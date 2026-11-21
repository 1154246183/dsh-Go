// 备份与还原：把设置里能调的参数存成一个 JSON 文件，换机、重装、试错之后能搬回来。
//
// **不备份会话**：`sessions/` 是聊天记录本身，跟着备份走会让文件越滚越大，
// 也把对话内容复制到了别处。这里只收「把 App 调成我喜欢的样子」的那些文件。
//
// 进来的东西分两类：
//   - 目录白名单（`_dirs`）：整棵子树，按相对路径逐个文件写进 JSON；
//   - 单文件白名单（`_files`）：顶层的那几个配置文件。
// 名单之外的一律不动，包括 cache/、ohos-lifecycle/、attachments/、sessions/。

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// GitHub 构建的账号存在 App 的 shared_preferences 里（不是 .dsh 下的文件）：
/// 键名以 `flutter.github_accounts` 开头，值是 JSON 字符串。
///
/// 这里不直接读写 plist：Dart 侧由 shared_preferences 负责，备份只带
/// 键值对这一份快照，还原时再写回去。
const String githubAccountsPrefix = 'flutter.github_accounts';

/// 备份里放 shared_preferences 那一份的名字。
const String prefsSectionKey = '_shared_preferences';
/// 一次备份的结果：写了哪些文件、多大、落在哪儿。
class BackupResult {
  const BackupResult({required this.file, required this.entries, required this.bytes});

  final File file;
  final int entries;
  final int bytes;

  String get name => file.uri.pathSegments.last;
}

/// 还原的结果：覆盖了多少个文件，顺带说清还原时跳过了什么。
class RestoreResult {
  const RestoreResult({required this.entries, required this.skipped});

  final int entries;
  final int skipped;
}

/// 备份文件的格式版本。以后加字段靠它认旧文件。
const int backupVersion = 1;

/// SQLite 的旁路文件后缀：还原写回前要先删掉，否则旧日志会盖掉新库。
const List<String> _walSuffixes = <String>['-wal', '-shm'];

/// 整棵备份的目录（相对 `.dsh`）。
///
/// 只收「配置」，不收「内容」：
///   ui.json 所在目录（界面）、profiles（模型与主机的配置）、
///   .agent-presets（子代理预设）、skills（装过的技能）、dsh-app（App 自己的偏好）。
const List<String> _dirs = <String>[
  'dsh-go',
  'profiles',
  '.agent-presets',
  'skills',
  'dsh-app',
  // 插件自己的设置与账户数据。都在 ~150 KB 以内，值得跟着搬：
  //   - our-free-model：服务目录缓存、可用性、原生扩展、账户与登录状态
  //     （settings.json 里存的是已登录的账户信息，正是「免得下次重新输入」）
  //   - channel-pack：渠道的签到状态与令牌账本（token-ledger.json）
  //   - media：图像与视频的预算账本和任务恢复索引（含 prompt 与 task id）
  //   - dsh-purge / redteam / openai-gateway：同一插件族的设置
  //   - storages：工作区选择、会话投影缓存
  'our-free-model',
  'channel-pack',
  'media',
  'dsh-purge',
  'redteam',
  'openai-gateway',
  'storages',
  // 注意：dsh-purge-community（7.7 MB / 448 文件）是插件自己的素材与
  // 运行缓存，不是「设置」，刻意不收，否则备份文件会胖十倍。
];

/// 顶层单文件。
///
/// `.credentials.yaml` 默认不算进来（见 [includeCredentials]）：它装的是
/// 各家模型的 key，跟着备份文件复制到别处等于把钥匙抄了一份。
///
/// 这里**一票否决**那些写着绝对容器路径的文件：
///   ios-container-paths.json、ios-host.patch.json、ohos-host.patch.json、
///   ohos-ownership/ —— 它们把
///   `/var/mobile/Containers/Data/Application/<UUID>/...` 原样记了下来，
///   而重装 App 后系统一定会发新的 UUID。这类文件搬回来只会指向不存在的路径，
///   轻则 host 插件加载失败，重则 App 起不来。它们描述的是「这一次安装」的
///   运行态，不是你的设置，所以不在备份范围内（还原时也会被跳过，
///   见 [restoreBackup]）。
const List<String> _files = <String>[];

/// 只在勾了「连凭据一起备份」时才收的目录。
///
/// 这些目录里除了设置，还留着使用痕迹：media 的账本记着 prompt 与
/// 供应商 task id，channel-pack 的账本记着令牌用量，our-free-model
/// 的 settings.json 记着账户。它们本身不含密钥，但和凭据同级敏感，
/// 放在同一个开关后面，不让人无意间把它发出去。
const List<String> _credentialGatedDirs = <String>[
  'our-free-model',
  'channel-pack',
  'media',
];

/// 备份里不该出现的路径前缀：含绝对容器路径的运行态文件。
///
/// 两条用途：备份时跳过（老备份里可能还有），还原时也跳过 ——
/// 让旧备份在新容器上也能安全落地。
const List<String> _containerBound = <String>[
  'ios-container-paths.json',
  'ios-host.patch.json',
  'ohos-host.patch.json',
  'ohos-ownership/',
];

/// [rel] 是不是那种「绑死在这次安装上」的运行态文件。
bool _isContainerBound(String rel) => _containerBound.any((p) => rel == p || rel.startsWith(p));

/// 需要整份拷贝、不进 JSON 的二进制文件。
///
/// SQLite 行情库（炒股插件的 data/tickflow.db）是二进制，按 UTF-8 读会得到
/// 一堆乱码，base64 进 JSON 又让备份膨胀一倍还得编解码。直接复制文件最省事：
/// 备份时放到 `<备份名>.files/` 下，还原时拷回原位。
bool _isBinaryPath(String rel) {
  if (rel.endsWith('.db') || rel.endsWith('.sqlite') || rel.endsWith('.sqlite3')) return true;
  if (rel.endsWith('.png') || rel.endsWith('.jpg') || rel.endsWith('.webp')) return true;
  if (rel.endsWith('.zip') || rel.endsWith('.gz')) return true;
  return false;
}

/// `.dsh` 根目录。和「帮助与关于」里用的是同一个位置。
Future<Directory?> dshDataDir() async {
  try {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/runtime/rootfs/root/.dsh');
    return dir.existsSync() ? dir : null;
  } catch (_) {
    return null;
  }
}

/// 备份文件的落点：`<App Documents>/dsh-backup-20261119-1043.json`。
///
/// 放 Documents 而不是 `.dsh` 里面，是为了 Filza、「文件」App、iTunes 文件共享
/// 都能直接拿到，不用先懂这个 App 的目录结构。
Future<Directory> backupDir() async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/backups');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir;
}

/// 列出已有备份，最新的在前。
Future<List<File>> listBackups() async {
  try {
    final dir = await backupDir();
    final files = dir
        .listSync(followLinks: false)
        .whereType<File>()
        .where((f) => f.path.endsWith('.json') && f.uri.pathSegments.last.startsWith('dsh-backup-'))
        .toList();
    files.sort((a, b) => b.path.compareTo(a.path));
    return files;
  } catch (_) {
    return <File>[];
  }
}

String _stamp(DateTime now) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}';
}

/// 把设置打成一个 JSON 文件。
///
/// [includeCredentials] 为 true 时才收 `.credentials.yaml`。
/// [note] 是给这个备份起的一句话，还原时会显示出来（可为空）。
Future<BackupResult> createBackup({bool includeCredentials = false, String? note}) async {
  final home = await dshDataDir();
  if (home == null) {
    throw StateError('没找到 DSH 数据目录');
  }
  final files = <String, String>{};
  // 需要原样拷贝的二进制文件（SQLite 行情库之类）：它们的相对路径。
  // 不进 JSON —— 1 MB 的库 base64 之后更大，还得编解码。
  // 备份时把它们复制到备份文件旁边的同名目录，还原时再拷回来。
  final copies = <String>[];

  void collect(String rel, File file) {
    // 绑死在这台设备这次安装上的运行态文件，一律不收：重装后 UUID 变了，
    // 放回去只会指向不存在的路径。
    if (_isContainerBound(rel)) return;
    // WAL / SHM 是 SQLite 的临时旁路文件，跟着主库一起搬没意义，
    // 还原时留着旧的反而会污染刚写回去的主库。
    if (rel.endsWith('-wal') || rel.endsWith('-shm')) return;
    if (_isBinaryPath(rel)) {
      copies.add(rel);
      return;
    }
    try {
      // 其余按 UTF-8 收；坏了就跳过（宁可少一个文件，也不要生成打不开的备份）。
      files[rel] = file.readAsStringSync();
    } catch (_) {
      // 不是 UTF-8 就是二进制，改成整份拷贝。
      copies.add(rel);
    }
  }

  if (includeCredentials) {
    final f = File('${home.path}/.credentials.yaml');
    if (f.existsSync()) collect('.credentials.yaml', f);
  }
  for (final name in _dirs) {
    final dir = Directory('${home.path}/$name');
    if (!dir.existsSync()) continue;
    // 含使用痕迹的目录跟着凭据开关走。
    if (!includeCredentials && _credentialGatedDirs.contains(name)) continue;
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = entity.path.substring('${home.path}/'.length);
      // 目录白名单里也别把会话顺进来（attachments 挂在会话下，但这里本就
      // 没列 attachments；多一层防御，名单将来改了也不会漏）。
      if (rel.startsWith('sessions/') || rel.startsWith('attachments/')) continue;
      collect(rel, entity);
    }
  }

  // 插件自带的本地数据库：`profiles/<profile>/node_modules/<pkg>/data/*.db`。
  // 炒股插件的 tickflow.db 就是这种 —— 1 MB 上下的 SQLite，里面是已同步的
  // K 线与自选股。不收的话重装后要重新拉一遍。
  // 只收 db，不收插件的其它文件（那是代码，随 ipa 一起装）。
  final profilesRoot = Directory('${home.path}/profiles');
  if (profilesRoot.existsSync()) {
    for (final profile in profilesRoot.listSync(followLinks: false)) {
      if (profile is! Directory) continue;
      final modules = Directory('${profile.path}/node_modules');
      if (!modules.existsSync()) continue;
      for (final pkg in modules.listSync(followLinks: false)) {
        if (pkg is! Directory) continue;
        // 带 scope 的包（@scope/name）
        final leaves = <Directory>[];
        if (pkg.path.split('/').last.startsWith('@')) {
          for (final inner in pkg.listSync(followLinks: false)) {
            if (inner is Directory) leaves.add(inner);
          }
        } else {
          leaves.add(pkg);
        }
        for (final leaf in leaves) {
          final data = Directory('${leaf.path}/data');
          if (!data.existsSync()) continue;
          for (final entity in data.listSync(followLinks: false)) {
            if (entity is! File) continue;
            final rel = entity.path.substring('${home.path}/'.length);
            if (rel.startsWith('sessions/') || rel.startsWith('attachments/')) continue;
            collect(rel, entity);
          }
        }
      }
    }
  }

  // GitHub 构建的账号：跟着凭据开关走（它等于登录凭证）。
  if (includeCredentials) {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys()) {
        if (!key.startsWith(githubAccountsPrefix)) continue;
        final value = prefs.get(key);
        if (value is String) files['${prefsSectionKey}/$key'] = value;
      }
    } catch (_) {
      // 读不到就不带，不影响别的设置。
    }
  }

  final now = DateTime.now();
  final payload = <String, Object?>{
    'version': backupVersion,
    'createdAt': now.toIso8601String(),
    'app': 'dsh-go',
    'note': note ?? '',
    'includesCredentials': includeCredentials,
    'files': files,
    // 二进制文件的相对路径；实际内容放在备份旁边的同名目录里。
    if (copies.isNotEmpty) 'copies': copies,
  };
  final text = const JsonEncoder.withIndent('  ').convert(payload);
  final dir = await backupDir();
  final file = File('${dir.path}/dsh-backup-${_stamp(now)}.json');
  await file.writeAsString(text);

  // 二进制原样拷贝到 <备份名>.files/ 下，保持原来的相对路径。
  if (copies.isNotEmpty) {
    final sidecar = Directory('${dir.path}/${file.uri.pathSegments.last}.files');
    if (sidecar.existsSync()) sidecar.deleteSync(recursive: true);
    for (final rel in copies) {
      try {
        final source = File('${home.path}/$rel');
        if (!source.existsSync()) continue;
        final target = File('${sidecar.path}/$rel');
        target.parent.createSync(recursive: true);
        source.copySync(target.path);
      } catch (_) {}
    }
  }

  return BackupResult(
    file: file,
    entries: files.length + copies.length,
    bytes: text.length,
  );
}

/// 读一个备份文件，校验格式，给出里面的文件表。
///
/// 认不出来就抛 [FormatException]，调用方负责提示。
Future<({Map<String, String> files, List<String> copies, String? note, bool credentials, DateTime? at})> readBackup(File file) async {
  final text = await file.readAsString();
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    throw const FormatException('这不像是 DSH Go 的备份文件');
  }
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('这不像是 DSH Go 的备份文件');
  }
  if (decoded['app'] != 'dsh-go') {
    throw const FormatException('这不是 DSH Go 的备份');
  }
  final version = decoded['version'];
  if (version is! int || version > backupVersion) {
    throw const FormatException('备份来自更新的版本，这台设备上的 App 读不了');
  }
  final raw = decoded['files'];
  if (raw is! Map) {
    throw const FormatException('备份里没有文件');
  }
  final files = <String, String>{};
  raw.forEach((key, value) {
    if (key is String && value is String) files[key] = value;
  });
  final at = DateTime.tryParse(decoded['createdAt'] is String ? decoded['createdAt'] as String : '');
  // 二进制文件的相对路径；内容在同名 `.files/` 目录里，不在这份 JSON。
  final copies = <String>[
    for (final e in (decoded['copies'] is List ? decoded['copies'] as List : const []))
      if (e is String && e.isNotEmpty) e,
  ];
  return (
    files: files,
    copies: copies,
    note: decoded['note'] is String ? decoded['note'] as String : null,
    credentials: decoded['includesCredentials'] == true,
    at: at,
  );
}

/// 把备份写回去。
///
/// 只覆盖备份里有的文件，不删任何东西：备份里没有的（会话、缓存、新装的技能）
/// 原样留着。这样还原旧备份不会把后来装的东西抹掉。
Future<RestoreResult> restoreBackup(
  File file, {
  bool includeCredentials = false,
  void Function(String rel, int done, int total)? onProgress,
}) async {
  final home = await dshDataDir();
  if (home == null) {
    throw StateError('没找到 DSH 数据目录');
  }
  final data = await readBackup(file);
  final entries = data.files.entries.toList();
  var written = 0;
  var skipped = 0;
  for (final (i, entry) in entries.indexed) {
    final rel = entry.key;
    // 备份是可以被手改的，别让 `../` 写到 `.dsh` 外面去。
    if (rel.contains('..') || rel.startsWith('/')) {
      skipped++;
      continue;
    }
    if (rel == '.credentials.yaml' && !includeCredentials) {
      skipped++;
      continue;
    }
    // GitHub 账号：写回 shared_preferences，不是文件。
    if (rel.startsWith('${prefsSectionKey}/')) {
      if (!includeCredentials) {
        skipped++;
        continue;
      }
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(rel.substring(prefsSectionKey.length + 1), entry.value);
        written++;
      } catch (_) {
        skipped++;
      }
      onProgress?.call(rel, i + 1, entries.length);
      continue;
    }
    if (rel.startsWith('sessions/') || rel.startsWith('attachments/')) {
      skipped++;
      continue;
    }
    // 旧备份里可能还留着含绝对容器路径的运行态文件。重装后 UUID 已经变了，
    // 写回去就是一批死路径 —— 跳过，让旧备份也能在新容器上安全还原。
    if (_isContainerBound(rel)) {
      skipped++;
      continue;
    }
    try {
      final target = File('${home.path}/$rel');
      final parent = target.parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      await target.writeAsString(entry.value);
      written++;
    } catch (_) {
      skipped++;
    }
    onProgress?.call(rel, i + 1, entries.length);
  }

  // 二进制文件：从 `<备份名>.files/` 拷回原位。
  // 还原前先把这个库可能残留的 -wal/-shm 删掉，否则旧日志会盖掉刚写回去的主库。
  if (data.copies.isNotEmpty) {
    final sidecar = Directory('${file.path}.files');
    for (final rel in data.copies) {
      if (rel.contains('..') || rel.startsWith('/')) {
        skipped++;
        continue;
      }
      if (_isContainerBound(rel)) {
        skipped++;
        continue;
      }
      try {
        final source = File('${sidecar.path}/$rel');
        if (!source.existsSync()) {
          skipped++;
          continue;
        }
        final target = File('${home.path}/$rel');
        target.parent.createSync(recursive: true);
        // 旧的 WAL / SHM 会让新库读到过期的页，先清掉。
        for (final suffix in _walSuffixes) {
          final side = File('${target.path}$suffix');
          if (side.existsSync()) {
            try {
              side.deleteSync();
            } catch (_) {
              // 删不掉就算了，拷贝会覆盖。
            }
          }
        }
        source.copySync(target.path);
        written++;
      } catch (_) {
        skipped++;
      }
    }
  }

  return RestoreResult(entries: written, skipped: skipped);
}

/// 删掉一个备份文件。
Future<void> deleteBackup(File file) async {
  try {
    if (file.existsSync()) await file.delete();
  } catch (_) {}
}
