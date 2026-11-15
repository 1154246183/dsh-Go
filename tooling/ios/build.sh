#!/usr/bin/env bash
# `flutter build ios` with these arguments. Reading a job's log takes a GitHub sign-in
# and its annotations don't, so on failure the compiler's errors go up as annotations
# as well (at most ten: GitHub's limit for one step).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# The library ships with the iOS app; sensitive capabilities are disabled until
# the user enables them in the app. This does not install an XCTest runner.
if ! bash "$ROOT/tooling/ios/build-phone-self-runner.sh"; then
  printf '::error::The pinned iOS phone native library did not build.\n' >&2
  exit 1
fi

# 签名在工程里关掉了：Runner.xcodeproj 的 Debug/Release/Profile 三处
# `CODE_SIGN_IDENTITY[sdk=iphoneos*]` 旁边都加了
# `CODE_SIGNING_ALLOWED = NO; CODE_SIGNING_REQUIRED = NO;`。
#
# 为什么不在命令行传：`flutter build ios --no-codesign` 只让 Flutter 跳过
# **产物**签名，xcodebuild 仍然带着工程的
# `CODE_SIGNING_ALLOWED = YES` / `CODE_SIGN_IDENTITY = iPhone Developer`
# 去要 Development Team，失败后 Flutter 抛的是 code_signing.dart 里的
# **兜底文案**（"Building a deployable iOS app requires a selected
# Development Team…"），真实原因被完全遮住。
# 试过 `FLUTTER_XCODE_CODE_SIGNING_ALLOWED=NO` 之类的环境变量，实测不生效
# （那次构建的 `xcodebuild -showBuildSettings` 仍是 YES），所以落到工程设置。
# 这个仓库本来就用 ldid 在后面手动签名，xcodebuild 不签名才是对的。

log="$(mktemp)"
flutter build ios "$@" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
if [ "$status" -ne 0 ]; then
  # Flutter prints Xcode's message with its file on the line after.
  awk '/\(Xcode\):|error:|Error:/ {
    line = $0
    if (getline following > 0) line = line " | " following
    print line
  }' "$log" | awk '!seen[$0]++' | cut -c1-600 | head -10 | sed -e 's/%/%25/g' -e 's/^/::error::/'
  # 注解只收 error: 形态的行。xcodebuild 有时既不输出 error: 也不给 (Xcode): 前缀
  # （例如签名或打包阶段失败），那时上面什么都抓不到，日志里就只剩 Flutter 那句
  # “requires a selected Development Team”。把尾部原样打出来，否则无从判断。
  echo "::group::flutter build ios 输出（末尾 400 行）"
  tail -400 "$log" | sed -e 's/%/%25/g'
  echo "::endgroup::"
  # 真正生效的签名设置。上面那些 FLUTTER_XCODE_* 有没有传进去，看这里。
  echo "::group::xcodebuild 生效的签名设置"
  "$DEVELOPER_DIR/usr/bin/xcodebuild" \
    -workspace ios/Runner.xcworkspace -scheme Runner \
    -configuration Release -sdk iphoneos -showBuildSettings 2>&1 |
    grep -E 'CODE_SIGN|DEVELOPMENT_TEAM|PROVISIONING_PROFILE|SDKROOT|IPHONEOS_DEPLOYMENT_TARGET' |
    head -40
  echo "::endgroup::"
fi
exit "$status"
