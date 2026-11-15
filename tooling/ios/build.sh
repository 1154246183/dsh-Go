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

# 注意：构建失败时 Flutter 经常只打 code_signing.dart 里的兜底文案
# （"Building a deployable iOS app requires a selected Development Team…"），
# 真正的错误在 xcodebuild 的输出里，而它默认不打印。所以下面始终用
# `--verbose` 抓完整日志，失败时把关键行捞出来。曾经因为看不到真实错误，
# 白白排查了好几轮签名问题，实际是 Dart 编译错误。

log="$(mktemp)"
# 始终用 --verbose 跑，但只写进文件、不刷屏。
#
# 之前 `flutter build ios` 失败时日志里只有 code_signing.dart 的兜底文案
# （“requires a selected Development Team…”），xcodebuild 的真实输出一行都没有，
# 结果每次构建都要盲猜一轮，浪费十几分钟。--verbose 会打印 xcodebuild 的
# 完整命令行与输出，成功时我们不打印什么，失败时才把关键部分捞出来。
flutter build ios "$@" --verbose >"$log" 2>&1
status=$?
if [ "$status" -ne 0 ]; then
  # Flutter prints Xcode's message with its file on the line after.
  awk '/\(Xcode\):|error:|Error:/ {
    line = $0
    if (getline following > 0) line = line " | " following
    print line
  }' "$log" | awk '!seen[$0]++' | cut -c1-600 | head -10 | sed -e 's/%/%25/g' -e 's/^/::error::/'

  echo "::group::xcodebuild 命令行与结果"
  grep -nE 'xcodebuild|Xcode build done|BUILD FAILED|The following build commands failed|\*\* ' "$log" |
    head -40 | cut -c1-400 | sed -e 's/%/%25/g'
  echo "::endgroup::"

  echo "::group::诊断：错误行"
  grep -nEi 'error:|fatal|failed to|CodeSign|Provisioning|undefined symbol|No such file|cannot find|not found' "$log" |
    grep -viE 'DeprecationWarning|pub outdated|newer versions' |
    head -60 | cut -c1-400 | sed -e 's/%/%25/g'
  echo "::endgroup::"

  echo "::group::flutter build ios 输出（末尾 200 行）"
  tail -200 "$log" | cut -c1-400 | sed -e 's/%/%25/g'
  echo "::endgroup::"

  echo "::group::xcodebuild 生效的签名设置"
  "$DEVELOPER_DIR/usr/bin/xcodebuild" \
    -workspace ios/Runner.xcworkspace -scheme Runner \
    -configuration Release -sdk iphoneos -showBuildSettings 2>&1 |
    grep -E 'CODE_SIGN|DEVELOPMENT_TEAM|PROVISIONING_PROFILE|SDKROOT|IPHONEOS_DEPLOYMENT_TARGET' |
    head -40
  echo "::endgroup::"
else
  echo "flutter build ios 成功，日志 $(wc -l <"$log") 行（已省略）"
fi
exit "$status"
