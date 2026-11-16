// 设置 → 能力 → GitHub 构建密钥。
//
// 两个固定槽：一个是常用账号，一个是备用。Keychain 存 PAT，prefs 只留账号名
// 和默认仓库。填好之后，会话里可以直接用 `githubBuildAccounts()` 看到
// 「有哪个账号、跑哪个仓库」，真正需要密钥时才 `tokenFor(slot)` 取，用完即弃。
//
// 页面上不显示已存的密钥：只显示「已保存（ghp_…abcd）」，改要重新输入。这不
// 是为了安全表演——Keychain 里的是唯一的一份，界面读回来只会在截图、录屏和
// 无障碍朗读里多一次泄漏机会。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'shell/page_frame.dart';
import '../state/github_accounts.dart';
import 'theme/app_icons.dart';
import 'theme/theme.dart';
import 'settings/settings_widgets.dart';

class GitHubBuildAccountsPage extends ConsumerStatefulWidget {
  const GitHubBuildAccountsPage({super.key});

  @override
  ConsumerState<GitHubBuildAccountsPage> createState() => _GitHubBuildAccountsPageState();
}

class _GitHubBuildAccountsPageState extends ConsumerState<GitHubBuildAccountsPage> {
  final _controllers = <int, _SlotControllers>{};
  bool _loading = true;
  int? _savingSlot;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final accounts = await ref.read(githubAccountsProvider).load();
    if (!mounted) return;
    setState(() {
      for (final a in accounts) {
        _controllers[a.slot] = _SlotControllers(a);
      }
      _loading = false;
    });
  }

  Future<void> _save(int slot) async {
    final c = _controllers[slot];
    if (c == null) return;
    final repo = c.repo.text.trim();
    if (repo.isNotEmpty && !repo.contains('/')) {
      setState(() => _error = '仓库要写成 owner/repo，例如 w753951/dsh-Go');
      return;
    }
    setState(() {
      _savingSlot = slot;
      _error = null;
      _notice = null;
    });
    try {
      await c.persist(slot, ref.read(githubAccountsProvider));
      ref.invalidate(githubAccountsListProvider);
      if (!mounted) return;
      setState(() {
        _notice = '账户 $slot 已保存';
        c.clearTokenField();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '保存失败：$e');
    } finally {
      if (mounted) setState(() => _savingSlot = null);
    }
  }

  Future<void> _clear(int slot) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('清除账户 $slot？'),
        content: const Text('这会删掉 Keychain 里的密钥，以及这栏的账号名和仓库。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('清除')),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(githubAccountsProvider).clear(slot);
    ref.invalidate(githubAccountsListProvider);
    if (!mounted) return;
    setState(() {
      _controllers[slot]?.clearAll();
      _notice = '账户 $slot 已清除';
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = DshColors.of(context);
    // 键盘弹起时补一块底部留白，密钥框才能滚到键盘上方，不被挡住。
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    if (_loading) {
      return AppPage.list(
        title: 'GitHub 构建',
        children: const [
          Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
        ],
      );
    }
    return AppPage.list(
      title: 'GitHub 构建',
      children: [
        SettingsSection(
          children: [
            SettingsTile(
              icon: AppIcons.terminal,
              tint: 4, // SettingsHues.abilities；直接写值避免 import settings_screen（它会 import 本页）
              title: '让会话用你的账号跑构建',
              subtitle: '填好后，会话能读到账号和默认仓库，并在需要时用对应密钥触发 GitHub Actions。密钥存在 Keychain，不进对话记录。',
              chevron: false,
            ),
            for (final slot in const [1, 2]) _slotCard(slot),
            if (_error case final e?)
              Padding(
                padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 4, SettingsMetrics.inset, 8),
                child: Text(e, style: TextStyle(color: colors.danger, fontSize: 13)),
              ),
            if (_notice case final n?)
              Padding(
                padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 4, SettingsMetrics.inset, 8),
                child: Text(n, style: TextStyle(color: colors.success, fontSize: 13)),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 8, SettingsMetrics.inset, 14),
              child: Text(
                '密钥只需要 repo（读写 Actions、内容）权限。细粒度的 github_pat_… 或经典的 ghp_… 都可以。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.textTertiary, height: 1.5),
              ),
            ),
          ],
        ),
        // 键盘高度 + 一点余量：最后那个输入框（密钥）能滚到键盘上方。
        SizedBox(height: keyboard > 0 ? keyboard + 24 : 0),
      ],
    );
  }

  Widget _slotCard(int slot) {
    final c = _controllers[slot]!;
    final saving = _savingSlot == slot;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 10, SettingsMetrics.inset, 2),
          child: Row(
            children: [
              Text(
                slot == 1 ? '账户 1（常用）' : '账户 2（备用）',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              if (c.hasSavedToken)
                Text(
                  c.maskedToken,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
            ],
          ),
        ),
        _field(controller: c.login, label: '账号名', hint: 'w753951', keyboard: TextInputType.text),
        _field(
          controller: c.repo,
          label: '默认仓库',
          hint: 'w753951/dsh-Go',
          keyboard: TextInputType.url,
          autocorrect: false,
        ),
        _field(
          controller: c.note,
          label: '备注',
          hint: '例如：主账号，跑 dsh-Go 的 iOS 构建',
          keyboard: TextInputType.text,
          optional: true,
        ),
        _tokenField(c),
        Padding(
          padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 8, SettingsMetrics.inset, 14),
          child: Row(
            children: [
              FilledButton(
                onPressed: saving ? null : () => _save(slot),
                child: saving
                    ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('保存'),
              ),
              const SizedBox(width: 12),
              TextButton(
                onPressed: saving ? null : () => _clear(slot),
                child: const Text('清除'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required String hint,
    TextInputType? keyboard,
    bool autocorrect = false,
    bool optional = false,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 4, SettingsMetrics.inset, 4),
      child: TextField(
        controller: controller,
        keyboardType: keyboard,
        autocorrect: autocorrect,
        enableSuggestions: autocorrect,
        decoration: InputDecoration(labelText: optional ? '$label（可选）' : label, hintText: hint, isDense: true),
      ),
    );
  }

  Widget _tokenField(_SlotControllers c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 4, SettingsMetrics.inset, 4),
      child: TextField(
        controller: c.token,
        obscureText: c.obscure,
        autocorrect: false,
        enableSuggestions: false,
        style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 13),
        decoration: InputDecoration(
          labelText: '密钥（PAT）',
          hintText: c.hasSavedToken ? '已保存，留空则不修改' : 'ghp_… 或 github_pat_…',
          isDense: true,
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: Icon(c.obscure ? AppIcons.showSecret : AppIcons.hideSecret, size: 20),
                onPressed: () => setState(() => c.obscure = !c.obscure),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One slot's text fields and what was loaded into them.
class _SlotControllers {
  _SlotControllers(GitHubAccount account)
    : login = TextEditingController(text: account.login),
      repo = TextEditingController(text: account.repo),
      note = TextEditingController(text: account.note),
      token = TextEditingController(),
      hasSavedToken = account.token.isNotEmpty,
      maskedToken = _mask(account.token);

  final TextEditingController login;
  final TextEditingController repo;
  final TextEditingController note;
  final TextEditingController token;

  /// Whether the Keychain held a token when this page opened (or after a save).
  bool hasSavedToken;
  String maskedToken;
  bool obscure = true;

  static String _mask(String token) {
    if (token.isEmpty) return '';
    final tail = token.length <= 4 ? '' : token.substring(token.length - 4);
    final head = token.startsWith('github_pat_')
        ? 'github_pat_…'
        : token.startsWith('ghp_')
        ? 'ghp_…'
        : '…';
    return '已保存 $head$tail';
  }

  /// Writes what the fields hold. An empty token field keeps the saved one.
  Future<void> persist(int slot, GitHubAccounts accounts) async {
    final typed = token.text.trim();
    await accounts.save(GitHubAccount(
      slot: slot,
      login: login.text.trim(),
      repo: repo.text.trim(),
      note: note.text.trim(),
      token: typed.isEmpty ? (hasSavedToken ? await accounts.tokenFor(slot) : '') : typed,
    ));
    if (typed.isNotEmpty) {
      hasSavedToken = true;
      maskedToken = _mask(typed);
    }
  }

  /// After a save: the field must not keep holding the key in memory.
  void clearTokenField() => token.clear();

  void clearAll() {
    login.clear();
    repo.clear();
    note.clear();
    token.clear();
    hasSavedToken = false;
    maskedToken = '';
  }

  void dispose() {
    login.dispose();
    repo.dispose();
    note.dispose();
    token.dispose();
  }
}
