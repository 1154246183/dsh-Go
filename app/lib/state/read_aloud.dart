// 对话朗读：把一条回复交给伙伴小屋那套语音（本机语音 / 内置多家 API /
// 自定义 OpenAI 兼容接口 / 任意 HTTP），并对外暴露"正在读哪一条"。
//
// 为什么不直接用 CompanionSpeaker：它的排队与"按句切分"是给伙伴角色
// 连续说话的，一次只该有一段在响。对话里朗读是一条消息一个按钮，谁点
// 谁说话，点第二条就把第一条掐掉——这里包一层，管住"当前是谁"。

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../companion/companion_voice.dart';
import '../companion/companion_voice_source.dart';

/// 谁在说话。
class ReadAloudState {
  const ReadAloudState({this.speakingId, this.preparing = false, this.error});

  /// 正在读的那条消息的 id；null 表示没在读。
  final String? speakingId;

  /// 已在取音频、还没出声（外部语音要等一次网络往返）。
  final bool preparing;

  /// 上一次失败的原因（短句，给 tooltip 用）。
  final String? error;

  bool speaks(String id) => speakingId == id;

  ReadAloudState copyWith({String? speakingId, bool? preparing, String? error, bool clearError = false}) =>
      ReadAloudState(
        speakingId: speakingId ?? this.speakingId,
        preparing: preparing ?? this.preparing,
        error: clearError ? null : (error ?? this.error),
      );

  static const idle = ReadAloudState();
}

class ReadAloudController extends Notifier<ReadAloudState> {
  StreamSubscription<CompanionVoiceEvent>? _events;
  String? _current;

  @override
  ReadAloudState build() {
    ref.onDispose(() {
      unawaited(_events?.cancel());
      _events = null;
    });
    return ReadAloudState.idle;
  }

  CompanionSpeaker get _speaker => ref.read(companionSpeakerProvider);

  /// 开始读 [text]（[id] 是消息的稳定标识）；同一条再点一次就是停。
  Future<void> toggle(String id, String text) async {
    if (_current == id) {
      await stop();
      return;
    }
    final settings = ref.read(companionVoiceSettingsProvider);
    if (settings == null) {
      state = const ReadAloudState(error: 'not-ready');
      return;
    }
    // 换人说话：先把上一条掐掉，避免两条叠在一起。
    await stop();
    _current = id;
    state = ReadAloudState(speakingId: id, preparing: true);

    _listen();
    final ok = await _speaker.ready(settings);
    if (_current != id) return; // 等待期间被停掉或换掉了
    if (!ok) {
      _current = null;
      state = const ReadAloudState(error: 'not-configured');
      return;
    }
    state = state.copyWith(preparing: false, clearError: true);
    _speaker.speak(id, text, flush: true);
  }

  Future<void> stop() async {
    _current = null;
    state = ReadAloudState.idle;
    _speaker.stop();
  }

  /// 播放结束（done/stopped/error 事件）就把状态收回，让按钮复位。
  void _listen() {
    _events ??= _speaker.events.listen((event) {
      if (event.id != _current) return;
      switch (event.type) {
        case CompanionVoiceEventType.done ||
            CompanionVoiceEventType.stopped ||
            CompanionVoiceEventType.error:
          _current = null;
          state = ReadAloudState.idle;
        case CompanionVoiceEventType.start ||
            CompanionVoiceEventType.range ||
            CompanionVoiceEventType.fallback:
          break;
      }
    });
  }
}

final readAloudProvider = NotifierProvider<ReadAloudController, ReadAloudState>(ReadAloudController.new);
