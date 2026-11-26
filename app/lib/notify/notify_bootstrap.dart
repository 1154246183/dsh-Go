import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'notify_channel.dart';

/// 启动时把系统通知权限要到手。
///
/// 为什么需要这段：iOS 的 设置 › 通知 里只会列出**申请过**通知权限的 App。
/// 在此之前 DSH 只在「设置 › 通知」页里按需调 `openSettings`，那条路径要求
/// 用户先摸到那一页；结果装完一直没申请过，系统设置里压根找不到 DSH，
/// 通知也就永远发不出来。
///
/// 只在第一次启动问一次（结果记在 prefs 里）：iOS 的授权对话框本来就只弹
/// 一次，之后只能去系统设置里改，所以这里不需要、也不该反复请求。
abstract final class NotifyBootstrap {
  static const _key = 'notify.permission_asked';

  /// 申请一次；之前问过就什么都不做。
  ///
  /// 失败一律吞掉：拿不到通知权限不该挡住 App 启动。
  static Future<void> ensure() async {
    // 只有 iOS 需要这一步：Android 由系统在通道里自己处理权限，
    // HarmonyOS 有它自己的弹窗时机。
    if (!Platform.isIOS) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_key) ?? false) return;
      final granted = await NotifyChannel().requestPermission();
      await prefs.setBool(_key, true);
      debugPrint('notify: 首次申请通知权限 -> $granted');
    } catch (error) {
      debugPrint('notify: 申请权限失败 $error');
    }
  }
}
