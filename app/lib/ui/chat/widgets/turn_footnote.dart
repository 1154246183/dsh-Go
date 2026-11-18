// The quiet per-turn footnote: just when the turn was generated. It opens the
// turn's trajectory, where duration, steps, cost and tokens live.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../plugins/native/native_model.dart' show NativeTurnNotes;
import '../../plugins/native/native_tone.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';

/// 一轮结束后的**回合脚注**:`23:08 ›`——只报生成时刻。
///
/// 时长、步数、花费、tokens 都在点开的「本轮轨迹」里，脚注只留一个可点的时刻。
class TurnFootnote extends StatelessWidget {
  const TurnFootnote({super.key, required this.trace, this.onTap, this.notes});

  final TurnTrace trace;
  final VoidCallback? onTap;

  /// What plugins say about this turn (`turn.note`): the first thing to go when it doesn't fit.
  final NativeTurnNotes? notes;

  /// 时刻：`23:08`。脚注只报「这轮是什么时候生成的」，
  /// 时长、步数、花费、tokens 全部放进本轮轨迹详情，避免和下面那排重复。
  static String _clock(DateTime time) {
    final local = time.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}';
  }

  /// 从全到简的几种写法(第一种放得下就用它)。
  /// 只有时刻与插件注记两种成分，放不下就先丢注记。
  static List<String> variants(TurnTrace trace, {String? note}) {
    final clock = _clock(trace.start);
    return [
      if (note != null && note.isNotEmpty) '$clock · $note',
      clock,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final style = AppType.tabular(
      theme.textTheme.labelSmall!.copyWith(fontSize: 12, color: dsh.textTertiary, height: 1.3),
    );
    final notes = this.notes;
    final options = variants(trace, note: notes?.text);
    return Semantics(
      button: onTap != null,
      label: l10n.chatTurnFootnoteSemantics(options.first),
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        customBorder: Squircle.border(AppShape.sm),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 36),
          // 放进 Bleed(8) 的操作行里:左 8 让文字贴正文左缘;右 4 是光学补偿,
          // 箭头字形在 16 的格子里右侧自带约 5 的空白,补完后笔画贴正文右缘。
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final room = constraints.maxWidth - 16;
                final text = options.firstWhere((o) => _width(context, o, style) <= room, orElse: () => options.last);
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: notes != null && text == options.first
                          ? _noted(text, notes, style, dsh)
                          : Text(text, maxLines: 1, softWrap: false, overflow: TextOverflow.fade, style: style),
                    ),
                    Icon(AppIcons.disclosure, size: 16, color: dsh.textTertiary),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// [text] ends with the notes: each in the tone its plugin asked for, the rest as it always is.
  static Widget _noted(String text, NativeTurnNotes notes, TextStyle style, DshColors dsh) => Text.rich(
    TextSpan(
      children: [
        TextSpan(text: text.substring(0, text.length - notes.text.length)),
        for (final (i, note) in notes.notes.indexed) ...[
          if (i > 0) const TextSpan(text: ' · '),
          TextSpan(
            text: note.text,
            style: TextStyle(color: nativeToneColor(dsh, note.tone)),
          ),
        ],
      ],
    ),
    maxLines: 1,
    softWrap: false,
    overflow: TextOverflow.fade,
    style: style,
  );

  static double _width(BuildContext context, String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }
}
