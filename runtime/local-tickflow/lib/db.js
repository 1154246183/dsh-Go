// 本地行情库：node:sqlite，零依赖。
import { DatabaseSync } from 'node:sqlite'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
export const ROOT = path.resolve(HERE, '..')
export const DATA_DIR = path.join(ROOT, 'data')
export const DB_PATH = path.join(DATA_DIR, 'tickflow.db')
const SCHEMA_PATH = path.join(ROOT, 'sql', 'schema.sql')
const CONFIG_PATH = path.join(ROOT, 'config.json')
const KEY_PATH = path.join(ROOT, '.apikey')

let _db = null

export function config() {
  try { return JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8')) }
  catch { return { tier: 'A', refreshSec: 60, historyBars: 5000, watchlist: [] } }
}

export function saveConfig(cfg) {
  fs.writeFileSync(CONFIG_PATH, JSON.stringify(cfg, null, 2) + '\n', 'utf8')
}

// key 只从两处读：环境变量、600 权限文件。绝不落进代码或视图。
export function apiKey() {
  const env = (process.env.TICKFLOW_API_KEY || '').trim()
  if (env) return env
  try {
    const k = fs.readFileSync(KEY_PATH, 'utf8').trim()
    return k || ''
  } catch { return '' }
}

export function setApiKey(k) {
  if (!k) { try { fs.rmSync(KEY_PATH, { force: true }) } catch {} ; return }
  fs.writeFileSync(KEY_PATH, String(k).trim() + '\n', { mode: 0o600 })
  try { fs.chmodSync(KEY_PATH, 0o600) } catch {}
}

export function hasRealtime() { return apiKey() !== '' }
export function baseUrl() { return hasRealtime() ? 'https://api.tickflow.org' : 'https://free-api.tickflow.org' }

export function open() {
  if (_db) return _db
  fs.mkdirSync(DATA_DIR, { recursive: true })
  const db = new DatabaseSync(DB_PATH)
  db.exec('PRAGMA journal_mode = WAL')
  db.exec('PRAGMA synchronous = NORMAL')
  db.exec('PRAGMA busy_timeout = 5000')
  try { db.exec(fs.readFileSync(SCHEMA_PATH, 'utf8')) }
  catch (e) { console.error('[tickflow] schema:', e && e.message) }
  _db = db
  return db
}

export function close() {
  if (!_db) return
  try { _db.exec('PRAGMA wal_checkpoint(TRUNCATE)') } catch {}
  try { _db.close() } catch {}
  _db = null
}

export const PX = 1000
export const toInt = (v) => (v == null || !Number.isFinite(v) ? null : Math.round(v * PX))
export const toFloat = (v) => (v == null ? null : v / PX)

export function symbolId(db, symbol) {
  const s = String(symbol || '').trim().toUpperCase()
  const row = db.prepare('SELECT id FROM instrument WHERE symbol = ?').get(s)
  return row ? row.id : null
}

export function upsertInstruments(db, list) {
  const st = db.prepare(`
    INSERT INTO instrument (symbol, code, exchange, region, type, name, name_en,
                            total_shares, float_shares, listing_date, tick_size)
    VALUES (?,?,?,?,?,?,?,?,?,?,?)
    ON CONFLICT(symbol) DO UPDATE SET
      code=excluded.code, exchange=excluded.exchange, region=excluded.region,
      type=excluded.type, name=excluded.name, name_en=excluded.name_en,
      total_shares=excluded.total_shares, float_shares=excluded.float_shares,
      listing_date=excluded.listing_date, tick_size=excluded.tick_size`)
  db.exec('BEGIN')
  try {
    for (const it of list) {
      const e = it.ext || {}
      st.run(it.symbol, it.code ?? null, it.exchange ?? null, it.region ?? null,
        it.type ?? null, it.name ?? null, e.name_en ?? null,
        e.total_shares ?? null, e.float_shares ?? null,
        e.listing_date ?? null, e.tick_size ?? null)
    }
    db.exec('COMMIT')
  } catch (e) { db.exec('ROLLBACK'); throw e }
}

export function writeKlines(db, id, data) {
  if (!data || !Array.isArray(data.timestamp) || data.timestamp.length === 0) return 0
  const st = db.prepare(`INSERT OR REPLACE INTO kline_daily
    (symbol_id, ts, open, high, low, close, volume, amount) VALUES (?,?,?,?,?,?,?,?)`)
  const n = data.timestamp.length
  db.exec('BEGIN')
  try {
    for (let i = 0; i < n; i++) {
      st.run(id, data.timestamp[i], toInt(data.open[i]), toInt(data.high[i]),
        toInt(data.low[i]), toInt(data.close[i]),
        data.volume[i] ?? null, Math.round(data.amount[i] ?? 0))
    }
    db.exec('COMMIT')
  } catch (e) { db.exec('ROLLBACK'); throw e }
  refreshLatest(db, id)
  return n
}

export function refreshLatest(db, id) {
  const rows = db.prepare(`SELECT ts, close, amount FROM kline_daily
    WHERE symbol_id = ? ORDER BY ts DESC LIMIT 2`).all(id)
  if (rows.length === 0) return
  const cur = rows[0]
  const prev = rows[1]
  const pc = prev ? prev.close : cur.close
  const pct = pc ? ((cur.close - pc) * 100) / pc : null
  db.prepare(`INSERT OR REPLACE INTO latest_daily
    (symbol_id, ts, close, prev_close, pct, amount) VALUES (?,?,?,?,?,?)`)
    .run(id, cur.ts, cur.close, pc, pct, cur.amount ?? null)
}

export function readDaily(db, id, limit = 240) {
  return db.prepare(`SELECT ts, open, high, low, close, volume, amount FROM kline_daily
    WHERE symbol_id = ? ORDER BY ts DESC LIMIT ?`).all(id, limit)
}

export function watchlist(db) {
  return db.prepare(`SELECT w.symbol_id, w.sort, i.symbol, i.name, i.type
    FROM watchlist w JOIN instrument i ON i.id = w.symbol_id
    ORDER BY w.sort, w.symbol_id`).all()
}

export function addWatch(db, id) {
  const n = db.prepare('SELECT COUNT(*) c FROM watchlist').get().c
  db.prepare('INSERT OR IGNORE INTO watchlist (symbol_id, sort, added_at) VALUES (?,?,?)')
    .run(id, n, Date.now())
}

export function removeWatch(db, id) {
  db.prepare('DELETE FROM watchlist WHERE symbol_id = ?').run(id)
}

export function writeSnapshots(db, quotes) {
  const st = db.prepare(`INSERT OR REPLACE INTO quote_snapshot
    (symbol_id, last_price, prev_close, open, high, low, volume, amount, pct, session, updated_at)
    VALUES (?,?,?,?,?,?,?,?,?,?,?)`)
  const now = Date.now()
  db.exec('BEGIN')
  try {
    for (const q of quotes) {
      const id = symbolId(db, q.symbol)
      if (!id) continue
      const ext = q.ext || {}
      const pct = ext.change_pct != null ? ext.change_pct
        : (q.prev_close ? ((q.last_price - q.prev_close) * 100) / q.prev_close : null)
      st.run(id, q.last_price ?? null, q.prev_close ?? null, q.open ?? null,
        q.high ?? null, q.low ?? null, q.volume ?? null, q.amount ?? null,
        pct, q.session ?? null, now)
    }
    db.exec('COMMIT')
  } catch (e) { db.exec('ROLLBACK'); throw e }
}

export function readSnapshots(db) {
  return db.prepare(`SELECT s.*, i.symbol, i.name FROM quote_snapshot s
    JOIN instrument i ON i.id = s.symbol_id`).all()
}

export function getState(db, k) {
  const r = db.prepare('SELECT v FROM sync_state WHERE k = ?').get(k)
  return r ? r.v : null
}

export function setState(db, k, v) {
  db.prepare('INSERT OR REPLACE INTO sync_state (k, v, updated_at) VALUES (?,?,?)')
    .run(k, String(v), Date.now())
}
