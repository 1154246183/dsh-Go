#!/usr/bin/env python3
"""修补 dsh-our-free-model 里 Trae 的错误分类（假限流）。

用法：
    python3 tooling/ios/patch-ofm.py <插件目录>

## 修什么

上游 `vendor/channel-pack` 的 `classifyTraeError()` 用**裸数字子串**判限流：

```js
var QUOTA_EXCEEDED_MARKERS = ["4008", '"code":4008', "quota", "exceeded the quota"];
if (body.includes("4011") || body.includes('"code":4011')) return "soft-rate";
var PLAN_LIMIT_MARKERS = ['"code":1005', "1005"];
```

`body.includes("4008")` 这类判断没有边界：响应体里**任何位置**出现这四个
字符（token 数、请求 ID、时间戳片段都算）就会命中，于是：

- `4008` → `quota-exceeded`（长期不可用）
- `4011` → `soft-rate`（60 秒冷却）
- `1005` → `hard-plan`（**12 小时**冷却）

判定结果会被 `accountPool.updateModelRateLimit()` 写进 `state.json` 的
`modelRateLimits`，而 UI 只显示「限流中」，用户看不出这是误判。

## 还有第二处

```js
function recordsTraeRateLimit(kind) {
  return kind === "hard-plan" || kind === "soft-rate"
      || kind === "not-found" || kind === "quota-exceeded";
}
```

`not-found` 是 HTTP 404（模型不存在 / 上游未上架）。把它记成限流，会让一个
**刚添加的模型当场锁死**——而用户在列表里选不到它，就永远不可能再成功一次
来自愈，只能等 TTL 过期或手改 `state.json`。

## 改成什么

1. 只认 JSON 的 `code` 字段（`'"code":4011'` / `'"code": 4011'`）。
2. 从 `recordsTraeRateLimit` 移除 `not-found`。

替换是**幂等**的：已经打过的文件再跑一次会跳过（找不到原始片段时不报错，
但会提示）。找不到任何片段时退出码非 0，让 CI 明确失败而不是静默产出坏包。
"""

import sys

REPLACEMENTS = [
    (
        # ① PLAN_LIMIT_MARKERS 去掉裸 "1005"
        """var PLAN_LIMIT_MARKERS = ['"code":1005', "1005"];""",
        """var PLAN_LIMIT_MARKERS = ['"code":1005', '"code": 1005'];"""
        """ // DSH-PATCH: 去掉裸 1005（任意位置命中会误判 12h 冷却）""",
    ),
    (
        # ② QUOTA_EXCEEDED_MARKERS 去掉裸 "4008"
        """var QUOTA_EXCEEDED_MARKERS = ["4008", '"code":4008', "quota", "exceeded the quota"];""",
        """var QUOTA_EXCEEDED_MARKERS = ['"code":4008', '"code": 4008', "quota", """
        """"exceeded the quota"]; // DSH-PATCH: 去掉裸 4008""",
    ),
    (
        # ③ 4011 只认 code 字段
        '''  if (body.includes("4011") || body.includes('"code":4011')) {
    return "soft-rate";
  }''',
        '''  if (body.includes('"code":4011') || body.includes('"code": 4011')) {
    // DSH-PATCH: 去掉裸 4011
    return "soft-rate";
  }''',
    ),
    (
        # ④ 404 不再记为限流
        '''function recordsTraeRateLimit(kind) {
  return kind === "hard-plan" || kind === "soft-rate" || kind === "not-found" || kind === "quota-exceeded";
}''',
        '''function recordsTraeRateLimit(kind) {
  // DSH-PATCH: 404（模型不存在）不是限流。记成限流会让新添加的模型当场锁死，
  // 而用户选不到它就不可能再成功一次来自愈。
  return kind === "hard-plan" || kind === "soft-rate" || kind === "quota-exceeded";
}''',
    ),
]


def main() -> int:
    if len(sys.argv) != 2:
        print("用法: python3 patch-ofm.py <插件目录>", file=sys.stderr)
        return 2

    import os

    path = os.path.join(sys.argv[1], "vendor", "channel-pack", "pack.js")
    if not os.path.isfile(path):
        print(f"::error title=plugin patch::找不到 {path}")
        return 1

    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        src = f.read()

    applied = 0
    skipped = []
    for old, new in REPLACEMENTS:
        if old in src:
            src = src.replace(old, new, 1)
            applied += 1
        elif new in src or "DSH-PATCH" in src:
            skipped.append(old[:48])
        else:
            print(f"::warning title=plugin patch::片段不匹配: {old[:48]!r}")

    if applied == 0:
        # 幂等：文件已打过补丁时不算失败，但必须有 DSH-PATCH 标记为证。
        if "DSH-PATCH" in src:
            print("已打过补丁，跳过")
            return 0
        print("::error title=plugin patch::一处都没替换成功，pack.js 结构与预期不符")
        return 1

    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(src)

    print(f"DSH-PATCH 已应用 {applied} 处")
    if skipped:
        print(f"已有的跳过 {len(skipped)} 处")
    return 0


if __name__ == "__main__":
    sys.exit(main())
