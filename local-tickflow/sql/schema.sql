-- TickFlow 本地行情库：A 档（全市场元数据 + 自选池日K）
-- 价格统一存整数（×1000），省 40% 空间并避免浮点误差。

PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;

CREATE TABLE IF NOT EXISTS instrument (
  id           INTEGER PRIMARY KEY,
  symbol       TEXT NOT NULL UNIQUE,
  code         TEXT,
  exchange     TEXT,
  region       TEXT,
  type         TEXT,
  name         TEXT,
  name_en      TEXT,
  total_shares REAL,
  float_shares REAL,
  listing_date TEXT,
  tick_size    REAL
);
CREATE INDEX IF NOT EXISTS idx_instrument_code ON instrument(code);
CREATE INDEX IF NOT EXISTS idx_instrument_name ON instrument(name);

CREATE TABLE IF NOT EXISTS kline_daily (
  symbol_id INTEGER NOT NULL,
  ts        INTEGER NOT NULL,
  open      INTEGER, high INTEGER, low INTEGER, close INTEGER,
  volume    INTEGER, amount INTEGER,
  PRIMARY KEY (symbol_id, ts)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS latest_daily (
  symbol_id  INTEGER PRIMARY KEY,
  ts         INTEGER,
  close      INTEGER,
  prev_close INTEGER,
  pct        REAL,
  amount     INTEGER
);

CREATE TABLE IF NOT EXISTS kline_minute (
  symbol_id INTEGER NOT NULL,
  ts        INTEGER NOT NULL,
  open      INTEGER, high INTEGER, low INTEGER, close INTEGER,
  volume    INTEGER, amount INTEGER,
  PRIMARY KEY (symbol_id, ts)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS quote_snapshot (
  symbol_id  INTEGER PRIMARY KEY,
  last_price REAL, prev_close REAL, open REAL, high REAL, low REAL,
  volume     INTEGER, amount REAL, pct REAL, session TEXT, updated_at INTEGER
);

CREATE TABLE IF NOT EXISTS watchlist (
  symbol_id INTEGER PRIMARY KEY,
  sort      INTEGER DEFAULT 0,
  added_at  INTEGER
);

CREATE TABLE IF NOT EXISTS sync_state (
  k          TEXT PRIMARY KEY,
  v          TEXT,
  updated_at INTEGER
);
