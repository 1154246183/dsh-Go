// 设置 › 主题 › 壁纸: the user's own wallpaper (lib/wallpaper/custom_wallpaper.dart), whether it's
// the one in use, and the picture baked for the screen it's on.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui' show Brightness;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../performance/performance_state.dart';
import '../wallpaper/custom_wallpaper.dart';
import '../wallpaper/wallpaper_import.dart';
import '../wallpaper/wallpaper_render.dart';

export '../wallpaper/wallpaper_import.dart' show LaunchImportProblem;

final wallpaperImportProvider = Provider<WallpaperImport>((ref) => WallpaperImport());

/// Bakes for the backdrop and the settings' small phones; keeps the last decoded picture.
final wallpaperRendererProvider = Provider<WallpaperRenderer>((ref) {
  final renderer = WallpaperRenderer();
  ref.onDispose(renderer.release);
  return renderer;
});

/// The stored wallpaper (null: none chosen yet, or its file is gone).
final customWallpaperProvider = AsyncNotifierProvider<CustomWallpaperController, CustomWallpaper?>(
  CustomWallpaperController.new,
);

class CustomWallpaperController extends AsyncNotifier<CustomWallpaper?> {
  @override
  Future<CustomWallpaper?> build() => CustomWallpaper.load();

  /// The system picker; the pick becomes the wallpaper in use. Null when it did, else why not
  /// ([LaunchImportProblem.cancelled] included).
  Future<LaunchImportProblem?> choose() async {
    final previous = await _current;
    final (wallpaper, problem) = await ref.read(wallpaperImportProvider).pick(previous: previous);
    if (wallpaper == null) return problem ?? LaunchImportProblem.unreadable;
    await _store(wallpaper);
    return null;
  }

  /// 最近一次确实读到/写过的那份。用来兜住 load() 偶发失败（iOS 容器路径
  /// 解析、文件刚被系统挪动）：这种时候 state 是 null，若直接按「没有壁纸」
  /// 新建一份，用户调好的缩放/位置就全被洗掉了。
  CustomWallpaper? _known;

  /// The stored wallpaper, once it's read.
  Future<CustomWallpaper?> get _current async {
    if (state.hasValue) {
      final v = state.value;
      if (v != null) _known = v;
      return v ?? _known;
    }
    try {
      final v = await future;
      if (v != null) _known = v;
      return v ?? _known;
    } catch (_) {
      return _known;
    }
  }

  /// The custom one in use (true) or the default backdrop (false); the picture stays either way.
  Future<void> use(bool custom) async {
    final current = await _current;
    if (current == null || current.on == custom) return;
    await _store(current.copyWith(on: custom));
  }

  /// Where the screen sits in the picture.
  Future<void> frame({required double zoom, required double alignX, required double alignY}) async {
    final current = await _current;
    if (current == null) return;
    await _store(
      current.copyWith(
        zoom: zoom.clamp(1.0, CustomWallpaper.maxZoom),
        alignX: alignX.clamp(-1.0, 1.0),
        alignY: alignY.clamp(-1.0, 1.0),
      ),
    );
  }

  Future<void> setBlur(double blur) async {
    final current = await _current;
    if (current == null || current.blur == blur) return;
    await _store(current.copyWith(blur: blur.clamp(0.0, 1.0)));
  }

  /// 提亮 (light mode) or 压暗 (dark mode).
  Future<void> setTone(Brightness brightness, double tone) async {
    final current = await _current;
    if (current == null || current.toneFor(brightness) == tone) return;
    await _store(current.withTone(brightness, tone.clamp(0.0, 1.0)));
  }

  /// 「壁纸亮度」：把自动遮罩按比例退掉多少（0 保持可读性保护，1 全退）。
  Future<void> setPop(double pop) async {
    final current = await _current;
    if (current == null || current.pop == pop) return;
    await _store(current.copyWith(pop: pop.clamp(0.0, 1.0)));
  }

  /// 换成图库里的另一张：只换 path 与尺寸，缩放 / 位置 / 模糊 / 亮度
  /// 这些观感沿用当前这份，切图不会把调好的样子打回默认。
  Future<void> adopt(String path, int width, int height, int? edge) async {
    final current = await _current;
    final next = current == null
        ? CustomWallpaper(path: path, width: width, height: height, edge: edge)
        : current.replacedBy(path: path, width: width, height: height, edge: edge);
    await _store(next.copyWith(on: true));
  }

  Future<void> _store(CustomWallpaper wallpaper) async {
    _known = wallpaper;
    state = AsyncData(wallpaper);
    await CustomWallpaper.save(wallpaper);
  }
}

/// The wallpaper baked for [WallpaperFrame]; null: the default backdrop (none chosen, switched
/// off, or the picture can't be read — the page never breaks over it).
final wallpaperImageProvider = FutureProvider.autoDispose.family<ui.Image?, WallpaperFrame>((ref, frame) async {
  final CustomWallpaper? wallpaper;
  try {
    wallpaper = await ref.watch(customWallpaperProvider.future);
  } catch (_) {
    return null;
  }
  if (wallpaper == null || !wallpaper.on) return null;
  final lightweight = ref.watch(performanceDefaultsProvider.select((p) => p.lightweight));
  final image = await ref.read(wallpaperRendererProvider).bake(wallpaper, frame.copyWith(lightweight: lightweight));
  if (!ref.mounted) {
    image?.dispose();
    return null;
  }
  if (image != null) ref.onDispose(image.dispose);
  return image;
});

/// 壁纸图库：多张图 + 轮换。
///
/// 轮换有两种触发，都由 [rotateOn] 这一个开关管：
///  - 进入会话页 / 设置页时换一张（[rotateOnEnter]）——换得勤，但只在页面
///    刚进来时换，滚动阅读中不动；
///  - 开着 App 时按 [interval] 定时换（[_syncTicker]），到点才换。
///
/// 切图只换 path 与尺寸；缩放 / 位置 / 模糊 / 亮度这些调好的观感留在
/// [CustomWallpaper] 上不动（见 `replacedBy` 的 keepFraming）。
class WallpaperGalleryController extends AsyncNotifier<List<WallpaperShot>> {
  static const rotateKey = 'wallpaper_rotate';
  static const intervalKey = 'wallpaper_rotate_secs';

  /// 旧版本只有「随机显示」，升级时把它的值继承过来。
  static const legacyRandomKey = 'wallpaper_random';

  /// 可选间隔（秒）：15 秒 / 1 / 5 / 15 / 30 分钟 / 1 / 3 小时。
  static const intervals = <int>[15, 60, 300, 900, 1800, 3600, 10800];
  static const defaultInterval = 300;

  Timer? _ticker;

  @override
  Future<List<WallpaperShot>> build() async {
    final shots = await WallpaperGallery.load();
    await _loadPrefs();
    ref.onDispose(() {
      _ticker?.cancel();
      _ticker = null;
    });
    // 冷启动先换一张：开着轮换就该每次打开看到不一样的。
    unawaited(_shuffle());
    _syncTicker();
    return shots;
  }

  bool _rotateOn = false;
  bool get rotateOn => _rotateOn;

  int _interval = defaultInterval;
  int get interval => _interval;

  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _rotateOn = prefs.getBool(rotateKey) ?? prefs.getBool(legacyRandomKey) ?? false;
      final secs = prefs.getInt(intervalKey);
      _interval = secs != null && intervals.contains(secs) ? secs : defaultInterval;
    } catch (_) {}
  }

  /// 由 [wallpaperRotateProvider] 推过来：开关或间隔变了，重建定时器。
  /// 设置本身存在那个 provider 的 prefs 键里，这里只管「什么时候换」。
  Future<void> applySettings({required bool on, required int interval}) async {
    final wasOn = _rotateOn;
    _rotateOn = on;
    _interval = interval;
    _syncTicker();
    // 从关到开立刻换一张，别让用户等到第一个间隔。
    if (!wasOn && on) await _shuffle();
  }

  /// 进入某个页面时调一次：开着轮换就换一张。
  Future<void> rotateOnEnter() async {
    if (!_rotateOn) return;
    await _shuffle();
  }

  /// 开关或间隔一变就重建定时器。
  void _syncTicker() {
    _ticker?.cancel();
    _ticker = null;
    if (!_rotateOn) return;
    final shots = state.value;
    if (shots == null || shots.length < 2) return;
    _ticker = Timer.periodic(Duration(seconds: _interval), (_) {
      unawaited(_shuffle());
    });
  }


  /// 随机挑一张**和当前不同的**换上去。
  ///
  /// 以前是「挑到同一张就 return」：图库只有两张时有一半概率什么都不发生，
  /// 看着就像功能坏了。现在从「除当前那张以外」里挑。
  Future<void> _shuffle() async {
    final shots = state.value ?? const <WallpaperShot>[];
    if (shots.length < 2) return;
    final current = await _current;
    // 跳过当前那张，也跳过文件已经不在了的：换上去读不出来，画面就退回
    // 默认底色，看着像「取景丢了」。
    final pool = [
      for (final s in shots)
        if ((current == null || s.path != current.path) && File(s.path).existsSync()) s,
    ];
    if (pool.isEmpty) return;
    final pick = pool[math.Random().nextInt(pool.length)];
    await ref
        .read(customWallpaperProvider.notifier)
        .adopt(pick.path, pick.width, pick.height, pick.edge);
  }

  Future<CustomWallpaper?> get _current async {
    try {
      return await ref.read(customWallpaperProvider.future);
    } catch (_) {
      return null;
    }
  }

  /// 多选导入，追加到图库（不删已有文件）。
  Future<LaunchImportProblem?> addMany() async {
    final (shots, problem) = await ref.read(wallpaperImportProvider).pickMany();
    if (shots.isEmpty) return problem ?? LaunchImportProblem.unreadable;
    final kept = [...(state.value ?? const <WallpaperShot>[]), ...shots];
    final capped = kept.length > WallpaperGallery.maxShots
        ? kept.sublist(kept.length - WallpaperGallery.maxShots)
        : kept;
    state = AsyncData(capped);
    await WallpaperGallery.save(capped);
    // 第一张顺手设为当前壁纸，导完就能看到。
    final first = shots.first;
    await ref.read(customWallpaperProvider.notifier).adopt(first.path, first.width, first.height, first.edge);
    // 够两张了，定时器该起来了。
    _syncTicker();
    return problem;
  }

  /// 删掉图库里的一张（同时删文件）。正在用的那张不在此列：先切走。
  Future<void> remove(WallpaperShot shot) async {
    final current = await _current;
    if (current != null && current.path == shot.path) return;
    final next = [for (final s in (state.value ?? const <WallpaperShot>[])) if (s != shot) s];
    state = AsyncData(next);
    await WallpaperGallery.save(next);
    await WallpaperImport.removeFile(shot.path);
    // 剩不到两张就不该再轮换了。
    if (next.length < 2) {
      _ticker?.cancel();
      _ticker = null;
    }
  }
}

/// 间隔的名字（设置页的下拉用）。
String rotateIntervalLabel(int seconds, bool zh) => switch (seconds) {
  15 => zh ? '15 秒' : '15 s',
  60 => zh ? '1 分钟' : '1 min',
  300 => zh ? '5 分钟' : '5 min',
  900 => zh ? '15 分钟' : '15 min',
  1800 => zh ? '30 分钟' : '30 min',
  3600 => zh ? '1 小时' : '1 h',
  10800 => zh ? '3 小时' : '3 h',
  _ => '${seconds}s',
};

final wallpaperGalleryProvider = AsyncNotifierProvider<WallpaperGalleryController, List<WallpaperShot>>(
  WallpaperGalleryController.new,
);

/// 轮换设置（开关 + 间隔），界面直接 watch 它。
///
/// 单独一份状态，不塞进图库的 state：图库里每张 [WallpaperShot] 都有 ==，
/// 内容没变时 Riverpod 判定状态相等，开关切了界面不会重画。
class WallpaperRotateSettings {
  const WallpaperRotateSettings({this.on = false, this.interval = WallpaperGalleryController.defaultInterval});

  final bool on;
  final int interval;

  WallpaperRotateSettings copyWith({bool? on, int? interval}) =>
      WallpaperRotateSettings(on: on ?? this.on, interval: interval ?? this.interval);

  @override
  bool operator ==(Object other) => other is WallpaperRotateSettings && other.on == on && other.interval == interval;

  @override
  int get hashCode => Object.hash(on, interval);
}

class WallpaperRotateController extends Notifier<WallpaperRotateSettings> {
  @override
  WallpaperRotateSettings build() {
    unawaited(_load());
    return const WallpaperRotateSettings();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final on =
          prefs.getBool(WallpaperGalleryController.rotateKey) ??
          prefs.getBool(WallpaperGalleryController.legacyRandomKey) ??
          false;
      final secs = prefs.getInt(WallpaperGalleryController.intervalKey);
      final interval = secs != null && WallpaperGalleryController.intervals.contains(secs)
          ? secs
          : WallpaperGalleryController.defaultInterval;
      state = WallpaperRotateSettings(on: on, interval: interval);
    } catch (_) {}
  }

  Future<void> setOn(bool on) async {
    state = state.copyWith(on: on);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(WallpaperGalleryController.rotateKey, on);
    } catch (_) {}
    await _sync();
  }

  Future<void> setInterval(int seconds) async {
    if (!WallpaperGalleryController.intervals.contains(seconds)) return;
    state = state.copyWith(interval: seconds);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(WallpaperGalleryController.intervalKey, seconds);
    } catch (_) {}
    await _sync();
  }

  /// 把设置推给图库控制器，让它重建定时器。
  Future<void> _sync() async {
    final gallery = ref.read(wallpaperGalleryProvider.notifier);
    await gallery.applySettings(on: state.on, interval: state.interval);
    if (state.on) await gallery.rotateOnEnter();
  }
}

final wallpaperRotateProvider = NotifierProvider<WallpaperRotateController, WallpaperRotateSettings>(
  WallpaperRotateController.new,
);
