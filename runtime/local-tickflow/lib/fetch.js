// TickFlow HTTP 客户端：Node 原生 fetch，零依赖。
import { apiKey, baseUrl } from './db.js'

const TIMEOUT_MS = 15000

function headers() {
  const h = { accept: 'application/json' }
  const k = apiKey()
  if (k) h['x-api-key'] = k
  return h
}

async function request(pathname, { method = 'GET', params, body } = {}) {
  const url = new URL(pathname, baseUrl())
  for (const [k, v] of Object.entries(params || {})) {
    if (v != null) url.searchParams.set(k, String(v))
  }
  const ac = new AbortController()
  const timer = setTimeout(() => ac.abort(), TIMEOUT_MS)
  try {
    const init = { method, headers: headers(), signal: ac.signal }
    if (body !== undefined) {
      init.headers = { ...init.headers, 'content-type': 'application/json' }
      init.body = JSON.stringify(body)
    }
    const r = await fetch(url, init)
    const text = await r.text()
    let parsed = null
    try { parsed = text ? JSON.parse(text) : null } catch { parsed = null }
    if (!r.ok) {
      const err = new Error((parsed && parsed.message) || `HTTP ${r.status}`)
      err.status = r.status
      err.code = parsed && parsed.code
      throw err
    }
    return parsed
  } finally {
    clearTimeout(timer)
  }
}

// 交易所标的清单：SH / SZ / BJ
export async function fetchExchangeInstruments(exchange, type) {
  const j = await request(`/v1/exchanges/${encodeURIComponent(exchange)}/instruments`, {
    params: type ? { type } : undefined,
  })
  return Array.isArray(j && j.data) ? j.data : []
}

// 批量实时行情（需要 key；免费源返回 403）
export async function fetchQuotes(symbols) {
  if (!Array.isArray(symbols) || symbols.length === 0) return []
  const j = await request('/v1/quotes', { method: 'POST', body: { symbols } })
  return Array.isArray(j && j.data) ? j.data : []
}

// 日K
export async function fetchKlines(symbol, { period = '1d', count = 5000, adjust = 'forward' } = {}) {
  const j = await request('/v1/klines', { params: { symbol, period, count, adjust } })
  return (j && j.data) || null
}

// 分钟线
export async function fetchIntraday(symbol, period = '1m') {
  const j = await request('/v1/klines', { params: { symbol, period, count: 240, adjust: 'none' } })
  return (j && j.data) || null
}

// 标的池
export async function fetchUniverses() {
  const j = await request('/v1/universes')
  return Array.isArray(j && j.data) ? j.data : []
}
