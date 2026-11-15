// 把随 ipa 一起内置的 DSH 插件补进本机引擎的 profile。
//
// 手机端装插件要在引擎里走 npm/pnpm，联网和磁盘都容易失败；这里改成
// 构建期把插件包放进 app bundle，启动时复制进 profile 的 node_modules，
// 再把它加进 profile 包的 `dsh.profile.bundles`。
//
// 引擎的目录约定（见 app/ios/Runner/EngineChannel.swift）：
//   guestRoot = <App>/Library/.../runtime/rootfs
//   home      = guestRoot/root          ← LocalPaths.home 返回的就是这个
//   dshHome   = home/.dsh
//   profiles  = dshHome/profiles/<name>
//
// 边界：
//   - 只处理已经存在 node_modules 的 profile（引擎至少启动过一次）；
//   - 复制是幂等的，目标已在就跳过；
//   - 任何一步失败都只记录，不影响启动。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'local_paths.dart';

class BuiltinPlugins {
  BuiltinPlugins._();

  /// 内置在 app bundle 里、需要补进 profile 的插件目录名。
  ///
  /// 这些目录由 CI 在打包时放进 App 的 `builtin-plugins/`，首次启动时整份
  /// 复制进 profile 的 node_modules 并登记到 package.json。
  static const List<String> bundled = ['dsh-our-free-model', 'dsh-purge'];

  /// app bundle 里存放内置插件的位置（由 CI 复制进去）。
  static const String bundleFolder = 'builtin-plugins';

  /// 最近一次执行的诊断结果，供设置页展示。
  static String lastResult = '尚未执行';
  static List<String> lastProfiles = const [];
  static List<String> lastSteps = const [];

  static String? get _appDirectory {
    final executable = Platform.resolvedExecutable;
    if (executable.isEmpty) return null;
    return File(executable).parent.path;
  }

  static Future<void> ensure() async {
    final steps = <String>[];
    try {
      await _ensure(steps);
    } catch (error) {
      steps.add('异常: $error');
    }
    lastSteps = steps;
    for (final step in steps) {
      debugPrint('builtin plugins: $step');
    }
    _writeLog(steps);
  }

  /// 把这一次的结果写到 `$DSH_HOME/dsh-app/builtin-plugins.log`。
  ///
  /// 手机上没法看 debugPrint，注入失败时只有这个文件能说明原因。
  static void _writeLog(List<String> steps) {
    try {
      final home = LocalPaths.home;
      if (home.isEmpty) return;
      final file = File('$home/.dsh/dsh-app/builtin-plugins.log');
      file.parent.createSync(recursive: true);
      final stamp = DateTime.now().toIso8601String();
      file.writeAsStringSync(
        '[$stamp] ${lastResult}\n${steps.map((s) => '  - $s').join('\n')}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // 日志本身失败不影响注入。
    }
  }

  /// profile 目录由引擎创建；App 先启动时可能还没有，等一会儿再来。
  static bool _profileReady(Directory profiles) {
    if (!profiles.existsSync()) return false;
    for (final entity in profiles.listSync()) {
      if (entity is Directory) return true;
    }
    return false;
  }

  static Future<void> _ensure(List<String> steps) async {
    final app = _appDirectory;
    if (app == null) {
      lastResult = '没有 app 目录';
      steps.add('没有 app 目录');
      return;
    }
    steps.add('app=$app');

    final sourceRoot = Directory('$app/$bundleFolder');
    if (!sourceRoot.existsSync()) {
      lastResult = '包里没有 $bundleFolder';
      steps.add('缺 $bundleFolder');
      return;
    }
    final available = sourceRoot
        .listSync()
        .whereType<Directory>()
        .map((d) => d.path.split('/').last)
        .toList();
    steps.add('包内插件: ${available.join(',')}');

    final home = LocalPaths.home;
    steps.add('home=$home');
    if (home.isEmpty) {
      lastResult = '还没有 home 路径（guestRoot 未就绪）';
      return;
    }

    final profiles = Directory('$home/.dsh/profiles');
    // 引擎首次启动前 profile 还不存在；等它建好再注入，最多等 20 秒。
    // 调用方不 await 这个函数，所以等待不拖慢启动。
    for (var attempt = 0; attempt < 40 && !_profileReady(profiles); attempt++) {
      if (attempt == 0) steps.add('等引擎建 profile: ${profiles.path}');
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    steps.add('profiles ready=${_profileReady(profiles)}');
    if (!_profileReady(profiles)) {
      lastResult = '引擎还没建 profile（等了 20 秒）';
      return;
    }

    final names = <String>[];
    final seeded = <String>[];
    for (final entity in profiles.listSync()) {
      if (entity is! Directory) continue;
      final name = entity.path.split('/').last;
      // 不要要求 node_modules 预先存在：全新 profile 里它就是没有的，
      // 而我们要做的正是把它建起来。
      names.add(name);
      final modules = Directory('${entity.path}/node_modules');
      if (!modules.existsSync()) {
        steps.add('创建 $name/node_modules');
        modules.createSync(recursive: true);
      }
      for (final plugin in bundled) {
        final source = Directory('${sourceRoot.path}/$plugin');
        if (!source.existsSync()) continue;
        final target = Directory('${modules.path}/$plugin');
        if (!target.existsSync()) {
          steps.add('复制 $plugin → $name');
          await _copy(source, target);
        } else {
          steps.add('$plugin 已在 $name');
        }
        await _register(entity.path, plugin, steps);
        if (!seeded.contains(plugin)) seeded.add(plugin);
      }
      // 插件登记完之后，把默认模型指向插件的通道。
      await _seedDefaultModel(entity.path, steps);
    }
    lastProfiles = names;
    if (names.isEmpty) {
      lastResult = 'profiles 下没有任何 profile 目录';
    } else if (seeded.isEmpty) {
      lastResult = '包内缺少插件源目录';
    } else {
      lastResult = '已写入 ${seeded.join(',')} → ${names.join(',')}；重启本机引擎后生效';
    }
  }

  /// 把 profile 设置层（`cordis.patch.yml`）的默认模型指向内置插件。
  ///
  /// ## 为什么必须做
  ///
  /// 引擎自带的 `dsh-agent-default-model` 出厂值是 `deepseek-official` +
  /// `deepseek-flash`，即 DeepSeek 官方账号通道。装上 `dsh-our-free-model`
  /// 之后它并不会自动改用插件——插件只是注册了一个叫 `our-free-model` 的
  /// 适配器，得有人把默认指向它。
  ///
  /// 不指过去的表现：每一轮都报「还没有 DeepSeek API Key」（那条提示其实
  /// 是兜底文案，真实错误可能是任意 provider 的 MISSING_CREDENTIAL）。
  ///
  /// ## 为什么连 rememberLastSelection 一起关
  ///
  /// 引擎的 `initializeDefaultModel()` 在启动时会把默认模型改写成官方账号
  /// 通道的第一个模型，无视这里的配置。它开头有一句
  /// `if (!remembersLastSelection()) return;`——把 `rememberLastSelection`
  /// 设成 `false` 就能让它跳过改写，这里配的 provider/model 才站得住。
  ///
  /// 这个改写是纯文本、逐行、只认预期形态：任何一行不像预期就整段跳过并
  /// 记日志，绝不猜。
  static const String _pluginProvider = 'our-free-model';
  static const String _pluginModel = 'deepseek-v4.1-flash-free';

  static Future<void> _seedDefaultModel(String profile, List<String> steps) async {
    if (!bundled.contains('dsh-our-free-model')) return;

    final file = File('$profile/cordis.patch.yml');
    final name = profile.split('/').last;

    if (!file.existsSync()) {
      // 引擎还没写出设置层。整块新建是合法的：它是一个补丁数组，
      // 只覆盖我们关心的那几个字段，其余继承 bundle 层。
      try {
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(_defaultModelBlock, flush: true);
        steps.add('新建 $name/cordis.patch.yml（默认模型 → $_pluginProvider）');
      } catch (error) {
        steps.add('新建 cordis.patch.yml 失败: $error');
      }
      return;
    }

    List<String> lines;
    try {
      lines = await file.readAsLines();
    } catch (error) {
      steps.add('读 $name/cordis.patch.yml 失败: $error');
      return;
    }

    if (lines.any((l) => l.contains(_pluginProvider))) {
      steps.add('$name 默认模型已是 $_pluginProvider');
      return;
    }

    // 找 `- id: agent-default-model` 这一条。
    final start = lines.indexWhere(
      (l) => l.trimRight() == '- id: agent-default-model',
    );
    if (start < 0) {
      // 没有这一条：追加一整块，交给补丁层去覆盖 bundle 的出厂值。
      try {
        final text = '${lines.join('\n')}\n$_defaultModelBlock';
        file.writeAsStringSync(text, flush: true);
        steps.add('$name 追加默认模型条目 → $_pluginProvider');
      } catch (error) {
        steps.add('追加 cordis.patch.yml 失败: $error');
      }
      return;
    }

    // 找到这一条的花括号范围：从 start 到下一个顶格 `- ` 之前。
    var end = lines.length;
    for (var i = start + 1; i < lines.length; i++) {
      if (lines[i].startsWith('- ')) {
        end = i;
        break;
      }
    }

    var providerLine = -1;
    var modelLine = -1;
    var rememberLine = -1;
    for (var i = start; i < end; i++) {
      final t = lines[i].trim();
      if (t.startsWith('provider:')) providerLine = i;
      if (t.startsWith('model:')) modelLine = i;
      if (t.startsWith('rememberLastSelection:')) rememberLine = i;
    }
    if (providerLine < 0 || modelLine < 0) {
      // 形态不符（比如是 insert 列表），不猜，留给人工。
      steps.add('$name 的 agent-default-model 结构不符预期，跳过');
      return;
    }

    final updated = List<String>.from(lines);
    // 保留原来的缩进。
    String indentOf(int i) {
      final m = RegExp(r'^(\s*)').firstMatch(updated[i]);
      return m?.group(1) ?? '    ';
    }

    final pIndent = indentOf(providerLine);
    final mIndent = indentOf(modelLine);
    updated[providerLine] = '$pIndent' + 'provider: $_pluginProvider';
    updated[modelLine] = '$mIndent' + 'model: $_pluginModel';

    if (rememberLine >= 0) {
      updated[rememberLine] =
          '${indentOf(rememberLine)}rememberLastSelection: false';
    } else {
      // 没有就补在 model 后面。
      updated.insert(modelLine + 1, '$mIndent' + 'rememberLastSelection: false');
    }

    try {
      await file.writeAsString('${updated.join('\n')}\n', flush: true);
      steps.add('$name 默认模型 → $_pluginProvider/$_pluginModel，并关闭记忆选择');
    } catch (error) {
      steps.add('写 cordis.patch.yml 失败: $error');
    }
  }

  static const String _defaultModelBlock = '''
- id: agent-default-model
  name: "@deepseek-ai/dsh-agent-default-model"
  config:
    provider: our-free-model
    model: deepseek-v4.1-flash-free
    rememberLastSelection: false
''';

  static Future<void> _copy(Directory source, Directory target) async {
    target.createSync(recursive: true);
    for (final entity in source.listSync(recursive: true, followLinks: false)) {
      final relative = entity.path.substring(source.path.length + 1);
      final destination = '${target.path}/$relative';
      if (entity is Directory) {
        Directory(destination).createSync(recursive: true);
      } else if (entity is File) {
        File(destination).parent.createSync(recursive: true);
        entity.copySync(destination);
      }
    }
  }

  /// 在 profile 的 package.json 里登记 bundle。解析失败就原样不动。
  static Future<void> _register(String profile, String name, List<String> steps) async {
    final manifest = File('$profile/package.json');
    if (!manifest.existsSync()) {
      steps.add('$profile 没有 package.json');
      return;
    }
    final text = await manifest.readAsString();
    final Map<String, dynamic> root;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        steps.add('package.json 不是对象');
        return;
      }
      root = decoded;
    } catch (error) {
      steps.add('package.json 解析失败: $error');
      return;
    }

    final dshRaw = root['dsh'];
    final Map<String, dynamic> dsh =
        dshRaw is Map<String, dynamic> ? dshRaw : <String, dynamic>{};
    root['dsh'] = dsh;
    final profileRaw = dsh['profile'];
    final Map<String, dynamic> profileSection =
        profileRaw is Map<String, dynamic> ? profileRaw : <String, dynamic>{};
    dsh['profile'] = profileSection;
    final bundlesRaw = profileSection['bundles'];
    final List<dynamic> bundles = bundlesRaw is List ? bundlesRaw : <dynamic>[];
    profileSection['bundles'] = bundles;

    if (bundles.contains(name)) {
      steps.add('$name 已登记在 bundle 列表');
      return;
    }
    bundles.add(name);
    try {
      await manifest.writeAsString(
        const JsonEncoder.withIndent('  ').convert(root),
        flush: true,
      );
      steps.add('已登记 $name 到 ${profile.split('/').last}');
    } catch (error) {
      steps.add('写 package.json 失败: $error');
    }
  }
}
