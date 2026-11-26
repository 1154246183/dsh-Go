import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'dev/frame_probe.dart';
import 'diagnostics/app_error_log.dart';
import 'launch/launch_state.dart';
import 'launch/startup_trace.dart';
import 'notify/notify_bootstrap.dart';
import 'runtime/builtin_plugins.dart';
import 'runtime/local_paths.dart';
import 'state/locale_state.dart';
import 'ui/common/third_party_licenses.dart';
import 'ui/settings/font_licenses.dart';
import 'ui/theme/theme.dart';

Future<void> main() => runWithFrameProbe(_startApp);

Future<void> _startApp() async {
  if (!frameProbeEnabled) SteadyFrameBinding();
  WidgetsFlutterBinding.ensureInitialized();
  appErrorCapture.install();
  appErrorLog.onRecord = (record) => StartupTrace.error(record.message);
  StartupTrace.mark('main, ${kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug')}');
  // The first frame is already in the chosen language (设置 → 语言), and is the launch
  // window's own picture (启动画面, lib/launch/launch_state.dart).
  await Future.wait([
    StartupTrace.step('language', AppLanguageController.load),
    StartupTrace.step('launch screen', LaunchController.begin, onLate: LaunchController.giveUp),
    StartupTrace.step('paths', LocalPaths.load),
  ]);
  // 把随包内置的插件补进本机引擎 profile。引擎建 profile 可能要等几秒，
  // 所以这里不等它：注入在后台重试，失败也只写日志，不影响启动。
  unawaited(StartupTrace.step('builtin plugins', BuiltinPlugins.ensure));
  // iOS：第一次启动把通知权限要到手，否则 设置 › 通知 里永远没有这个 App，
  // 任务完成的通知也就发不出去。等第一帧之后再问，别挡住界面。
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(StartupTrace.step('notify permission', NotifyBootstrap.ensure));
  });
  // MIT / OFL notices must ship with the APK, not just the sources.
  registerThirdPartyLicenses();
  registerFontLicenses();
  // Edge-to-edge with transparent system bars; pages refine the icon brightness
  // through AnnotatedRegion(dshSystemOverlay(...)).
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(dshSystemOverlay(PlatformDispatcher.instance.platformBrightness));
  StartupTrace.mark('runApp');
  runApp(const ProviderScope(child: DshApp()));
  WidgetsBinding.instance.addPostFrameCallback((_) => StartupTrace.mark('first frame'));
}
