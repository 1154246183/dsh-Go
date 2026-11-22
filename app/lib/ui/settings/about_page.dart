// About DSH Go: app information, the original author and personal profiles,
// then the brand mark, slogan and unofficial-app disclaimer.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/l10n.dart';
import '../../state/app_info.dart';
import '../../state/update_state.dart';
import '../shell/brand_mark.dart';
import '../shell/page_frame.dart';
import '../theme/theme.dart';
import '../update/update_tiles.dart';
import 'settings_widgets.dart';

/// The installed version as the app shows it: `0.9.6 (10271234)`.
String installedVersionLabel(WidgetRef ref) {
  // What Android reports as installed (the compiled-in constant until it does).
  final installed = ref.watch(appUpdateProvider.select((s) => s.current));
  return installed.build == null ? installed.name : '${installed.name} (${installed.build})';
}

class AboutPage extends ConsumerWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final version = installedVersionLabel(ref);
    return AppPage.list(
      title: l10n.hubAbout,
      children: [
        SettingsSection(
          children: [
            SettingsTile(
              spot: Spots.version,
              value: Text(version, style: AppType.tabular(theme.textTheme.bodyMedium!)),
            ),
            const AppUpdateTiles(),
            SettingsTile(
              key: const ValueKey('settings-cleanup'),
              title: '清理缓存',
              subtitle: '删掉可再生的缓存和日志，会话、凭据、技能、附件都不动',
              onTap: () => unawaited(_openCleanup(context)),
            ),
            SettingsTile(
              key: const ValueKey('settings-open-data-dir'),
              title: '打开数据目录',
              subtitle: '用 Filza 打开 DSH 的 .dsh 目录，可直接翻缓存和会话文件',
              onTap: () => unawaited(_openDataDir(context)),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
          child: Column(
            children: [
              BrandMark(size: 18, color: colors.textDisabled),
              const SizedBox(height: 10),
              Text(
                AppInfo.slogan,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(color: colors.textTertiary),
              ),
              const SizedBox(height: 8),
              Text(
                AppInfo.disclaimer,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(color: colors.textTertiary),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// DSH 的数据根目录：`<Application Support>/runtime/rootfs/root/.dsh`。
  static Future<Directory?> _dshHome() async {
    try {
      final base = await getApplicationSupportDirectory();
      final dir = Directory('${base.path}/runtime/rootfs/root/.dsh');
      return dir.existsSync() ? dir : null;
    } catch (_) {
      return null;
    }
  }

  static int _dirBytes(Directory dir) {
    var total = 0;
    try {
      if (!dir.existsSync()) return 0;
      for (final entity in dir.listSync(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            total += entity.lengthSync();
          } catch (_) {
            // 单个文件读不到就跳过，不中断统计
          }
        }
      }
    } catch (_) {
      // 目录不可读时按 0 计
    }
    return total;
  }

  static String _sizeText(int bytes) => '${(bytes / 1048576).toStringAsFixed(1)} MB';

  /// 用 Filza 打开 DSH 数据目录；没装 Filza 就把路径复制到剪贴板。
  Future<void> _openDataDir(BuildContext context) async {
    final home = await _dshHome();
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (home == null) {
      messenger?.showSnackBar(const SnackBar(content: Text('没找到 DSH 数据目录')));
      return;
    }
    final opened = await revealInFilza(home.path);
    if (!opened) {
      messenger?.showSnackBar(SnackBar(content: Text('没打开 Filza，路径已复制：' + home.path)));
    }
  }

  /// 在 Filza 中定位一个本机绝对路径。
  ///
  /// Filza（com.tigisoftware.Filza）的 Info.plist 只注册了 `filza` 一个
  /// scheme，二进制里写死的入口只有 `filza://view` 与 `filza://license`。
  /// 因此只有 **`view` 当 host、绝对路径当 path** 的写法会定位并高亮目标：
  /// `filza://view/var/mobile/Library/Application%20Support/…`。
  ///
  /// 两种「唤起 Filza 却停在首页」的写法都在这里踩过：
  ///
  /// 1. `filza:///<绝对路径>`：scheme 匹配得上，但 host 为空，走不到 view
  ///    处理器，只唤起不定位；
  /// 2. 整条路径 `Uri.encodeComponent` 后拼在 `filza://view` 后面：开头的
  ///    `/` 变成 `%2F`，`view` 与路径之间没有真实分隔符，`view%2Fvar%2F…`
  ///    整串被当成 **host**，URL 规范化把字母转小写，容器 UUID 从
  ///    `3E5F3EAD-…` 变成 `3e5f3ead-…`；iOS 数据卷 APFS 区分大小写，
  ///    Filza 找不到目录就退回首页。
  ///
  /// 所以按 `/` 分段编码，并用 Uri 的 scheme/host/path 显式构造。
  ///
  /// 打不开就把路径复制给用户，至少不让人白点。
  static Future<bool> revealInFilza(String path) async {
    final clean = path.startsWith('/') ? path : '/' + path;
    final target = Uri(scheme: 'filza', host: 'view', path: clean);
    for (final uri in <Uri>[
      target, // 定位并高亮
      Uri.parse('filza://'), // 至少唤起 Filza
    ]) {
      try {
        if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return true;
      } catch (_) {
        // 换下一个写法
      }
    }
    try {
      await Clipboard.setData(ClipboardData(text: clean));
    } catch (_) {}
    return false;
  }

  /// 清理缓存：只动 `cache/` 与 `ohos-lifecycle/` 两处可再生的数据。
  Future<void> _openCleanup(BuildContext context) async {
    final home = await _dshHome();
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (home == null) {
      messenger?.showSnackBar(const SnackBar(content: Text('没找到 DSH 数据目录')));
      return;
    }
    final cacheDir = Directory('${home.path}/cache');
    final logDir = Directory('${home.path}/ohos-lifecycle');
    final cacheBytes = _dirBytes(cacheDir);
    final logBytes = _dirBytes(logDir);
    final total = cacheBytes + logBytes;
    if (!context.mounted) return;
    if (total == 0) {
      messenger?.showSnackBar(const SnackBar(content: Text('已经是干净的，没有可清理的缓存')));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清理缓存'),
        content: Text(
          '可释放 ${_sizeText(total)}\n'
          '缓存 ${_sizeText(cacheBytes)} · 日志 ${_sizeText(logBytes)}\n\n'
          '只删这两处；会话、凭据、技能、附件都不动。',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('清理')),
        ],
      ),
    );
    if (confirmed != true) return;
    var freed = 0;
    for (final dir in [cacheDir, logDir]) {
      final before = _dirBytes(dir);
      try {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
        freed += before;
      } catch (_) {
        // 删不掉的留着，下次再清
      }
    }
    if (messenger?.mounted ?? false) {
      messenger!.showSnackBar(SnackBar(content: Text('已释放 ${_sizeText(freed)}')));
    }
  }
}
