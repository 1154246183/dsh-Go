import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../l10n/l10n.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../diff_page.dart';
import '../turn_summary.dart';
import 'chat_card.dart';
import '../../common/brief_notice.dart';

/// 一轮结束时的**改动卡**:改了哪些文件、各自 +/−,是改动详情页的入口。
///
/// ```
/// ┌──────────────────────────────────────┐
/// │ ▤ 改动了 5 个文件              +31 −6 │  ChatCard 标题行
/// │ ▢ login_controller.dart  app/l… +18 −4│  每行 40,行间不画线
/// │ ▢ README.md  新建                  +6 │
/// │ ▢ CHANGELOG.md                  +1 −1 │
/// │ 查看改动            还有 2 个文件  ›  │  ChatCardFooter
/// └──────────────────────────────────────┘
/// ```
///
/// 最多列 [shownCount] 个文件;点文件直接打开那个文件,点底栏从第一个看起。
class ChangeCard extends StatelessWidget {
  const ChangeCard({super.key, required this.files, this.sessionId});

  final List<FileChange> files;

  /// 这一轮所在会话：改动详情页据此把相对路径换成绝对路径，好在 Filza 里直达。
  final String? sessionId;

  /// 卡片上最多列几个文件。
  static const shownCount = 3;

  void _open(BuildContext context, int index) {
    Navigator.of(context).push(ChangeDiffPage.route(files, initialIndex: index, sessionId: sessionId));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final added = files.fold(0, (sum, f) => sum + f.added);
    final removed = files.fold(0, (sum, f) => sum + f.removed);
    final shown = files.length <= shownCount ? files : files.sublist(0, shownCount);
    final hidden = files.length - shown.length;

    return ChatCard(
      icon: AppIcons.diff,
      title: l10n.chatChangedFiles(files.length),
      // One file: its row already carries the counts.
      trailing: files.length > 1 ? DiffCounts(added: added, removed: removed) : null,
      children: [
        for (final (i, file) in shown.indexed) _FileRow(file: file, onTap: () => _open(context, i)),
        ChatCardFooter(
          label: l10n.chatViewChanges,
          meta: hidden > 0 ? l10n.chatMoreFiles(hidden) : null,
          semanticsLabel: hidden > 0 ? l10n.chatViewMoreChanges(hidden) : l10n.chatViewChanges,
          onTap: () => _open(context, 0),
        ),
      ],
    );
  }
}

/// 一行一个文件:文件名、目录(弱化、可省略)、+/−。
class _FileRow extends StatelessWidget {
  const _FileRow({required this.file, required this.onTap});

  final FileChange file;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dsh = DshColors.of(context);
    final directory = file.directory;
    void copy() => copyPath(context, file.path);

    return Semantics(
      button: true,
      label: l10n.chatFileChangeSemantics(file.shownPath, file.added, file.removed),
      excludeSemantics: true,
      onTap: onTap,
      onLongPress: copy,
      child: InkWell(
        onTap: onTap,
        onLongPress: copy,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: ChatCard.inset),
            child: Row(
              children: [
                Icon(
                  file.created ? AppIcons.fileNew : AppIcons.document,
                  size: 20,
                  color: file.created ? dsh.success : dsh.textTertiary,
                ),
                const SizedBox(width: 8),
                // One line: the name, then the directory, which gives way
                // first when the line runs out.
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: file.fileName),
                        if (file.created)
                          TextSpan(
                            text: l10n.chatNewFileSuffix,
                            style: theme.textTheme.labelSmall?.copyWith(color: dsh.success),
                          ),
                        if (directory.isNotEmpty)
                          TextSpan(
                            text: '  $directory',
                            style: AppType.mono(size: 11.5, height: 1.35, color: dsh.textTertiary),
                          ),
                      ],
                    ),
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.3, color: colors.onSurface),
                  ),
                ),
                const SizedBox(width: 8),
                DiffCounts(added: file.added, removed: file.removed),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 等宽数字的 `+18 −4`;一侧为 0 时省掉那一侧(两侧都为 0 显示 `+0`)。
class DiffCounts extends StatelessWidget {
  const DiffCounts({super.key, required this.added, required this.removed});

  final int added;
  final int removed;

  @override
  Widget build(BuildContext context) {
    final dsh = DshColors.of(context);
    final mono = AppType.tabular(AppType.monoLabel(weight: FontWeight.w500));
    return Text.rich(
      TextSpan(
        children: [
          if (added > 0 || removed == 0)
            TextSpan(
              text: '+$added',
              style: mono.copyWith(color: dsh.success),
            ),
          if (removed > 0)
            TextSpan(
              text: '${added > 0 ? ' ' : ''}−$removed',
              style: mono.copyWith(color: dsh.danger),
            ),
        ],
      ),
    );
  }
}

/// 复制完整路径并给一句轻提示。
Future<void> copyPath(BuildContext context, String path) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.maybeOf(context);
  await Clipboard.setData(ClipboardData(text: path));
  HapticFeedback.selectionClick();
  messenger?.showBriefNotice(l10n.chatPathCopied);
}

/// 在 Filza 里直达 [path]（越狱机才有 Filza；没有就退回复制路径）。
///
/// 实测（Filza 4.0 / iOS 15 rootless）：
/// - `filza://view/<绝对路径>` 直达并高亮目标，路径里的空格和中文必须
///   百分号编码，否则 Filza 收到的是坏 URL，只会停在上一次的位置；
/// - `filza:///<绝对路径>` 只是被唤起，不定位；
/// - 所以先按能跳的写法试，再兜底只唤起，最后交给「文件」App。
Future<void> openInFilza(BuildContext context, String path) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final abs = path.startsWith('/') ? path : '/$path';
  // 每段单独编码：保留分隔用的 /，转义空格、中文和 % 本身。
  final encoded = abs.split('/').map(Uri.encodeComponent).join('/');
  final target = encoded.startsWith('/') ? encoded.substring(1) : encoded;
  final uris = <Uri>[
    Uri.parse('filza://view/$target'), // filza://view/var/mobile/… 直达
    Uri.parse('filza:///$encoded'), // 有些版本认这个
    Uri.parse('filza://'), // 只唤起
    Uri.parse('shareddocuments://${_encodeSharePath(abs)}'), // 没装 Filza 时交给「文件」
  ];
  for (final uri in uris) {
    var opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      opened = false;
    }
    if (opened) {
      HapticFeedback.selectionClick();
      return;
    }
  }
  // 没装 Filza 或者系统不让跳：退回复制路径，至少还能自己去粘贴。
  await copyPath(context, abs);
  messenger?.showBriefNotice(l10n.chatFilzaUnavailable);
}

/// `shareddocuments://` 要把整条路径当一个查询参数，只转义 / 以外的字符。
String _encodeSharePath(String abs) => Uri.encodeComponent(abs).replaceAll('%2F', '/');
