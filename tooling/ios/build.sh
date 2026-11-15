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
fi
exit "$status"
