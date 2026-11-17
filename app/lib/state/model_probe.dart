import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection_state.dart';
import 'read_list_identity.dart';

/// 一次探测的结论：能答（带首字毫秒）或答不了（带原因）。
class ModelProbe {
  const ModelProbe.ok(this.ms) : ok = true, code = '', detail = '';
  const ModelProbe.failed(this.code, this.detail) : ok = false, ms = -1;

  final bool ok;

  /// 首字毫秒；失败时为 -1。
  final int ms;

  /// 失败码，例如 `RATE_LIMIT`、`INVALID_MODEL_INFO`、`TIMEOUT`。
  final String code;

  /// 失败详情，用来做 tooltip。
  final String detail;

  /// 一句话结论，给徽标显示。
  String get label {
    if (ok) return '$ms ms';
    return switch (code) {
      'TIMEOUT' => '超时',
      'EMPTY_RESPONSE' => '没内容',
      'RATE_LIMIT' => '限流',
      'QUOTA' || 'ACCOUNT_QUOTA' => '额度',
      'INVALID_CREDENTIAL' || 'MISSING_CREDENTIAL' => '密钥',
      'TRANSPORT' || 'SERVER' => '连不上',
      'INVALID_MODEL_INFO' || 'NO_ADAPTER' => '模型不存在',
      _ => '不可用',
    };
  }
}

/// `provider\u0000model`，一次探测的键。
String modelProbeKey(String provider, String model) => '$provider\u0000$model';

/// 批量测速的**全部状态与生命周期**。
///
/// 放在 state 层而不是面板里，是因为一个渠道几十个模型，串行跑要几分钟；
/// 用户关掉「选择模型」面板去别处逛一圈是常事，面板一销毁就 `setState`
/// 失败、会话也没人收拾。这里归 Riverpod 管：面板关掉不影响它跑完，
/// 再打开面板还能看到已经测出来的那部分。
class ModelProbeController extends Notifier<ModelProbeState> {
  @override
  ModelProbeState build() => const ModelProbeState.idle();

  bool _running = false;

  /// 用户按下「停止」：当前这一个测完就收手，不发新的。
  bool _stopped = false;

  /// 停掉这一轮。已经在跑的那个探测会自然收尾（它的临时会话要收拾干净），
  /// 不会再开始下一个。
  void stop() {
    if (!_running) return;
    _stopped = true;
    state = state.copyWith(running: false);
  }

  /// 逐个试 [models]：开临时会话、选中模型、发「你好」，**等到回合结束**
  /// 才下结论。只等第一个分片会误判——上游常在吐了开头之后才报错。
  Future<void> run(List<ModelInfo> models) async {
    if (_running || models.isEmpty) return;
    final conn = ref.read(readListLiveConnectionProvider);
    if (conn == null) return;
    _running = true;
    _stopped = false;
    state = ModelProbeState(total: models.length);

    for (final model in models) {
      if (_stopped || !ref.mounted) break;
      final probe = await _probeOne(conn, model);
      if (!ref.mounted) break;
      state = state.withResult(model.provider, model.id, probe);
    }

    _running = false;
    _stopped = false;
    state = state.copyWith(running: false);
  }

  Future<ModelProbe> _probeOne(HostConnection conn, ModelInfo model) async {
    String? scratch;
    StreamSubscription<DshEvent>? sub;
    try {
      scratch = (await conn.client.createSession()).sessionId;
      final done = Completer<ModelProbe>();
      final watch = Stopwatch()..start();
      var firstMs = -1;
      final text = StringBuffer();

      sub = conn.client.watch(scratch).listen((event) {
        if (done.isCompleted) return;
        switch (event) {
          case AssistantChunkEvent(:final chunk):
            if (chunk is TextDeltaChunk && chunk.text.trim().isNotEmpty) {
              if (firstMs < 0) firstMs = watch.elapsedMilliseconds;
              text.write(chunk.text);
            } else if (chunk is ReasoningDeltaChunk && chunk.text.trim().isNotEmpty) {
              if (firstMs < 0) firstMs = watch.elapsedMilliseconds;
            } else if (chunk is FinishChunk && chunk.failure != null) {
              done.complete(ModelProbe.failed(chunk.failure!.code, chunk.failure!.message));
            }
          case TurnEndedEvent(:final reason):
            if (reason.isError) {
              done.complete(ModelProbe.failed(reason.error?.code ?? 'ERROR', reason.error?.message ?? ''));
            } else if (text.toString().trim().isEmpty) {
              // 说完成了却一个字没有：这个模型给不出回答。
              done.complete(const ModelProbe.failed('EMPTY_RESPONSE', '没有内容'));
            } else {
              done.complete(ModelProbe.ok(firstMs < 0 ? watch.elapsedMilliseconds : firstMs));
            }
          default:
            break;
        }
      });

      await conn.client.setModel(scratch, provider: model.provider, model: model.id);
      await conn.client.prompt(scratch, '你好');
      return await done.future.timeout(
        const Duration(seconds: 45),
        onTimeout: () => const ModelProbe.failed('TIMEOUT', '超时'),
      );
    } on Object catch (error) {
      return ModelProbe.failed('FAILED', error.toString());
    } finally {
      await sub?.cancel();
      if (scratch != null) {
        try {
          await conn.client.cancel(scratch);
          await conn.client.deleteSessionPermanently(scratch);
        } on Object {
          // 临时会话收拾不干净也不影响结论
        }
      }
    }
  }
}

final modelProbeProvider = NotifierProvider<ModelProbeController, ModelProbeState>(ModelProbeController.new);

/// 测速进度与结果。不可变，改一次换一个新实例，面板跟着重建。
class ModelProbeState {
  const ModelProbeState({this.results = const {}, this.running = false, this.done = 0, this.total = 0});

  const ModelProbeState.idle() : results = const {}, running = false, done = 0, total = 0;

  /// `provider\u0000model` → 结论。
  final Map<String, ModelProbe> results;
  final bool running;

  /// 已经测完几个、这一轮一共几个。
  final int done;
  final int total;

  ModelProbe? of(String provider, String model) => results[modelProbeKey(provider, model)];

  ModelProbeState withResult(String provider, String model, ModelProbe probe) => ModelProbeState(
    results: {...results, modelProbeKey(provider, model): probe},
    running: running,
    done: done + 1,
    total: total,
  );

  ModelProbeState copyWith({bool? running}) =>
      ModelProbeState(results: results, running: running ?? this.running, done: done, total: total);

  /// 这一轮里能答的个数与最快首字。
  int get goodCount => results.values.where((p) => p.ok).length;
  int get badCount => results.values.where((p) => !p.ok).length;
  int? get fastestMs {
    final good = results.values.where((p) => p.ok).map((p) => p.ms);
    return good.isEmpty ? null : good.reduce((a, b) => a < b ? a : b);
  }
}
