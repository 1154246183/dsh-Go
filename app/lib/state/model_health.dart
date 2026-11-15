// 模型实测健康度：从插件已经发生的调用里读出「连得上吗、首字节多快」。
//
// ## 两个数据源
//
// `dsh-our-free-model` 按通道把统计分开记在两处，都要读：
//
// 1. **账号通道**（trae / cline / qoder / lobsterai …）
//    `$DSH_HOME/channel-pack/token-ledger.json`
//    键形如 `direct|trae|trae-4a55d6eb|deepseek-v4.1-flash`，
//    每项有 `requests` / `errors` / `ttftSumMs` / `ttftCount`。
//
// 2. **匿名免费通道**
//    `$DSH_HOME/our-free-model/stats.json`
//    键就是模型 id，每项有 `calls` / `failed` / `ttftMs` / `ttftSamples`。
//
// ## 为什么要把模型名归一化
//
// 两边记的是**上游模型名**（`deepseek-v4.1-flash`），而模型面板显示的是
// 目录 id（`deepseek-v4.1-flash-free`）。对不上就永远查不到数据，所以这里
// 统一归一：取最后一个 `|` 之后的部分，去掉结尾的 `-free`，转小写。
//
// ## 为什么不主动探测
//
// 插件里 `refreshCatalog({ probe: false })` 旁边写着「Automatic availability
// probing is disabled by owner policy」——作者有意关掉自动探测。这里不推翻
// 它：只读**已经真实发生过**的调用，不发任何网络请求。一个从没调用过的
// 模型没有徽标，而不是被标成不可用——「没测过」和「测过不行」是两件事。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../runtime/local_paths.dart';

/// 一个模型的实测情况（多个账号 / 通道的调用会合并）。
class ModelHealth {
  const ModelHealth({
    required this.okSamples,
    required this.failures,
    required this.avgTtftMs,
  });

  /// 成功拿到首字节的次数。
  final int okSamples;

  /// 失败次数。
  final int failures;

  /// 平均首字节耗时（毫秒）；没有样本时为空。
  final int? avgTtftMs;

  int get total => okSamples + failures;

  /// 成功率。实测里偶发失败是正常的，不要求零失败。
  double get successRate => total == 0 ? 0 : okSamples / total;

  /// 跑通过、且成功率站得住 —— 画绿框。
  bool get usable => okSamples > 0 && successRate >= 0.6;

  /// 试过但一次都没成功 —— 画红框，提示别选。
  bool get broken => okSamples == 0 && failures > 0;
}

/// 把模型名归一成可比较的键。
///
/// `direct|trae|trae-4a55d6eb|deepseek-v4.1-flash` → `deepseek-v4.1-flash`
/// `deepseek-v4.1-flash-free`                     → `deepseek-v4.1-flash`
String normalizeModelKey(String raw) {
  var key = raw;
  final bar = key.lastIndexOf('|');
  if (bar >= 0) key = key.substring(bar + 1);
  key = key.trim().toLowerCase();
  if (key.endsWith('-free')) key = key.substring(0, key.length - '-free'.length);
  return key;
}

/// 模型 id → 实测情况。
///
/// autoDispose：每次打开模型面板重新读一次，刚聊完那轮的延迟能反映出来。
final modelHealthProvider = FutureProvider.autoDispose<Map<String, ModelHealth>>((ref) {
  return _load();
});

/// 按模型 id 查实测情况，自动套用归一化（目录 id 与上游名不完全一致）。
ModelHealth? healthFor(Map<String, ModelHealth> health, String modelId) {
  return health[modelId] ?? health[normalizeModelKey(modelId)];
}

Future<Map<String, ModelHealth>> _load() async {
  final root = '${LocalPaths.home}/.dsh';
  final merged = <String, ModelHealth>{};

  void add(String rawKey, int ok, int failed, int sumMs, int count) {
    if (ok == 0 && failed == 0) return;
    final key = normalizeModelKey(rawKey);
    if (key.isEmpty) return;
    final prev = merged[key];
    merged[key] = ModelHealth(
      okSamples: (prev?.okSamples ?? 0) + ok,
      failures: (prev?.failures ?? 0) + failed,
      avgTtftMs: _weightedAvg(
        prevAvg: prev?.avgTtftMs,
        prevCount: prev?.okSamples ?? 0,
        sumMs: sumMs,
        count: count,
      ),
    );
  }

  // ① 账号通道：token-ledger.json
  final ledger = await _readJson('$root/channel-pack/token-ledger.json');
  final ledgerDays = ledger?['days'];
  if (ledgerDays is Map<String, dynamic>) {
    for (final day in ledgerDays.values) {
      if (day is! Map<String, dynamic>) continue;
      for (final entry in day.entries) {
        final v = entry.value;
        if (v is! Map<String, dynamic>) continue;
        final requests = _intOf(v['requests']);
        final errors = _intOf(v['errors']);
        final ttftCount = _intOf(v['ttftCount']);
        final ttftSum = _intOf(v['ttftSumMs']);
        // requests 含失败；ttftCount 是真正测到首字节的次数。
        final ok = ttftCount > 0 ? ttftCount : (requests - errors > 0 ? requests - errors : 0);
        add(entry.key, ok, errors, ttftSum, ttftCount);
      }
    }
  }

  // ② 匿名免费通道：stats.json
  final stats = await _readJson('$root/our-free-model/stats.json');
  final statsModels = stats?['models'];
  if (statsModels is Map<String, dynamic>) {
    for (final entry in statsModels.entries) {
      final v = entry.value;
      if (v is! Map<String, dynamic>) continue;
      final calls = _intOf(v['calls']);
      final failed = _intOf(v['failed']);
      final samples = _intOf(v['ttftSamples']);
      final sumMs = _intOf(v['ttftMs']);
      final ok = samples > 0 ? samples : (calls - failed > 0 ? calls - failed : 0);
      add(entry.key, ok, failed, sumMs, samples);
    }
  }

  return merged;
}

Future<Map<String, dynamic>?> _readJson(String path) async {
  final file = File(path);
  try {
    if (!await file.exists()) return null;
    final decoded = jsonDecode(await file.readAsString());
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    // 插件可能正在写它。读不到就当没有，不影响选模型。
    return null;
  }
}

/// 合并两个来源的平均值：按各自样本数加权。
int? _weightedAvg({int? prevAvg, required int prevCount, required int sumMs, required int count}) {
  final sum = prevAvg == null || prevCount == 0 ? 0 : prevAvg * prevCount;
  final total = prevCount + count;
  if (total == 0) return null;
  return ((sum + sumMs) / total).round();
}

int _intOf(Object? value) => value is int ? value : (value is num ? value.toInt() : 0);
