// 输入框上方那颗「插件」胶囊：有没有东西可看。
//
// 这一行在输入框附近，每轮对话都重建，所以它必须便宜。原来的判断同时问了
// 「原生面板」和「聊天页 7 个插槽的座位规划」——后者要跑 7 次 seatPlan，
// 每帧都跑，而这些插件大多时候根本没人点开。
//
// 现在分两级：
//   * 常驻判断（这里）只看已经拿到手的清单：有没有装第三方插件、有没有
//     原生面板。都是列表里现成的东西，不触发规划。
//   * 7 个插槽的规划只在面板真正打开后计算（`chatWebPluginsProvider`），
//     面板关掉 30 秒就释放（autoDispose）。
//
// 代价：只注册了网页插槽、没有任何原生面板的插件，胶囊不会出现——它的
// 入口在「设置 › 插件」。破甲这类有原生面板的照常显示。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../plugins/native/native_state.dart';
import '../../../state/plugins_state.dart';

/// 便宜的判断：这台主机上有没有第三方插件。
///
/// 只读已经加载好的那一份清单，不跑座位规划，不发请求，不看任何插槽。
/// 面板里总会列出这些插件（至少是它们的设置入口），所以「有没有东西可看」
/// 就等于「装没装第三方插件」。
final pluginCapsuleHasContentProvider = Provider.family<bool, String>((ref, sessionId) {
  final bundles = ref.watch(installedPluginsProvider.select((s) => s.value));
  if (bundles == null) return false;
  for (final bundle in bundles) {
    if (bundleGroup(bundle) == BundleGroup.installed) return true;
  }
  return false;
});
