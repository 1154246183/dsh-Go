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

# 彻底关掉代码签名，不要只依赖 `flutter build ios --no-codesign`。
#
# `--no-codesign` 只是让 Flutter 跳过**产物**签名；工程里
# `CODE_SIGN_STYLE = Automatic` 仍然会让它去找 Development Team。找到不到时
# Flutter 抛的是 code_signing.dart 里的**兜底文案**
# （“Building a deployable iOS app requires a selected Development Team…”），
# 真实原因被完全遮住。这个仓库本来就用 ldid 在 CI 后面手动签名，
# 所以让 xcodebuild 根本不签名是正确做法，不是绕过。
#
# `FLUTTER_XCODE_<SETTING>` 会被 Flutter 原样变成同名 xcodebuild 构建设置。
export FLUTTER_XCODE_CODE_SIGNING_ALLOWED=NO
export FLUTTER_XCODE_CODE_SIGNING_REQUIRED=NO
export FLUTTER_XCODE_CODE_SIGN_IDENTITY=""
export FLUTTER_XCODE_EXPANDED_CODE_SIGN_IDENTITY=""
export FLUTTER_XCODE_PROVISIONING_PROFILE_SPECIFIER=""

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
