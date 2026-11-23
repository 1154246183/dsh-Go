import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';
import '../performance/performance_state.dart';
import '../secrets/secure_storage.dart';
import 'provider_keys.dart';
import 'read_list_epoch.dart';

/// 按 [allow] 设定屏幕方向：开 = 跟随手机转，关 = 钉在竖屏。
///
/// iOS 上这由引擎侧的系统调用完成，方向本身仍受 Info.plist 里声明的几种
/// 约束（竖屏、左横、右横）。启动时和开关变化时都调一次。
Future<void> applyScreenOrientation(bool allow) => SystemChrome.setPreferredOrientations(
  allow
      ? const [
          DeviceOrientation.portraitUp,
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]
      : const [DeviceOrientation.portraitUp],
);

/// User settings: the DeepSeek API key (and custom-provider keys, see
/// [ProviderKeyVault]) live in the Android Keystore-backed secure storage;
/// plain preferences go to SharedPreferences.
class AppSettings {
  const AppSettings({
    this.apiKey = '',
    this.themeMode = ThemeMode.system,
    this.autoStartLocal = true,
    this.autoStartLocalExplicit = true,
    this.autoApproveCommands = false,
    this.phoneStorage = false,
    this.webEnabled = false,
    this.webPhoneLayout = true,
    this.hardwareEnterSends = false,
    this.chatTextScale = 1.0,
    this.foldCompletedTurns = true,
    this.visualReplies = true,
    this.allowLandscape = true,
    this.glassOpacity = 0,
    this.customProviderIds = const {},
    this.loaded = false,
  });

  final String apiKey;
  final ThemeMode themeMode;

  /// Start the local DSH automatically when the app opens.
  final bool autoStartLocal;

  /// A stored user choice. Policy defaults never create this preference.
  final bool autoStartLocalExplicit;

  /// New local sessions use DSH's `danger-full-access` preset (commands run without asking).
  /// Off by default: there is no sandbox on Android, so each command escalation asks first.
  final bool autoApproveCommands;

  /// Mount the phone's shared storage at /sdcard in the Linux environment.
  final bool phoneStorage;

  /// 网页版总开关。**默认关**。
  ///
  /// 关着时 `LocalWebScreen` 不去碰引擎的 Web 服务，也不创建 WebView ——
  /// 后者一起来就是一个独立的 `WebContent` 进程，常驻几十到上百 MB，
  /// iOS 15 上很容易撞 per-process-limit 被系统杀掉。原生界面不走这条路，
  /// 所以平时留着它只是白占内存。
  ///
  /// 打开之后和原来完全一样：入口照旧，WebView 照旧。
  /// 这是「我要用网页版，所以愿意付这份内存」的显式选择。
  final bool webEnabled;

  /// Fit the embedded DSH Web to a phone (`assets/web/`). Off shows the
  /// official layout untouched, e.g. to check a plugin that restyles it.
  final bool webPhoneLayout;

  /// Hardware Enter sends; Shift+Enter and the software keyboard still insert newlines.
  final bool hardwareEnterSends;

  /// Size of chat content relative to the system setting (header and
  /// composer keep theirs). One of [chatTextScales].
  final double chatTextScale;

  /// A normally finished turn folds its thinking, tool calls and interim
  /// messages into one summary line above the answer (DSH Web's default).
  final bool foldCompletedTurns;

  /// Tell the local DSH it may answer with ```dsh-ui views (charts, cards,
  /// options): a section of the managed AGENTS.md, written at engine start.
  /// Off only drops the instructions; views that arrive are still drawn.
  final bool visualReplies;

  /// Follow the phone into landscape. Off pins the app to portrait, so turning
  /// the device (or laying it flat) never rotates the chat under a thumb.
  final bool allowLandscape;

  /// 卡片 / 气泡的玻璃再加多少不透明度，0–1（0 = 原样）。
  ///
  /// 壁纸调亮后，暗色下 card/pill 只有 white@5–6%，背景一透出来字就糊；
  /// 这个值由「壁纸 › 卡片不透明度」调，越大字越稳、壁纸越不明显。
  final double glassOpacity;

  /// Custom providers created on the local engine whose key is kept on the
  /// phone ([ProviderKeyVault]). Known at launch, before the engine runs, so
  /// the first-run gate can tell "has a model to talk to" without it.
  final Set<String> customProviderIds;
  final bool loaded;

  bool get hasApiKey => apiKey.trim().isNotEmpty;

  /// A DeepSeek key or a custom provider on the local engine.
  bool get hasModelAccess => hasApiKey || customProviderIds.isNotEmpty;

  AppSettings copyWith({
    String? apiKey,
    ThemeMode? themeMode,
    bool? autoStartLocal,
    bool? autoStartLocalExplicit,
    bool? autoApproveCommands,
    bool? phoneStorage,
    bool? webEnabled,
    bool? webPhoneLayout,
    bool? hardwareEnterSends,
    double? chatTextScale,
    bool? foldCompletedTurns,
    bool? visualReplies,
    bool? allowLandscape,
    double? glassOpacity,
    Set<String>? customProviderIds,
    bool? loaded,
  }) => AppSettings(
    apiKey: apiKey ?? this.apiKey,
    themeMode: themeMode ?? this.themeMode,
    autoStartLocal: autoStartLocal ?? this.autoStartLocal,
    autoStartLocalExplicit: autoStartLocalExplicit ?? this.autoStartLocalExplicit,
    autoApproveCommands: autoApproveCommands ?? this.autoApproveCommands,
    phoneStorage: phoneStorage ?? this.phoneStorage,
    webEnabled: webEnabled ?? this.webEnabled,
    webPhoneLayout: webPhoneLayout ?? this.webPhoneLayout,
    hardwareEnterSends: hardwareEnterSends ?? this.hardwareEnterSends,
    chatTextScale: chatTextScale ?? this.chatTextScale,
    foldCompletedTurns: foldCompletedTurns ?? this.foldCompletedTurns,
    visualReplies: visualReplies ?? this.visualReplies,
    allowLandscape: allowLandscape ?? this.allowLandscape,
    glassOpacity: glassOpacity ?? this.glassOpacity,
    customProviderIds: customProviderIds ?? this.customProviderIds,
    loaded: loaded ?? this.loaded,
  );
}

/// Chat text sizes offered in settings: (scale, label).
List<(double, String)> get chatTextScales => [
  (0.9, appL10n.stateSizeSmall),
  (1.0, appL10n.stateSizeStandard),
  (1.15, appL10n.stateSizeLarge),
  (1.3, appL10n.stateSizeExtraLarge),
];

class SettingsController extends Notifier<AppSettings> {
  static const _apiKeyKey = 'deepseek_api_key';
  static const _themeKey = 'theme_mode';
  static const _autoStartKey = 'auto_start_local';
  static const _autoApproveKey = 'auto_approve_commands';
  static const _phoneStorageKey = 'phone_storage';
  static const _webPhoneLayoutKey = 'web_phone_layout';
  /// 网页版总开关。**没有存储值时按 false 读** —— 老用户升级上来也是关的，
  /// 这正是这次要的效果：默认不加载网页版。
  static const _webEnabledKey = 'web_enabled';
  static const _hardwareEnterKey = 'hardware_enter_sends';
  static const _chatTextScaleKey = 'chat_text_scale';
  static const _foldTurnsKey = 'fold_completed_turns';
  static const _visualRepliesKey = 'visual_replies';
  static const _allowLandscapeKey = 'allow_landscape';
  static const _glassOpacityKey = 'glass_opacity';
  static const _secure = AppSecureStorage();
  late Future<void> _loaded;

  @override
  AppSettings build() {
    ref.listen(performanceDefaultsProvider.select((p) => p.autoStartLocal), (_, next) {
      if (!state.autoStartLocalExplicit) state = state.copyWith(autoStartLocal: next);
    });
    _loaded = _load();
    return const AppSettings(autoStartLocalExplicit: false);
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!ref.mounted) return;
    await performanceReady(ref);
    if (!ref.mounted) return;
    String apiKey = '';
    try {
      apiKey = await _secure.read(key: _apiKeyKey) ?? '';
    } catch (_) {
      // Keystore unavailable or corrupted; the user can re-enter the key.
    }
    if (!ref.mounted) return;
    var providerIds = const <String>{};
    try {
      providerIds = (await ref.read(providerKeyVaultProvider).readAll()).keys.toSet();
    } catch (_) {
      // Same: the providers still work, only the self-heal copy is gone.
    }
    if (!ref.mounted) return;
    state = AppSettings(
      apiKey: apiKey,
      themeMode: ThemeMode.values.firstWhere(
        (m) => m.name == prefs.getString(_themeKey),
        orElse: () => ThemeMode.system,
      ),
      autoStartLocal: prefs.getBool(_autoStartKey) ?? ref.read(performanceDefaultsProvider).autoStartLocal,
      autoStartLocalExplicit: prefs.containsKey(_autoStartKey),
      autoApproveCommands: prefs.getBool(_autoApproveKey) ?? false,
      phoneStorage: prefs.getBool(_phoneStorageKey) ?? false,
      webPhoneLayout: prefs.getBool(_webPhoneLayoutKey) ?? true,
      webEnabled: prefs.getBool(_webEnabledKey) ?? false,
      hardwareEnterSends: prefs.getBool(_hardwareEnterKey) ?? false,
      chatTextScale: _knownScale(prefs.getDouble(_chatTextScaleKey)),
      foldCompletedTurns: prefs.getBool(_foldTurnsKey) ?? true,
      visualReplies: prefs.getBool(_visualRepliesKey) ?? true,
      allowLandscape: prefs.getBool(_allowLandscapeKey) ?? true,
      glassOpacity: (prefs.getDouble(_glassOpacityKey) ?? 0).clamp(0.0, 1.0),
      customProviderIds: providerIds,
      loaded: true,
    );
    // 设置读出来了，方向按保存的偏好落一次（默认跟随手机）。
    unawaited(applyScreenOrientation(prefs.getBool(_allowLandscapeKey) ?? true));
  }

  /// Takes the keys in again once the saved credentials were cleared
  /// (credential_recovery.dart). Only the keys: invalidating this provider would
  /// drop [AppSettings.loaded] and the whole app back to the splash.
  Future<void> reloadCredentials() async {
    await _loaded;
    if (!ref.mounted) return;
    var apiKey = '';
    var providerIds = const <String>{};
    try {
      apiKey = await _secure.read(key: _apiKeyKey) ?? '';
      providerIds = (await ref.read(providerKeyVaultProvider).readAll()).keys.toSet();
    } catch (_) {
      // As in [_load]: the user can re-enter them.
    }
    if (!ref.mounted) return;
    state = state.copyWith(apiKey: apiKey, customProviderIds: providerIds);
  }

  /// Keeps [key] for the local engine's custom provider [id] (see
  /// [ProviderKeyVault]).
  Future<void> saveProviderKey(String id, String key) async {
    ref.read(readListCredentialEpochProvider.notifier).advance();
    await ref.read(providerKeyVaultProvider).write(id, key);
    state = state.copyWith(customProviderIds: {...state.customProviderIds, id});
  }

  Future<void> removeProviderKey(String id) async {
    ref.read(readListCredentialEpochProvider.notifier).advance();
    await ref.read(providerKeyVaultProvider).delete(id);
    state = state.copyWith(customProviderIds: {...state.customProviderIds}..remove(id));
  }

  Future<void> setApiKey(String key) async {
    ref.read(readListCredentialEpochProvider.notifier).advance();
    final trimmed = key.trim();
    if (trimmed.isEmpty) {
      await _secure.delete(key: _apiKeyKey);
    } else {
      await _secure.write(key: _apiKeyKey, value: trimmed);
    }
    state = state.copyWith(apiKey: trimmed);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeKey, mode.name);
    state = state.copyWith(themeMode: mode);
  }

  Future<void> setAutoApproveCommands(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoApproveKey, value);
    state = state.copyWith(autoApproveCommands: value);
  }

  Future<void> setPhoneStorage(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_phoneStorageKey, value);
    state = state.copyWith(phoneStorage: value);
  }

  static double _knownScale(double? v) => chatTextScales.any((s) => s.$1 == v) ? v! : 1.0;

  Future<void> setChatTextScale(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_chatTextScaleKey, value);
    state = state.copyWith(chatTextScale: value);
  }

  Future<void> setFoldCompletedTurns(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_foldTurnsKey, value);
    state = state.copyWith(foldCompletedTurns: value);
  }

  /// Takes effect at the next engine start (the instructions live in the
  /// managed AGENTS.md, written before DSH starts).
  Future<void> setVisualReplies(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_visualRepliesKey, value);
    state = state.copyWith(visualReplies: value);
  }

  /// 横屏开关：关掉立刻钉在竖屏，打开立刻恢复跟随手机。
  Future<void> setAllowLandscape(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_allowLandscapeKey, value);
    state = state.copyWith(allowLandscape: value);
    await applyScreenOrientation(value);
  }

  /// 卡片 / 气泡的玻璃再加多少不透明度（0–1）。
  Future<void> setGlassOpacity(double value) async {
    final v = value.clamp(0.0, 1.0);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_glassOpacityKey, v);
    state = state.copyWith(glassOpacity: v);
  }

  Future<void> setWebPhoneLayout(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_webPhoneLayoutKey, value);
    state = state.copyWith(webPhoneLayout: value);
  }

  /// 网页版总开关。开 = 和以前一样；关 = 不碰 WebView、不起 WebContent。
  Future<void> setWebEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_webEnabledKey, value);
    state = state.copyWith(webEnabled: value);
  }

  Future<void> setHardwareEnterSends(bool value) async {
    await _loaded;
    if (!ref.mounted) return;
    state = state.copyWith(hardwareEnterSends: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_hardwareEnterKey, value);
  }

  Future<void> setAutoStartLocal(bool value) async {
    await _loaded;
    if (!ref.mounted) return;
    state = state.copyWith(autoStartLocal: value, autoStartLocalExplicit: true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoStartKey, value);
  }
}

final settingsProvider = NotifierProvider<SettingsController, AppSettings>(SettingsController.new);
