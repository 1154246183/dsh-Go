// About DSH Go: app information, the original author and personal profiles,
// then the brand mark, slogan and unofficial-app disclaimer.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../l10n/l10n.dart';
import '../../state/app_info.dart';
import '../../state/star_prompt.dart' show starLinkOpenerProvider;
import '../../state/update_state.dart';
import '../shell/brand_mark.dart';
import '../shell/page_frame.dart';
import '../star/star_prompt_dialog.dart' show openStarProject;
import '../theme/app_icons.dart';
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
              key: const ValueKey('settings-star'),
              spot: Spots.star,
              onTap: () => unawaited(
                openStarProject(ProviderScope.containerOf(context, listen: false), ScaffoldMessenger.maybeOf(context)),
              ),
            ),
            SettingsTile(
              spot: Spots.licenses,
              onTap: () => showLicensePage(
                context: context,
                applicationName: AppInfo.name,
                applicationVersion: version,
                applicationIcon: const Padding(padding: EdgeInsets.all(12), child: BrandMark(size: 56, tile: true)),
                applicationLegalese: AppInfo.disclaimer,
              ),
            ),
            SettingsTile(
              key: const ValueKey('settings-cleanup'),
              title: '清理缓存',
              subtitle: '删掉可再生的缓存和日志，会话、凭据、技能、附件都不动',
              onTap: () => unawaited(_openCleanup(context)),
            ),
          ],
        ),
        SettingsSection(
          title: l10n.hubAboutAuthor,
          children: [
            const SettingsTile(title: AppInfo.author),
            _authorLink(
              context,
              ref,
              'about-author-bilibili',
              l10n.hubAboutBilibili,
              AppInfo.authorBilibiliName,
              AppInfo.authorBilibiliUrl,
            ),
            _authorLink(context, ref, 'about-author-x', l10n.hubAboutX, AppInfo.authorXHandle, AppInfo.authorXUrl),
            _authorLink(
              context,
              ref,
              'about-author-github',
              l10n.hubAboutGithub,
              '@${AppInfo.author}',
              AppInfo.authorGithubUrl,
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

  Widget _authorLink(BuildContext context, WidgetRef ref, String key, String title, String handle, String url) =>
      Semantics(
        link: true,
        child: SettingsTile(
          key: ValueKey(key),
          title: title,
          subtitle: handle,
          trailing: Icon(AppIcons.openExternal, size: 18, color: DshColors.of(context).textTertiary),
          onTap: () => unawaited(_openAuthorLink(context, ref, Uri.parse(url))),
        ),
      );

  Future<void> _openAuthorLink(BuildContext context, WidgetRef ref, Uri url) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      if (await ref.read(starLinkOpenerProvider)(url)) return;
    } catch (_) {
      // As with the project's link, fall back to copying when no browser opens.
    }
    var copied = true;
    try {
      await Clipboard.setData(ClipboardData(text: url.toString()));
    } catch (_) {
      copied = false;
    }
    if (messenger?.mounted ?? false) {
      messenger!.showSnackBar(
        SnackBar(content: Text(copied ? l10n.shellBrowserUrlCopied : l10n.stateBrowserOpenFailed)),
      );
    }
  }
}
