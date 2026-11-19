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
];

/// 顶层单文件。
///
/// `.credentials.yaml` 默认不算进来（见 [includeCredentials]）：它装的是
/// 各家模型的 key，跟着备份文件复制到别处等于把钥匙抄了一份。
const List<String> _files = <String>[
  'ios-host.patch.json',
  'ohos-host.patch.json',
  'ios-container-paths.json',
  'ohos-ownership',
];

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

  void collect(String rel, File file) {
    try {
      // 配置都是文本；按 UTF-8 收，坏了就跳过（宁可少一个文件，也不要生成打不开的备份）。
      files[rel] = file.readAsStringSync();
    } catch (_) {}
  }

  for (final name in _files) {
    final f = File('${home.path}/$name');
    if (f.existsSync()) collect(name, f);
  }
  if (includeCredentials) {
    final f = File('${home.path}/.credentials.yaml');
    if (f.existsSync()) collect('.credentials.yaml', f);
  }
  for (final name in _dirs) {
    final dir = Directory('${home.path}/$name');
    if (!dir.existsSync()) continue;
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = entity.path.substring('${home.path}/'.length);
      // 目录白名单里也别把会话顺进来（attachments 挂在会话下，但这里本就
      // 没列 attachments；多一层防御，名单将来改了也不会漏）。
      if (rel.startsWith('sessions/') || rel.startsWith('attachments/')) continue;
      collect(rel, entity);
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
  };
  final text = const JsonEncoder.withIndent('  ').convert(payload);
  final dir = await backupDir();
  final file = File('${dir.path}/dsh-backup-${_stamp(now)}.json');
  await file.writeAsString(text);
  return BackupResult(file: file, entries: files.length, bytes: text.length);
}

/// 读一个备份文件，校验格式，给出里面的文件表。
///
/// 认不出来就抛 [FormatException]，调用方负责提示。
Future<({Map<String, String> files, String? note, bool credentials, DateTime? at})> readBackup(File file) async {
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
  return (
    files: files,
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
    if (rel.startsWith('sessions/') || rel.startsWith('attachments/')) {
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
  return RestoreResult(entries: written, skipped: skipped);
}

/// 删掉一个备份文件。
Future<void> deleteBackup(File file) async {
  try {
    if (file.existsSync()) await file.delete();
  } catch (_) {}
}
