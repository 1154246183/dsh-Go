// 任务完成的提示音。
//
// 音频本身编进 App（assets/sounds/dsh-chime.wav），Dart 只负责读字节并交给
// 原生播放：iOS 走 `dsh/app` 的 playChime（AVAudioPlayer），其它平台没有这个
// 方法时安静地什么也不做——提示音不是功能，缺失不该报错，也不该挡住横幅。
//
// 为什么字节过通道而不是让原生自己找文件：资源由 Flutter 打进
// App.framework 的 flutter_assets 里，Xcode 的 Runner target 看不到那条路径，
// 在 pbxproj 里另加一个 resource 反而更脆。

import 'dart:async';

import 'package:flutter/services.dart';

/// 一次播放请求的去重窗口：同一批事件里横幅只出现一次，声音也只响一次。
const _dedupe = Duration(milliseconds: 400);

class CompletionChime {
  CompletionChime({MethodChannel? channel, AssetBundle? bundle})
    : _channel = channel ?? const MethodChannel('dsh/app'),
      _bundle = bundle ?? rootBundle;

  final MethodChannel _channel;
  final AssetBundle _bundle;

  /// 只在内存里留一份：一段 78 KB 的 WAV，重读一次也就是一次 IO。
  ByteData? _cached;
  DateTime? _last;
  Future<void>? _loading;

  /// 播一次。任何失败都吞掉：没有原生实现（桌面、测试）就是静音。
  Future<void> play() async {
    final now = DateTime.now();
    if (_last case final last? when now.difference(last) < _dedupe) return;
    _last = now;
    final bytes = await _load();
    if (bytes == null) return;
    // 不在主 isolate 上等结果：播放本身是毫秒级的，但通道往返不该挡住首帧。
    unawaited(() async {
      try {
        await _channel.invokeMethod<void>('playChime', {'bytes': bytes});
      } on MissingPluginException {
        // 这个平台没有原生播放：静音即可。
      } on PlatformException {
        // 会话被占用、音频服务没起来：同样不该冒泡成可见错误。
      }
    }());
  }

  Future<ByteData?> _load() async {
    if (_cached case final cached?) return cached;
    // 横幅可能连续来几次；并发进入时共用同一次读取。
    if (_loading case final pending?) {
      await pending;
      return _cached;
    }
    final completer = Completer<void>();
    _loading = completer.future;
    try {
      final data = await _bundle.load(_asset);
      _cached = ByteData.view(data.buffer, data.offsetInBytes, data.lengthInBytes);
      return _cached;
    } catch (_) {
      return null;
    } finally {
      _loading = null;
      completer.complete();
    }
  }

  static const _asset = 'assets/sounds/dsh-chime.wav';
}
