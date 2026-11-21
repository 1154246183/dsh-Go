// 同步器：全市场元数据 / 自选日K / 实时快照。
import {
  watchlist, symbolId, upsertInstruments, writeKlines, writeSnapshots,
  setState, getState,
} from './db.js'
import { fetchExchangeInstruments, fetchQuotes, fetchKlines } from './fetch.js'

const EXCHANGES = ['SH', 'SZ', 'BJ']

// 全市场标的字典（A 档：全存，约 1 MB）
export async function syncInstruments(db) {
  let total = 0
  const detail = []
  for (const ex of EXCHANGES) {
    try {
      const list = await fetchExchangeInstruments(ex)
      upsertInstruments(db, list)
      total += list.length
      detail.push(`${ex}${list.length}`)
    } catch (e) {
      detail.push(`${ex}✗`)
    }
  }
  setState(db, 'instruments_at', String(Date.now()))
  return { total, detail: detail.join(' ') }
}

// 自选日K：full 时拉满 historyBars，否则只补最近
export async function syncKlines(db, { full = false, historyBars = 5000, onStep } = {}) {
  const wl = watchlist(db)
  if (wl.length === 0) return { bars: 0, symbols: 0, detail: '自选为空' }
  const count = full ? historyBars : 400
  let bars = 0
  const detail = []
  for (let i = 0; i < wl.length; i++) {
    const w = wl[i]
    if (onStep) onStep(i, wl.length, w.symbol)
    try {
      const data = await fetchKlines(w.symbol, { period: '1d', count, adjust: 'forward' })
      bars += writeKlines(db, w.symbol_id, data)
      detail.push(`${w.symbol}✓`)
    } catch (e) {
      detail.push(`${w.symbol}✗`)
    }
  }
  setState(db, 'klines_at', String(Date.now()))
  return { bars, symbols: wl.length, detail: detail.join(' ') }
}

// 实时快照：有 key 才有
export async function syncQuotes(db) {
  const wl = watchlist(db)
  if (wl.length === 0) return { skipped: true, reason: '自选为空' }
  try {
    const quotes = await fetchQuotes(wl.map((w) => w.symbol))
    if (quotes.length > 0) {
      writeSnapshots(db, quotes)
      setState(db, 'quotes_at', String(Date.now()))
    }
    return { count: quotes.length }
  } catch (e) {
    if (e.status === 403) return { skipped: true, reason: '免费源无实时行情' }
    throw e
  }
}

// A 股交易时段：9:30-11:30, 13:00-15:00，周一至周五
export function inSession(d = new Date()) {
  const day = d.getDay()
  if (day === 0 || day === 6) return false
  const t = d.getHours() * 60 + d.getMinutes()
  return (t >= 570 && t <= 690) || (t >= 780 && t <= 900)
}
