// 设置 › 能力 › 语音朗读: 对话里那条朗读键用谁的声音。
//
// 声音配置不在这页另做一套——点进去打开的就是伙伴小屋的「她的声音」
// 整页（CompanionVoicePage：手机自带 / 常用服务 / OpenAI 兼容 /
// 自定义 HTTP，含 API Key、音色预设与克隆、说话风格、试听）。
// 同一份配置、同一个界面，改哪边都一样。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../companion/companion_voice_source.dart';
import '../../l10n/l10n.dart';
import '../companion/companion_voice_page.dart';
import '../shell/page_frame.dart';
import '../settings/settings_widgets.dart';
import '../theme/app_icons.dart';

class ReadAloudSettingsPage extends ConsumerWidget {
  const ReadAloudSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final s = ref.watch(companionVoiceSettingsProvider);
    final on = s?.on ?? false;
    return AppPage.list(
      title: l10n.hubReadAloud,
      children: [
        SettingsSection(
          children: [
            SettingsSwitchTile(
              icon: AppIcons.readAloud,
              title: l10n.hubReadAloudEnable,
              subtitle: l10n.hubReadAloudEnableHint,
              value: on,
              onChanged: s == null
                  ? null
                  : (v) => unawaited(ref.read(companionVoiceSettingsProvider.notifier).update(s.copyWith(on: v))),
            ),
            SettingsTile(
              icon: AppIcons.companionVoice,
              title: l10n.hubReadAloudVoice,
              subtitle: _sourceSummary(l10n, s),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const CompanionVoicePage()),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 用的是哪种来源，一行说完，省得点进去才知道。
  String _sourceSummary(L10n l10n, CompanionVoiceSettings? s) => switch (s?.source) {
    CompanionVoiceSource.system || null => l10n.companionVoiceSystem,
    CompanionVoiceSource.preset => l10n.companionVoicePreset,
    CompanionVoiceSource.openai => l10n.companionVoiceOpenai,
    CompanionVoiceSource.custom => l10n.companionVoiceCustom,
  };
}
