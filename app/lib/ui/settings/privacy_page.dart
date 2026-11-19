// 隐私与分享: what leaves this phone — the links you shared, a configuration
// to share, anonymous usage statistics, and (when the host has it) the chat
// log upload to DeepSeek. On HarmonyOS, while the saved credentials can't be
// read, also the way to clear them.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/credential_recovery.dart';
import '../../state/engine_settings_state.dart';
import '../engine_settings/namespace_copy.dart';
import '../engine_settings/schema_form.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'backup_page.dart';
import '../share_code/profile_share_sheet.dart';
import '../share_hosted/hosted_links_tile.dart';
import '../shell/page_frame.dart';
import 'credential_recovery_dialog.dart';
import 'settings_widgets.dart';
import 'usage_stats_section.dart';

class PrivacyPage extends ConsumerWidget {
  const PrivacyPage({super.key});

  static const logNamespace = 'session-log-deepseek';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final engine = ref.watch(engineSettingsProvider).value;
    return AppPage.list(
      title: l10n.hubPrivacy,
      children: [
        SettingsSection(
          title: l10n.hubPrivacySharing,
          children: [
            const HostedLinksSettingsTile(icon: false),
            SettingsTile(spot: Spots.shareConfig, onTap: () => unawaited(showShareProfileSheet(context))),
          ],
        ),
        if (ref.watch(credentialsUnreadableProvider).value ?? false)
          SettingsSection(
            title: l10n.harmonyCredentialsSection,
            children: [
              SettingsTile(
                title: l10n.harmonyCredentialsClear,
                subtitle: l10n.harmonyCredentialsUnreadable,
                danger: true,
                onTap: () => unawaited(confirmCredentialRecovery(context, ref)),
              ),
            ],
          ),
        // 备份与还原: 设置里的参数存成一个文件,换机、重装、试错之后能搬回来。
        // 放在这一页的最后:它和「什么会离开这台手机」不是一回事,但它是
        // 设置里唯一谈「数据怎么处理」的地方,搁在这儿最好找。会话不进备份。
        SettingsSection(
          title: '备份',
          footer: Text(
            '把界面、模型与主机配置、预设、技能、App 偏好存成一个文件；不备份聊天会话。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: DshColors.of(context).textTertiary,
            ),
          ),
          children: [
            SettingsTile(
              icon: AppIcons.archive,
              spot: Spots.backup,
              onTap: () => unawaited(
                Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const BackupPage()),
                ),
              ),
            ),
          ],
        ),
        const UsageStatsSection(),
        if (engine != null && engine.served(logNamespace))
          ...schemaFormGroups([
            SchemaFormSection(
              title: l10n.engineGeneralData,
              fields: [
                SchemaFieldSpec(logNamespace, const ['enabled'], copy: copyOf(logNamespace, const ['enabled'])),
              ],
            ),
          ], settings: engine),
      ],
    );
  }
}
