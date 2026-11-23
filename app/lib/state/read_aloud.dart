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

  /// 这次朗读切成了几块（`id`, `id#1`, …）；只有最后一块播完才复位。
  int _chunks = 1;

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
    // 长回复整段丢给外部语音，服务端常按上限截断（听感就是只读了开头）。
    // 这里按句切开逐条排队：CompanionSpeaker 本来就会顺序播，切句还能让
    // 第一句更快出声。
    final lines = splitForSpeech(text);
    if (lines.isEmpty) {
      _current = null;
      state = ReadAloudState.idle;
      return;
    }
    _chunks = lines.length;
    for (final (i, line) in lines.indexed) {
      _speaker.speak(i == 0 ? id : '$id#$i', line, flush: i == 0);
    }
  }

  Future<void> stop() async {
    _current = null;
    state = ReadAloudState.idle;
    _speaker.stop();
  }

  /// 播放结束就把状态收回，让按钮复位。
  ///
  /// 长文本按句切成 `id`、`id#1`、`id#2`…，只有**最后一块**播完才算读完；
  /// 中间句子结束时不改状态，否则第一句说完按钮就复位了，后面的还在响。
  void _listen() {
    _events ??= _speaker.events.listen((event) {
      final current = _current;
      if (current == null) return;
      final isBase = event.id == current;
      final isChunk = event.id.startsWith('$current#');
      if (!isBase && !isChunk) return;
      switch (event.type) {
        case CompanionVoiceEventType.done ||
            CompanionVoiceEventType.stopped ||
            CompanionVoiceEventType.error:
          final index = isBase ? 0 : (int.tryParse(event.id.split('#').last) ?? 0);
          if (index + 1 >= _chunks) {
            _current = null;
            state = ReadAloudState.idle;
          }
        case CompanionVoiceEventType.start ||
            CompanionVoiceEventType.range ||
            CompanionVoiceEventType.fallback:
          break;
      }
    });
  }
}

final readAloudProvider = NotifierProvider<ReadAloudController, ReadAloudState>(ReadAloudController.new);

/// 把一段回复切成适合逐条合成的片段。
///
/// 为什么切：整段丢给外部语音服务，长文常被服务端按上限截断；切句还能让
/// 第一句更早出声。按句末标点切，再按 [maxChars] 合并，避免一句一个请求
/// 把接口打得太碎。
List<String> splitForSpeech(String text, {int maxChars = 120}) {
  final clean = text.replaceAll(RegExp(r'\r\n?'), '\n').trim();
  if (clean.isEmpty) return const [];

  // 先按句末标点切开（保留标点）。
  final sentences = <String>[];
  final buffer = StringBuffer();
  const ends = {'。', '！', '？', '!', '?', '…', '\n', '；', ';'};
  for (final rune in clean.runes) {
    final ch = String.fromCharCode(rune);
    buffer.write(ch);
    if (ends.contains(ch)) {
      final piece = buffer.toString().trim();
      if (piece.isNotEmpty) sentences.add(piece);
      buffer.clear();
    }
  }
  final tail = buffer.toString().trim();
  if (tail.isNotEmpty) sentences.add(tail);

  // 再按 maxChars 合并，过长的一句单独再切。
  final out = <String>[];
  final current = StringBuffer();
  void flush() {
    final piece = current.toString().trim();
    if (piece.isNotEmpty) out.add(piece);
    current.clear();
  }

  for (final s in sentences) {
    if (s.length > maxChars) {
      flush();
      // 超长句按字数硬切，尽量在逗号处断开。
      var rest = s;
      while (rest.length > maxChars) {
        var cut = rest.lastIndexOf(RegExp('[，,、]'), maxChars);
        if (cut <= 0) cut = maxChars;
        out.add(rest.substring(0, cut + 1).trim());
        rest = rest.substring(cut + 1).trim();
      }
      if (rest.isNotEmpty) out.add(rest);
      continue;
    }
    if (current.length + s.length > maxChars) flush();
    current.write(s);
  }
  flush();
  return out;
}
