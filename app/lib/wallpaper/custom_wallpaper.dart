// 自定义壁纸：用户选的一张图片，铺在首页、对话和抽屉后面。文件在 App 私有目录
// （`<support>/wallpaper/`），设置存在 shared_preferences 的 `wallpaper_custom`（一条 JSON）。
//
// 取景（缩放 + 位置）按屏幕比例存成相对值，换屏幕尺寸、横竖屏都还对得上；模糊一份，
// 提亮（浅色）和压暗（深色）各一份。

import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart' show immutable;
import 'package:shared_preferences/shared_preferences.dart';

import '../runtime/container_paths.dart';

/// The user's wallpaper and how it sits.
class CustomWallpaper {
  const CustomWallpaper({
    required this.path,
    required this.width,
    required this.height,
    this.edge,
    this.zoom = 1,
    this.alignX = 0,
    this.alignY = 0,
    this.blur = defaultBlur,
    this.lighten = defaultLighten,
    this.dim = defaultDim,
    this.pop = defaultPop,
    this.on = true,
  });

  /// Files over this are refused (the system picker's budget, too).
  static const maxBytes = 15 * 1024 * 1024;

  /// The closest it zooms in: a fifth of the picture across the screen.
  static const maxZoom = 5.0;

  static const defaultBlur = 0.3;
  static const defaultLighten = 0.2;
  static const defaultDim = 0.2;
  static const defaultPop = 0.0;

  static const prefsKey = 'wallpaper_custom';

  /// The copy in the app's own storage.
  final String path;

  /// Pixel size of the picture (its first frame).
  final int width;
  final int height;

  /// The colour along the picture's edges (ARGB), read on import; drawn while it loads.
  final int? edge;

  /// 1: the picture just covers the screen; up to [maxZoom].
  final double zoom;

  /// Where the screen sits in the picture, -1 (left / top edge) to 1, like an [Alignment].
  final double alignX;
  final double alignY;

  /// 0–1: how soft the picture is ([WallpaperLook.blurSigma]).
  final double blur;

  /// 0–1: the page's own colour laid over the picture, in light mode ([lighten]) and in dark
  /// mode ([dim]). Text keeps its contrast whatever these say ([WallpaperLook]).
  final double lighten;
  final double dim;

  /// 0–1: 把自动遮罩按比例退掉多少，让壁纸本身更亮更清楚。
  ///
  /// 自动遮罩是为了让文字达到 4.6:1 对比度、按像素算出来的；偏亮、花纹多的
  /// 图会被压得很重，即使「压暗」是 0%（wallpaper_look.dart 的 bound）。
  /// 这一项不解那套计算，只在合成时把遮罩按比例让开，由人自己决定要不要
  /// 牺牲一点对比度换壁纸的可见度。1 = 遮罩全退。
  final double pop;

  /// In use. Off: the default backdrop, with this one kept to switch back to.
  final bool on;

  /// [lighten] or [dim], for a page in [brightness].
  double toneFor(Brightness brightness) => brightness == Brightness.dark ? dim : lighten;

  /// The part of the picture (its pixels) a [screen]-shaped window shows.
  Rect window(Size screen) => windowIn(Size(width.toDouble(), height.toDouble()), screen);

  /// The same window in a picture [picture] large (a downscaled decode of it).
  Rect windowIn(Size picture, Size screen) {
    if (picture.isEmpty || screen.isEmpty) return Offset.zero & picture;
    final cover = (picture.width / picture.height > screen.width / screen.height)
        ? Size(picture.height * screen.width / screen.height, picture.height)
        : Size(picture.width, picture.width * screen.height / screen.width);
    final z = zoom.clamp(1.0, maxZoom);
    final seen = Size(cover.width / z, cover.height / z);
    final spareX = picture.width - seen.width;
    final spareY = picture.height - seen.height;
    return Rect.fromLTWH(
      spareX / 2 * (1 + alignX.clamp(-1.0, 1.0)),
      spareY / 2 * (1 + alignY.clamp(-1.0, 1.0)),
      seen.width,
      seen.height,
    );
  }

  CustomWallpaper copyWith({
    double? zoom,
    double? alignX,
    double? alignY,
    double? blur,
    double? lighten,
    double? dim,
    double? pop,
    bool? on,
  }) => CustomWallpaper(
    path: path,
    width: width,
    height: height,
    edge: edge,
    zoom: zoom ?? this.zoom,
    alignX: alignX ?? this.alignX,
    alignY: alignY ?? this.alignY,
    blur: blur ?? this.blur,
    lighten: lighten ?? this.lighten,
    dim: dim ?? this.dim,
    pop: pop ?? this.pop,
    on: on ?? this.on,
  );

  /// [tone] as the value for [brightness].
  CustomWallpaper withTone(Brightness brightness, double tone) =>
      brightness == Brightness.dark ? copyWith(dim: tone) : copyWith(lighten: tone);

  /// A new picture in place of this one. 观感（亮度、模糊、圆角亮度）一律留着。
  ///
  /// 位置（zoom / alignX / alignY）默认也留着：轮换壁纸时如果把取景一起清掉，
  /// 用户每换一张就得重新调一次位置，等于「调整位置」白调了。真要重新取景，
  /// 传 [keepFraming] = false。
  CustomWallpaper replacedBy({
    required String path,
    required int width,
    required int height,
    int? edge,
    bool keepFraming = true,
  }) =>
      CustomWallpaper(
        path: path,
        width: width,
        height: height,
        edge: edge,
        zoom: keepFraming ? zoom : 1,
        alignX: keepFraming ? alignX : 0,
        alignY: keepFraming ? alignY : 0,
        blur: blur,
        lighten: lighten,
        dim: dim,
        pop: pop,
      );

  Map<String, Object?> toJson() => {
    'path': path,
    'width': width,
    'height': height,
    'edge': ?edge,
    'zoom': zoom,
    'alignX': alignX,
    'alignY': alignY,
    'blur': blur,
    'lighten': lighten,
    'dim': dim,
    'pop': pop,
    'on': on,
  };

  static CustomWallpaper? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final path = raw['path'];
    final width = raw['width'];
    final height = raw['height'];
    if (path is! String || path.isEmpty || width is! int || height is! int || width <= 0 || height <= 0) {
      return null;
    }
    double unit(Object? v, double fallback, {double lo = 0, double hi = 1}) =>
        v is num && v.isFinite ? v.toDouble().clamp(lo, hi) : fallback;
    final edge = raw['edge'];
    return CustomWallpaper(
      path: path,
      width: width,
      height: height,
      edge: edge is int ? edge : null,
      zoom: unit(raw['zoom'], 1, lo: 1, hi: maxZoom),
      alignX: unit(raw['alignX'], 0, lo: -1),
      alignY: unit(raw['alignY'], 0, lo: -1),
      blur: unit(raw['blur'], defaultBlur),
      lighten: unit(raw['lighten'], defaultLighten),
      dim: unit(raw['dim'], defaultDim),
      pop: unit(raw['pop'], defaultPop),
      on: raw['on'] != false,
    );
  }

  /// The stored wallpaper (in use or not), or null (none, unreadable, or its file is gone).
  static Future<CustomWallpaper?> load([SharedPreferences? prefs]) async {
    try {
      final store = prefs ?? await SharedPreferences.getInstance();
      final raw = store.getString(prefsKey);
      if (raw == null) return null;
      var json = Map<String, Object?>.from(jsonDecode(raw) as Map);
      final paths = ContainerPaths.enabled ? await ContainerPaths.load() : null;
      if (paths != null) {
        final relocated = await paths.decodeOwned(json, 'wallpaper');
        if (relocated == null) return null;
        json = relocated;
      }
      final wallpaper = fromJson(json);
      if (wallpaper == null || !File(wallpaper.path).existsSync()) return null;
      if (paths != null) {
        final saved = jsonEncode(await paths.encodeOwned(wallpaper.toJson(), 'wallpaper'));
        if (saved != raw) {
          try {
            await store.setString(prefsKey, saved);
          } catch (_) {
            // A migrated in-memory value remains usable if preferences cannot be written.
          }
        }
      }
      return wallpaper;
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(CustomWallpaper wallpaper) async {
    final prefs = await SharedPreferences.getInstance();
    final json = ContainerPaths.enabled
        ? await (await ContainerPaths.load()).encodeOwned(wallpaper.toJson(), 'wallpaper')
        : wallpaper.toJson();
    await prefs.setString(prefsKey, jsonEncode(json));
  }

  @override
  bool operator ==(Object other) =>
      other is CustomWallpaper &&
      other.path == path &&
      other.width == width &&
      other.height == height &&
      other.edge == edge &&
      other.zoom == zoom &&
      other.alignX == alignX &&
      other.alignY == alignY &&
      other.blur == blur &&
      other.lighten == lighten &&
      other.dim == dim &&
      other.pop == pop &&
      other.on == on;

  @override
  int get hashCode => Object.hash(path, width, height, edge, zoom, alignX, alignY, blur, lighten, dim, pop, on);
}

/// 壁纸图库里的一张：只要渲染需要的三样，视觉参数（缩放、位置、模糊、
/// 亮度）由「当前这张」那份 [CustomWallpaper] 统管，切图时不动。
@immutable
class WallpaperShot {
  const WallpaperShot({required this.path, required this.width, required this.height, this.edge});

  final String path;
  final int width;
  final int height;

  /// 图边缘的平均色（ARGB），加载时先垫着。
  final int? edge;

  Map<String, Object?> toJson() => {'path': path, 'width': width, 'height': height, 'edge': ?edge};

  static WallpaperShot? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final path = raw['path'];
    final width = raw['width'];
    final height = raw['height'];
    if (path is! String || path.isEmpty || width is! int || height is! int || width <= 0 || height <= 0) return null;
    final edge = raw['edge'];
    return WallpaperShot(path: path, width: width, height: height, edge: edge is int ? edge : null);
  }

  @override
  bool operator ==(Object other) =>
      other is WallpaperShot && other.path == path && other.width == width && other.height == height && other.edge == edge;

  @override
  int get hashCode => Object.hash(path, width, height, edge);
}

/// 壁纸图库：多张图，随机显示从这里挑。存在自己的 prefs 键里，
/// 与「当前这张」的 [CustomWallpaper] 分开——切图只换 path，不动调好的观感。
abstract final class WallpaperGallery {
  static const prefsKey = 'wallpaper_gallery';

  /// 最多留这么多张：再多也翻不过来，还白占磁盘。
  static const maxShots = 24;

  static Future<List<WallpaperShot>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw == null) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final item in decoded)
          if (WallpaperShot.fromJson(item) case final shot?) shot,
      ];
    } catch (_) {
      return const [];
    }
  }

  static Future<void> save(List<WallpaperShot> shots) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        prefsKey,
        jsonEncode([for (final s in shots) s.toJson()]),
      );
    } catch (_) {}
  }
}
