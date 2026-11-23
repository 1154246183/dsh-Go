// 设置 › 主题 › 壁纸: the user's own wallpaper (lib/wallpaper/custom_wallpaper.dart), whether it's
// the one in use, and the picture baked for the screen it's on.

import 'dart:async';
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

  /// The stored wallpaper, once it's read.
  Future<CustomWallpaper?> get _current async {
    if (state.hasValue) return state.value;
    try {
      return await future;
    } catch (_) {
      return null;
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

/// 壁纸图库：多张图 + 「随机显示」开关。
///
/// 随机只在**冷启动**生效（[bootstrapShuffle]），不在切回前台时换——切出去
/// 再回来换一张会打断阅读。切图只换 path 与尺寸，缩放 / 位置 / 模糊 /
/// 亮度这些调好的观感留在 [CustomWallpaper] 上不动。
class WallpaperGalleryController extends AsyncNotifier<List<WallpaperShot>> {
  static const randomKey = 'wallpaper_random';

  @override
  Future<List<WallpaperShot>> build() async {
    final shots = await WallpaperGallery.load();
    await loadRandom();
    // 冷启动时若是「随机显示」，就从图库里挑一张当当前壁纸。
    unawaited(_shuffleIfRandom(shots));
    return shots;
  }

  bool _random = false;
  bool get random => _random;

  /// 读一次开关（App 起得比 prefs 快时由 UI 补调）。
  Future<void> loadRandom() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _random = prefs.getBool(randomKey) ?? false;
    } catch (_) {}
  }

  Future<void> setRandom(bool on) async {
    _random = on;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(randomKey, on);
    } catch (_) {}
    if (on) await _shuffleIfRandom(state.value ?? const []);
  }

  Future<void> _shuffleIfRandom(List<WallpaperShot> shots) async {
    if (!_random || shots.length < 2) return;
    final pick = shots[math.Random().nextInt(shots.length)];
    final current = await _current;
    if (current == null || current.path == pick.path) return;
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
    final kept = [...(state.value ?? const []), ...shots];
    final capped = kept.length > WallpaperGallery.maxShots
        ? kept.sublist(kept.length - WallpaperGallery.maxShots)
        : kept;
    state = AsyncData(capped);
    await WallpaperGallery.save(capped);
    // 第一张顺手设为当前壁纸，导完就能看到。
    final first = shots.first;
    await ref.read(customWallpaperProvider.notifier).adopt(first.path, first.width, first.height, first.edge);
    return problem;
  }

  /// 删掉图库里的一张（同时删文件）。正在用的那张不在此列：先切走。
  Future<void> remove(WallpaperShot shot) async {
    final current = await _current;
    if (current != null && current.path == shot.path) return;
    final next = [for (final s in (state.value ?? const [])) if (s != shot) s];
    state = AsyncData(next);
    await WallpaperGallery.save(next);
    await WallpaperImport.removeFile(shot.path);
  }
}

final wallpaperGalleryProvider = AsyncNotifierProvider<WallpaperGalleryController, List<WallpaperShot>>(
  WallpaperGalleryController.new,
);
