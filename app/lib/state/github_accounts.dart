// GitHub 构建密钥：两个账户槽，PAT 存在 Keychain 里，不写进 prefs、不进提示词。
//
// 用途是把「去 GitHub 跑一次构建」这类操作从会话里的手写脚本收进来：会话通过
// `githubBuildAccounts()` 拿到账户名和默认仓库（**不含 PAT**），真正调用时用
// [GitHubCredential.tokenFor] 取密钥，用完即弃。
//
// 为什么两个固定槽而不是列表：这个人就两个账户，固定槽让「主账号/副账号」
// 一眼分得清，也省掉增删排序的界面。槽名参与 Keychain 的键名，改名会丢密钥。

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../secrets/secure_storage.dart';

/// One saved account. [token] is only ever held in memory for the call that
/// needs it; the persisted form keeps it in the Keychain.
class GitHubAccount {
  const GitHubAccount({
    required this.slot,
    this.login = '',
    this.token = '',
    this.repo = '',
    this.note = '',
  });

  /// 1 or 2: which fixed slot this is.
  final int slot;

  /// The account name shown in the list (`w753951`); empty until filled.
  final String login;

  /// Classic PAT (`ghp_…`) or fine-grained (`github_pat_…`).
  final String token;

  /// `owner/repo` the build runs in, e.g. `w753951/dsh-Go`.
  final String repo;

  /// Free text: what this account is for.
  final String note;

  bool get configured => token.isNotEmpty && repo.isNotEmpty;
  bool get hasRepo => repo.contains('/');

  GitHubAccount copyWith({String? login, String? token, String? repo, String? note}) => GitHubAccount(
    slot: slot,
    login: login ?? this.login,
    token: token ?? this.token,
    repo: repo ?? this.repo,
    note: note ?? this.note,
  );
}

/// What the conversation may see: no tokens.
typedef GitHubAccountSummary = ({int slot, String login, String repo, String note, bool usable});

class GitHubAccounts {
  static const _prefKey = 'github_accounts_v1';
  static String _tokenKey(int slot) => 'github_token_$slot';

  final AppSecureStorage _storage;
  GitHubAccounts([AppSecureStorage? storage]) : _storage = storage ?? const AppSecureStorage();

  /// Two slots, slot 1 first.
  Future<List<GitHubAccount>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefKey);
    final saved = <int, ({String login, String repo, String note})>{};
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            final slot = int.tryParse('${entry.key}');
            final v = entry.value;
            if (slot == null || v is! Map) continue;
            saved[slot] = (
              login: '${v['login'] ?? ''}',
              repo: '${v['repo'] ?? ''}',
              note: '${v['note'] ?? ''}',
            );
          }
        }
      } catch (_) {
        // 坏掉的偏好不是错误：当作没配过，密钥仍在 Keychain 里，重填一次即可。
      }
    }
    final out = <GitHubAccount>[];
    for (final slot in const [1, 2]) {
      final meta = saved[slot];
      String token = '';
      try {
        token = await _storage.read(key: _tokenKey(slot)) ?? '';
      } catch (_) {
        // Keychain 打不开（首次解锁前、迁移失败）：当作没密钥。
      }
      out.add(GitHubAccount(
        slot: slot,
        login: meta?.login ?? '',
        token: token,
        repo: meta?.repo ?? '',
        note: meta?.note ?? '',
      ));
    }
    return out;
  }

  /// Saves one slot: the metadata to prefs, the token to the Keychain. An empty
  /// token clears the saved one.
  Future<void> save(GitHubAccount account) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefKey);
    final map = <String, Object?>{};
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final e in decoded.entries) {
            map['${e.key}'] = e.value;
          }
        }
      } catch (_) {}
    }
    map['${account.slot}'] = {'login': account.login, 'repo': account.repo, 'note': account.note};
    await prefs.setString(_prefKey, jsonEncode(map));
    if (account.token.isEmpty) {
      await _storage.delete(key: _tokenKey(account.slot));
    } else {
      await _storage.write(key: _tokenKey(account.slot), value: account.token);
    }
  }

  Future<void> clear(int slot) async {
    await save(GitHubAccount(slot: slot));
  }

  /// The token for the call that needs it. Throws when the slot has none.
  Future<String> tokenFor(int slot) async {
    final token = await _storage.read(key: _tokenKey(slot));
    if (token == null || token.isEmpty) {
      throw StateError('GitHub 账户 $slot 还没有填密钥');
    }
    return token;
  }

  /// What a conversation may read: who and where, never the key.
  Future<List<GitHubAccountSummary>> summaries() async {
    final accounts = await load();
    return [
      for (final a in accounts)
        (slot: a.slot, login: a.login, repo: a.repo, note: a.note, usable: a.configured),
    ];
  }
}

final githubAccountsProvider = Provider<GitHubAccounts>((_) => GitHubAccounts());

/// The two slots, re-read after any save.
final githubAccountsListProvider = FutureProvider<List<GitHubAccount>>(
  (ref) => ref.watch(githubAccountsProvider).load(),
);

/// 会话能看到的摘要（无密钥）。没有账户时返回空列表。
Future<List<GitHubAccountSummary>> githubBuildAccounts() =>
    const GitHubAccounts().summaries();
