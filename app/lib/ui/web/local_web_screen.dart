import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/runtime_bridge.dart';
import '../../runtime/runtime_state.dart';
import '../../runtime/local_footprint.dart';
import '../../state/engine_control.dart';
import '../../state/settings_state.dart';
import '../common/empty_view.dart';
import '../common/progress_halo.dart';
import '../engine/engine_screen.dart';
import '../engine/engine_status.dart';
import '../onboarding/local_install.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'web_target.dart';
import 'web_view_page.dart';

/// `http://127.0.0.1:3080/?token=…` — the official DSH Web UI's launch URL.
Uri localWebUri(String baseUrl, String token) =>
    Uri.parse(baseUrl).replace(path: '/', queryParameters: {'token': token});

/// The official DSH Web UI served by the local engine: the fallback for anything
/// the native UI doesn't do yet (plugins, advanced settings…).
class LocalWebScreen extends ConsumerWidget {
  const LocalWebScreen({super.key, this.target, this.handle, this.link, this.onSession});

  /// Page to land on (a session, a panel, a settings section…).
  final DshWebTarget? target;

  /// 网页模式: the page is the app's home; [handle] takes the back button's
  /// seat (and a place in the engine page's bar while the engine is down).
  final Widget Function(double size)? handle;

  /// See [WebViewPage.link] and [WebViewPage.onSession].
  final DshWebLink? link;
  final ValueChanged<String?>? onSession;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(localRuntimeProvider.select((s) => s.status));
    final phoneLayout = ref.watch(settingsProvider.select((s) => s.webPhoneLayout));
    // 网页版总开关（设置 › 模型 › 网页版）。关着就**根本不建 WebView**：
    // WebView 一起来就是一个独立的 WebContent 进程，常驻几十到上百 MB，
    // iOS 15 上很容易撞 per-process-limit 被系统杀掉。这里提前返回，
    // 连 localWebUri 都不算，引擎那边也不会被拉起来。
    final webEnabled = ref.watch(settingsProvider.select((s) => s.webEnabled));
    if (!webEnabled) {
      return _WebDisabled(handle: handle);
    }
    if (status.isRunning) {
      return WebViewPage(
        // A restart issues a new token, and the layout switch applies on
        // load: rebuild the WebView for either.
        key: ValueKey((status.token, phoneLayout)),
        url: localWebUri(status.baseUrl!, status.token!),
        title: context.l10n.webTitle,
        subtitle: context.l10n.commonThisPhone,
        externalDisabledReason: context.l10n.webLocalAppOnly,
        dshWeb: true,
        phoneLayout: phoneLayout,
        openTarget: target,
        leading: handle,
        root: handle != null,
        link: link,
        onSession: onSession,
      );
    }
    return _NotRunning(handle: handle);
  }
}

/// 网页版总开关关着时看到的这一页。
///
/// 不建 WebView、不连引擎 —— 只有这样才真的省下那份内存。
/// 这里不直接替用户打开开关：那等于悄悄把内存花回去。给一句话、
/// 一个去设置的路，点不点由人定。
class _WebDisabled extends ConsumerWidget {
  const _WebDisabled({this.handle});

  final Widget Function(double size)? handle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    // 这一页原来左右两个返回键都点不动 —— 不是某一个键坏了，是整页的
    // 点击都没落到控件上。所以把两个箭头全删掉：留着一个坏掉的键比没有更糟。
    //
    // 出口改到右上角（跟别的页面的操作位一致，那里本来就有玻璃圆钮，
    // 点击是通的）：
    //   · 还在栈里 → pop 回上一层；
    //   · 已经在最底层 → popUntilFirst，一定回得到对话页。
    // 再包一层 PopScope(canPop: true)，iOS 的边缘返回手势也能用。
    void close() {
      final navigator = Navigator.of(context);
      if (navigator.canPop()) {
        navigator.pop();
      } else {
        navigator.popUntil((route) => route.isFirst);
      }
    }

    return PopScope(
      canPop: true,
      child: AppPage(
        title: l10n.commonWeb,
        showLargeTitle: false,
        actions: [
          // 网页模式当主页时，返回键由外面给；别的入口没有。
          ?handle?.call(44),
          GlassIconButton(icon: AppIcons.close, tooltip: l10n.commonClose, onPressed: close),
        ],
        slivers: [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 80),
              child: Center(
                child: EmptyView(
                  icon: AppIcons.webApp,
                  title: l10n.webDisabledTitle,
                  message: l10n.webDisabledBody,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
class _NotRunning extends ConsumerWidget {
  const _NotRunning({this.handle});

  final Widget Function(double size)? handle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(localRuntimeProvider);
    final phase = state.status.phase;
    final busy = phase == RuntimePhase.starting || phase == RuntimePhase.installing;
    final canStart = phase == RuntimePhase.installed || phase == RuntimePhase.error;
    final failed = phase == RuntimePhase.error;
    // Nothing on this phone: the one way forward is installing it (or, on a
    // build without the runtime, a remote host).
    final missing = state.status.runtimeMissing;
    final missingCopy = localMissingCopy(context.l10n, available: state.available);
    return AppPage(
      title: context.l10n.commonWeb,
      showLargeTitle: false,
      actions: [
        ?handle?.call(44),
        GlassIconButton(
          icon: AppIcons.engine,
          tooltip: context.l10n.webEngineStatus,
          // As the home (网页模式) it stays underneath; as a page it gives way.
          onPressed: () {
            final route = MaterialPageRoute<void>(builder: (_) => const EngineScreen());
            final navigator = Navigator.of(context);
            unawaited(handle != null ? navigator.push(route) : navigator.pushReplacement(route));
          },
        ),
      ],
      slivers: [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 80),
            child: Center(
              child: AnimatedSwitcher(
                duration: AppMotion.of(context, AppMotion.standard),
                switchInCurve: AppMotion.std,
                switchOutCurve: AppMotion.std,
                child: EmptyView(
                  key: ValueKey(phase),
                  art: busy ? const ProgressHalo(size: 96, strokeWidth: 3) : null,
                  icon: failed
                      ? AppIcons.error
                      : missing
                      ? AppIcons.thisPhone
                      : AppIcons.webApp,
                  title: phase == RuntimePhase.installing
                      ? context.l10n.shellRuntimePreparing
                      : busy
                      ? context.l10n.webEngineStarting
                      : failed
                      ? context.l10n.webEngineStartFailed
                      : missing
                      ? missingCopy.title
                      : context.l10n.webEngineNotRunning,
                  message: failed
                      ? (humanizeRuntimeError(state.status.error) ?? context.l10n.webEngineProblem)
                      : busy
                      ? context.l10n.webStartingSoon
                      : missing
                      ? null
                      : context.l10n.webStartToOpen,
                  action: missing
                      ? FilledButton(
                          style: FilledButton.styleFrom(minimumSize: const Size(160, 44)),
                          onPressed: () => unawaited(openLocalInstall(context)),
                          child: Text(missingCopy.action),
                        )
                      : canStart
                      ? FilledButton(
                          style: FilledButton.styleFrom(minimumSize: const Size(160, 44)),
                          onPressed: () => unawaited(EngineControl.ensureStarted(ProviderScope.containerOf(context))),
                          child: Text(failed ? context.l10n.webRestart : context.l10n.webStartEngine),
                        )
                      : null,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
