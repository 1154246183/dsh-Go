// 每个会话「最近一轮怎么结束的」，给抽屉的会话行做状态标签：
//
// * 思考中 — 这一轮正在跑（[SessionSummary.running]），或者刚提交、事件流还没到；
// * 已完成 — 最近一轮正常结束；
// * 出错了 — 最近一轮 error / interrupted，或收到该会话的 SessionErrorEvent；
// * 任务中 — 这一轮结束后后台任务还在跑（generate_video 这类）。
//
// 数据源是引擎推的事件：
// * `turn/start`、`turn/end`（带 [TurnEndReason]）—— 每个会话的 `client.watch`；
// * [SessionErrorEvent] —— 没有 turn 位置的即时失败，从 `hostEvents` 来。
//
// 待确认（approval / question）不在这里，由 `session_attention_state.dart`
// 的 [pendingInteractionsProvider] 管；行上它的优先级最高。
//
// 只记最近一轮：这不是历史记录。重启引擎后从会话列表的 running 重建。

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection_state.dart';
import 'session_attention_state.dart' show PendingKind;
import 'sessions_state.dart';

/// 一个会话最近一轮的结局。
enum SessionRunOutcome {
  /// 没有可显示的结局（还没跑过，或引擎重启后不认识）。
  idle,

  /// 正在跑。
  running,

  /// 正常结束。
  done,

  /// 失败、被中断，或收到该会话的错误事件。
  failed,
}

/// 会话行的状态标签。枚举顺序即优先级，抽屉按它挑一个显示。
enum SessionMark {
  pending,

  /// 出错了
  failed,

  /// 思考中
  thinking,

  /// 任务中
  working,

  /// 已完成
  done;

  /// 行上的文字。
  String get label => switch (this) {
    pending => '待确认',
    failed => '出错了',
    thinking => '思考中',
    working => '任务中',
    done => '已完成',
  };
}

/// 一个会话当前的运行状态。
class SessionRunState {
  const SessionRunState({
    this.outcome = SessionRunOutcome.idle,
    this.jobs = 0,
    this.error = '',
  });

  final SessionRunOutcome outcome;

  /// 这一轮结束后还在跑的后台任务数。
  final int jobs;

  /// [SessionRunOutcome.failed] 时的原因，给详情用；行上只显示「出错了」。
  final String error;

  SessionRunState copyWith({
    SessionRunOutcome? outcome,
    int? jobs,
    String? error,
  }) => SessionRunState(
    outcome: outcome ?? this.outcome,
    jobs: jobs ?? this.jobs,
    error: error ?? this.error,
  );
}

/// 会话 id → 当前运行状态。订阅每个会话的事件流。
class SessionRunStateController extends Notifier<Map<String, SessionRunState>> {
  final Map<String, StreamSubscription<DshEvent>> _subs = {};
  StreamSubscription<HostEvent>? _hostSub;
  DshClient? _client;

  @override
  Map<String, SessionRunState> build() {
    final conn = ref.watch(activeConnectionProvider).value;
    _reset();
    final client = conn?.client;
    _client = client;
    if (client == null) return const {};
    _hostSub = client.hostEvents.listen(_onHostEvent, onError: (Object _) {});

    // 订阅跟着会话列表走：新会话订阅上，走掉的取消。
    ref.listen<AsyncValue<List<SessionSummary>>>(
      sessionsProvider,
      (_, next) {
        final list = next.value;
        if (list != null) _sync(list);
      },
      fireImmediately: true,
    );

    ref.onDispose(_reset);
    return const {};
  }

  void _reset() {
    for (final sub in _subs.values) {
      unawaited(sub.cancel());
    }
    _subs.clear();
    unawaited(_hostSub?.cancel());
    _hostSub = null;
    _client = null;
  }

  /// 让订阅跟着会话列表走，并把列表说的 running 先记上。
  void _sync(List<SessionSummary> list) {
    final client = _client;
    if (client == null) return;
    final live = {for (final s in list) s.sessionId};
    for (final id in [..._subs.keys]) {
      if (live.contains(id)) continue;
      unawaited(_subs.remove(id)?.cancel());
      if (!state.containsKey(id)) continue;
      state = {...state}..remove(id);
    }
    for (final id in live) {
      if (_subs.containsKey(id)) continue;
      try {
        _subs[id] = client.watch(id).listen(
          (event) => _onSessionEvent(id, event),
          onError: (Object _) {},
        );
      } catch (_) {
        // 拿不到事件流的会话不标状态，不影响列表本身。
      }
    }
    // 列表说在跑的，先当 running（事件可能比列表慢一拍）。
    var next = state;
    var changed = false;
    for (final s in list) {
      if (!s.running) continue;
      final cur = next[s.sessionId];
      if (cur != null && cur.outcome == SessionRunOutcome.running) continue;
      next = {
        ...next,
        s.sessionId: (cur ?? const SessionRunState()).copyWith(
          outcome: SessionRunOutcome.running,
          error: '',
        ),
      };
      changed = true;
    }
    if (changed) state = next;
  }

  void _onSessionEvent(String sessionId, DshEvent event) {
    switch (event) {
      case TurnStartedEvent():
        _put(
          sessionId,
          _of(sessionId).copyWith(
            outcome: SessionRunOutcome.running,
            error: '',
          ),
        );
      case TurnEndedEvent(:final reason):
        final failed = reason.isError || reason.kind == 'interrupted';
        _put(
          sessionId,
          _of(sessionId).copyWith(
            outcome: failed ? SessionRunOutcome.failed : SessionRunOutcome.done,
            error: failed ? _reasonText(reason) : '',
          ),
        );
      default:
        break;
    }
  }

  /// 失败原因：结构化的 error 优先，其次是被中断。
  String _reasonText(TurnEndReason reason) {
    final failure = reason.error;
    if (failure != null) {
      final message = failure.message.trim();
      if (message.isNotEmpty) return message;
      return failure.code;
    }
    return reason.kind == 'interrupted' ? '本轮被中断' : '本轮失败';
  }

  void _onHostEvent(HostEvent event) {
    if (event is! SessionErrorEvent) return;
    _put(
      event.sessionId,
      _of(event.sessionId).copyWith(
        outcome: SessionRunOutcome.failed,
        error: event.message,
      ),
    );
  }

  SessionRunState _of(String sessionId) =>
      state[sessionId] ?? const SessionRunState();

  void _put(String sessionId, SessionRunState value) {
    state = {...state, sessionId: value};
  }

  /// 这一轮结束后，后台任务还剩几个。媒体插件提交视频后 turn 就结束了，
  /// 拿结果之前它一直在跑（`meta['dsh-go/media']` 的 job）。
  void setJobs(String sessionId, int count) {
    _put(sessionId, _of(sessionId).copyWith(jobs: count < 0 ? 0 : count));
  }

  /// 清掉一个会话的失败标记（人看过之后）。
  void clearError(String sessionId) {
    final cur = state[sessionId];
    if (cur == null || cur.outcome != SessionRunOutcome.failed) return;
    _put(
      sessionId,
      cur.copyWith(
        outcome: cur.jobs > 0 ? SessionRunOutcome.done : SessionRunOutcome.idle,
        error: '',
      ),
    );
  }
}

final sessionRunStateProvider =
    NotifierProvider<SessionRunStateController, Map<String, SessionRunState>>(
  SessionRunStateController.new,
);

/// 抽屉行显示哪个标记。待确认压过一切，其余按 [SessionMark] 的枚举顺序。
///
/// [unreadHint] 是列表自己的「有新进展」提示：没有事件可依时（比如这一轮
/// 是在上次启动时跑完的），它至少能说是「已完成」。
SessionMark? sessionMarkOf(
  Map<String, SessionRunState> runs,
  Map<String, PendingKind> pending,
  String sessionId, {
  required bool unreadHint,
}) {
  if (pending.containsKey(sessionId)) return SessionMark.pending;
  final run = runs[sessionId];
  if (run != null) {
    switch (run.outcome) {
      case SessionRunOutcome.failed:
        return SessionMark.failed;
      case SessionRunOutcome.running:
        return SessionMark.thinking;
      case SessionRunOutcome.done:
        return run.jobs > 0 ? SessionMark.working : SessionMark.done;
      case SessionRunOutcome.idle:
        if (run.jobs > 0) return SessionMark.working;
    }
  }
  return unreadHint ? SessionMark.done : null;
}
