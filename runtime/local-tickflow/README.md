# TickFlow 炒股插件

dsh-go 原生插件。自选股行情、本地日K库、炒股设置页。

## 装了什么

| 位置 | 内容 |
|---|---|
| 加号面板 | 「炒股设置」「自选行情」两个入口 |
| 输入框胶囊 | 「查行情」（读剪贴板/输入框代码）「自选股」 |
| 状态条 | 自选前三只的涨跌，交易时段每分钟刷新 |
| 面板 | `炒股设置`（填 Key、管自选、同步数据）、`自选股`（表格 + 走势） |

## 数据

- 免费源 `https://free-api.tickflow.org`：日K + 全市场标的（8596 只，1 MB），无需 Key。
- 完整源 `https://api.tickflow.org`：加实时行情、分钟线，需要在设置里填 Key。

Key 存在 `.apikey`（权限 600），不写进代码、不进视图、不进 git。

## 库

`data/tickflow.db`（SQLite，WAL）。价格存整数（×1000）。

| 表 | 内容 |
|---|---|
| `instrument` | 标的字典，全市场 |
| `kline_daily` | 日K，主键 (symbol_id, ts) 聚簇 |
| `latest_daily` | 最新一根物化表，横截面查询走这里 |
| `kline_minute` | 分钟线，只存自选 |
| `quote_snapshot` | 实时快照，覆盖写 |
| `watchlist` | 自选池 |
| `sync_state` | 各步同步时间 |

A 档实测体积：元数据 1.0 MB + 自选 30 只 × 5000 根 5.6 MB ≈ 7 MB。

## 首次使用

1. 加号面板 →「炒股设置」。
2. 「同步全市场标的」→ 拉到 8596 只（约 3 秒）。
3. 「保存自选」填代码（逗号分隔），或复制代码后点「加剪贴板股票」。
4. 「拉取K线」→ 自选池日K入库。
5. 有 Key 就填 Key，实时行情立刻可用。

## 卸载

```sh
dsh plugin --profile web remove local-tickflow
```

`data/` 会保留，要清就手动删目录。
