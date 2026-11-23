// 设置 › 能力 › 语音朗读: 对话里那条朗读键用谁的声音。
//
// 声音本身不在这里新造一套——它就是伙伴小屋那套 CompanionVoiceSettings
// （本机语音 / 内置多家 API 预设 / 自定义 OpenAI 兼容接口 / 任意 HTTP），
// 改这里等于改那里，两处永远一致。这里只挑对话用得上的几项，字段少、
// 能试听，不用在一页里翻完整张表。

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../companion/companion_voice.dart';
import '../../companion/companion_voice_source.dart';
import '../../l10n/l10n.dart';
import '../shell/page_frame.dart';
import '../settings/settings_widgets.dart';
import '../theme/app_icons.dart';

class ReadAloudSettingsPage extends ConsumerStatefulWidget {
  const ReadAloudSettingsPage({super.key});

  @override
  ConsumerState<ReadAloudSettingsPage> createState() => _ReadAloudSettingsPageState();
}

class _ReadAloudSettingsPageState extends ConsumerState<ReadAloudSettingsPage> {
  final _base = TextEditingController();
  final _key = TextEditingController();
  final _model = TextEditingController();
  final _voice = TextEditingController();
  bool _filled = false;
  String? _preview;
  Timer? _saveTimer;

  @override
  void dispose() {
    _saveTimer?.cancel();
    for (final c in [_base, _key, _model, _voice]) {
      c.dispose();
    }
    super.dispose();
  }

  CompanionVoiceSettingsController get _store => ref.read(companionVoiceSettingsProvider.notifier);

  void _fill(CompanionVoiceSettings s) {
    if (_filled) return;
    _filled = true;
    _base.text = s.openaiBase;
    _key.text = s.openaiKey;
    _model.text = s.openaiModel;
    _voice.text = s.openaiVoice;
  }

  CompanionVoiceSettings _fromFields(CompanionVoiceSettings s) => s.copyWith(
    openaiBase: _base.text.trim(),
    openaiKey: _key.text.trim(),
    openaiModel: _model.text.trim(),
    openaiVoice: _voice.text.trim(),
  );

  void _edited(CompanionVoiceSettings s) {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), () {
      unawaited(_store.update(_fromFields(s)));
    });
  }

  Future<void> _previewNow(CompanionVoiceSettings s) async {
    final why = await ref.read(companionSpeakerProvider).preview(s, context.l10n.readAloudPreviewText);
    if (!mounted) return;
    setState(() => _preview = why ?? 'ok');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final s = ref.watch(companionVoiceSettingsProvider);
    if (s == null) {
      return AppPage.list(title: l10n.hubReadAloud, children: const []);
    }
    _fill(s);
    final source = s.source;
    return AppPage.list(
      title: l10n.hubReadAloud,
      children: [
        SettingsSection(
          children: [
            SettingsSwitchTile(
              icon: AppIcons.readAloud,
              title: l10n.hubReadAloudEnable,
              subtitle: l10n.hubReadAloudEnableHint,
              value: s.on,
              onChanged: (v) => unawaited(_store.update(s.copyWith(on: v))),
            ),
          ],
        ),
        SettingsSection(
          title: l10n.companionVoiceSource,
          children: [
            for (final option in CompanionVoiceSource.values)
              SettingsTile(
                title: _sourceName(l10n, option),
                subtitle: _sourceHint(l10n, option),
                trailing: option == source
                    ? Icon(AppIcons.done, size: 20, color: Theme.of(context).colorScheme.primary)
                    : null,
                onTap: () => unawaited(_store.update(s.copyWith(source: option))),
              ),
          ],
        ),
        if (source == CompanionVoiceSource.openai || source == CompanionVoiceSource.preset)
          SettingsSection(
            title: l10n.companionVoiceApi,
            children: [
              if (source == CompanionVoiceSource.openai) ...[
                _field(l10n.companionVoiceBase, _base, 'https://api.openai.com/v1', s),
                _field('Key', _key, 'sk-…', s, obscure: true),
              ],
              _field(l10n.companionVoiceModel, _model, 'gpt-4o-mini-tts', s),
              _field(l10n.companionVoiceVoice, _voice, 'alloy', s),
            ],
          ),
        SettingsSection(
          children: [
            SettingsTile(
              icon: AppIcons.readAloud,
              title: l10n.readAloudPreview,
              subtitle: _preview == null
                  ? null
                  : (_preview == 'ok' ? l10n.readAloudPreviewPlayed : _preview!),
              onTap: () => unawaited(_previewNow(_fromFields(s))),
            ),
          ],
        ),
      ],
    );
  }

  /// 一行「标题 + 输入框」：输入框放在行尾，跟其它设置行的右缘对齐。
  Widget _field(String title, TextEditingController controller, String hint, CompanionVoiceSettings s,
          {bool obscure = false}) =>
      SettingsTile(
        title: title,
        value: SizedBox(
          width: 190,
          child: TextField(
            controller: controller,
            obscureText: obscure,
            autocorrect: false,
            enableSuggestions: false,
            textAlign: TextAlign.end,
            style: Theme.of(context).textTheme.bodyMedium,
            decoration: InputDecoration(hintText: hint, isDense: true, border: InputBorder.none),
            onChanged: (_) => _edited(s),
          ),
        ),
      );

  String _sourceName(AppLocalizations l10n, CompanionVoiceSource s) => switch (s) {
    CompanionVoiceSource.system => l10n.companionVoiceSystem,
    CompanionVoiceSource.preset => l10n.companionVoicePreset,
    CompanionVoiceSource.openai => l10n.companionVoiceOpenai,
    CompanionVoiceSource.custom => l10n.companionVoiceCustom,
  };

  String? _sourceHint(AppLocalizations l10n, CompanionVoiceSource s) => switch (s) {
    CompanionVoiceSource.system => l10n.companionVoiceSystemHint,
    CompanionVoiceSource.openai => l10n.companionVoiceOpenaiHint,
    _ => null,
  };
}
