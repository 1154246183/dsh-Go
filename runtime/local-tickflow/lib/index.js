// dsh-go 本地插件：炒股（TickFlow 行情）
// 引擎侧（Node）跑数据；App 只画 package.json 声明的原生控件。
import fs from 'node:fs'
import {
  open, config, saveConfig, setApiKey, hasRealtime,
  toFloat, symbolId, upsertInstruments, readDaily, readSnapshots,
  watchlist, addWatch, writeSnapshots, getState, setState,
  DB_PATH,
} from './db.js'
import { fetchQuotes } from './fetch.js'
import { syncInstruments, syncKlines, syncQuotes, inSession } from './sync.js'

export const name = 'local-tickflow'

// ── 进度与状态 ──
const prog = { running: false, task: '', detail: '', done: 0, total: 0, lastError: '', lastOk: '' }
let selSymbol = ''
// 当前这次行情条订阅的 emit，关掉炒股时用它立刻清空那一行。
// 订阅结束置 null，避免对已关闭的 feed 说话。
let tickEmit = null
const HIDDEN_STRIP = { text: '' }

const zhOf = (loc) => !String(loc || '').startsWith('en')

// 显示用的代码：去掉 .SH/.SZ/.BJ 后缀，输入框里只写数字。
// 港股/美股的 .HK/.US 保留——去掉就分不清 00700 是港股还是深市。
export function bareSymbol(sym) {
  const s = String(sym || '').trim().toUpperCase()
  return s.replace(/\.(SH|SZ|BJ)$/, '')
}

// 代码规范化：600519 / sz000001 / 00700.HK → 带后缀的统一写法。
// 输入框只收纯数字，后缀这里按首位补：6/9/5 沪、0/3/1/2 深、4/8 北；
// 5 位数字仍按港股处理（港股就是 5 位，A 股是 6 位，不会撞）。
export function normalizeSymbol(raw) {
  let s = String(raw || '').trim().toUpperCase().replace(/\s+/g, '')
  if (!s) return null
  const m = s.match(/^(SH|SZ|BJ)(\d{6})$/)
  if (m) return `${m[2]}.${m[1]}`
  if (/^\d{5}\.HK$/.test(s)) return s
  if (/^\d{5}$/.test(s)) return s + '.HK'
  s = s.replace(/^(SH|SZ|BJ)[.:]?/, (mm, ex) => ex + '.')
  if (/^\d{6}\.(SH|SZ|BJ)$/.test(s)) return s
  if (/^\d{6}$/.test(s)) {
    const h = s[0]
    if (h === '6' || h === '9' || h === '5') return s + '.SH'
    if (h === '0' || h === '3' || h === '1' || h === '2') return s + '.SZ'
    if (h === '4' || h === '8') return s + '.BJ'
    return s + '.SZ'
  }
  if (/^[A-Z]{1,6}\.(US|HK)$/.test(s)) return s
  if (/^[A-Z]{1,6}$/.test(s)) return s + '.US'
  return null
}

// 代码入库（不存在就补一条最小记录）
function ensureSymbol(db, sym) {
  let id = symbolId(db, sym)
  if (id) return id
  const [code, ex] = sym.split('.')
  upsertInstruments(db, [{
    symbol: sym, code, exchange: ex,
    region: ex === 'US' ? 'US' : ex === 'HK' ? 'HK' : 'CN',
    type: 'stock', name: sym,
  }])
  return symbolId(db, sym)
}

function ensureWatchlist(db) {
  const n = db.prepare('SELECT COUNT(*) c FROM watchlist').get().c
  if (n > 0) return
  const cf = config()
  const list = Array.isArray(cf.watchlist) ? cf.watchlist : []
  for (const raw of list) {
    const sym = normalizeSymbol(raw)
    if (!sym) continue
    const id = ensureSymbol(db, sym)
    if (id) addWatch(db, id)
  }
}

function startTask(task, fn) {
  if (prog.running) return { toast: '有任务在跑' }
  Object.assign(prog, { running: true, task, detail: '', done: 0, total: 0, lastError: '' })
  Promise.resolve()
    .then(fn)
    .then((r) => { prog.lastOk = `${task}完成${r ? ' ' + r : ''}`.trim() })
    .catch((e) => { prog.lastError = `${task}失败：${e && e.message}` })
    .finally(() => { prog.running = false; prog.task = '' })
  return { toast: `${task}已开始`, refresh: true }
}

const step = (i, n, s) => { prog.done = i; prog.total = n; prog.detail = s }

// ── 格式化 ──
const fmtPct = (v) => (v == null || !Number.isFinite(v) ? '—' : (v >= 0 ? '+' : '') + v.toFixed(2) + '%')
const fmtAmt = (v) => {
  if (v == null || !Number.isFinite(v)) return '—'
  if (v >= 1e8) return (v / 1e8).toFixed(1) + '亿'
  if (v >= 1e4) return (v / 1e4).toFixed(0) + '万'
  return String(Math.round(v))
}
const fmtTime = (v, zh) => {
  if (!v) return zh ? '从未' : 'never'
  const d = new Date(Number(v))
  const p = (n) => String(n).padStart(2, '0')
  return `${d.getMonth() + 1}/${d.getDate()} ${p(d.getHours())}:${p(d.getMinutes())}`
}

// caps.components 判定：确认支持才用 v2 输入控件
const can = (caps, comp) => {
  const arr = caps && Array.isArray(caps.components) ? caps.components : null
  return arr ? arr.includes(comp) : false
}

export function apply(ctx) {
  ctx.inject(['dshGo'], (ctx) => {
    // ═════════ 加号工具：已移除 ═════════
    // 「自选行情」「炒股设置」两个入口不再出现在 ＋ 面板里；面板改为从
    // 设置 › 插件 进入。handler 一并删掉：留着是没有入口的死绑定。

    // ═════════ 状态条 ═════════
    ctx.dshGo.strip('tick', (scope, emit, caps) => {
      const zh = zhOf(caps && caps.locale)
      // 总开关：关着就连定时器都不建，也不开库、不查表。
      // 「不用的时候不加载行情」就靠这一道。
      //
      // 关着时 emit 空文本 —— App 那边（composer_strip.dart:264）只看
      // text.isNotEmpty 才把这一行放进 ready，空文本整条不显示。
      // 不能写「炒股已关闭」：那会占着输入框上方一行，白占地方。
      const enabled = () => config().enabled !== false
      const HIDDEN = HIDDEN_STRIP
      tickEmit = emit
      if (!enabled()) {
        emit(HIDDEN)
        return () => { tickEmit = null }
      }
      const paint = () => {
        if (!enabled()) return emit(HIDDEN)
        try {
          const db = open()
          ensureWatchlist(db)
          const wl = watchlist(db)
          if (wl.length === 0) return emit({ text: zh ? '自选为空，点开设置' : 'Watchlist empty', icon: 'chart' })
          const snaps = readSnapshots(db)
          const byId = new Map(snaps.map((s) => [s.symbol_id, s]))
          const lat = new Map(db.prepare('SELECT symbol_id, pct FROM latest_daily').all()
            .map((r) => [r.symbol_id, r.pct]))
          const parts = []
          for (const w of wl.slice(0, 3)) {
            const s = byId.get(w.symbol_id)
            let pct = s ? s.pct : null
            if (pct == null) pct = lat.get(w.symbol_id) ?? null
            parts.push(`${(w.name || bareSymbol(w.symbol)).slice(0, 4)} ${pct != null ? fmtPct(pct) : '—'}`)
          }
          let text = parts.join(' ')
          if (wl.length > 3) text += ` +${wl.length - 3}`
          if (!hasRealtime()) text = (zh ? '日K ' : 'D ') + text
          emit({ text: text.slice(0, 24), icon: 'chart' })
        } catch {
          emit({ text: zh ? '行情未就绪' : 'Not ready', icon: 'chart' })
        }
      }
      paint()
      // 关闭炒股的那一刻 App 不会重新订阅，只有这次 emit 能把「自选为空，
      // 点开设置」这类残留清掉：定时器一律走 paint()，由它自己判断开关，
      // 不能用 enabled() 挡在 setInterval 外面——那样关了以后再也不 emit，
      // 行情条就定在最后一条非空文本上。
      const timer = setInterval(
        () => { if (inSession()) paint() },
        Math.max(30, Number(config().refreshSec) || 60) * 1000,
      )
      return () => { tickEmit = null; clearInterval(timer) }
    })

    // ═════════ 面板：炒股设置 ═════════
    ctx.dshGo.panel('settings', {
      view: (scope, caps) => {
        const zh = zhOf(caps && caps.locale)
        const rich = can(caps, 'textField') && can(caps, 'form')
        const keyForm = rich
          ? [{ type: 'form', submit: 'saveKey', submitLabel: zh ? '保存 Key' : 'Save key', children: [
              { type: 'textField', label: 'TickFlow API Key', bind: 'data.keyInput',
                placeholder: zh ? '粘贴 Key；留空继续用免费源' : 'Paste key; empty = free tier',
                maxLength: 200 },
            ] }]
          : []
        const listForm = rich
          ? [{ type: 'form', submit: 'saveWatch', submitLabel: zh ? '保存自选' : 'Save list', children: [
              { type: 'textField', label: zh ? '自选股代码' : 'Symbols', bind: 'data.symbolsInput',
                placeholder: '600519, 000001, 510300',
                multiline: true, maxLines: 4, maxLength: 800 },
            ] }]
          : [{ type: 'text', tone: 'muted',
              text: zh ? '把股票代码复制到剪贴板，点下面按钮逐个添加。' : 'Copy a symbol, then tap Add.' }]
        return {
          v: 2,
          type: 'stack',
          title: zh ? '炒股设置' : 'Stock settings',
          children: [
            { type: 'callout', tone: { $: 'data.enabledTone' }, text: { $: 'data.enabledText' } },
            { type: 'actions', items: [
              { label: { $: 'data.enabledLabel' }, action: 'toggleEnabled', style: 'primary' },
            ] },
            { type: 'divider' },
            { type: 'keyValue', items: { $: 'data.info' } },
            { type: 'callout', text: { $: 'data.keyState' }, tone: { $: 'data.keyTone' } },
            ...keyForm,
            { type: 'actions', items: [
              { label: zh ? '从剪贴板读 Key' : 'Key from clip', action: 'keyFromClip', style: 'primary' },
              { label: zh ? '清除 Key' : 'Clear key', action: 'clearKey' },
            ] },
            { type: 'divider' },
            ...listForm,
            { type: 'actions', items: [
              { label: zh ? '加剪贴板股票' : 'Add from clip', action: 'addFromClip' },
              { label: zh ? '清空自选' : 'Clear list', action: 'clearWatch' },
            ] },
            { type: 'divider' },
            { type: 'actions', items: [
              { label: zh ? '同步标的' : 'Instruments', action: 'syncInst' },
              { label: zh ? '拉取K线' : 'Sync K', action: 'syncK' },
              { label: zh ? '一键重建' : 'Rebuild', action: 'rebuild', style: 'primary' },
            ] },
            { type: 'progress', value: { $: 'data.progressPct' }, label: { $: 'data.progressLabel' } },
            { type: 'keyValue', items: { $: 'data.storage' } },
            { type: 'actions', items: [
              { label: zh ? '看自选行情' : 'Watchlist', action: 'toWatch' },
            ] },
          ],
        }
      },
      data: (scope, emit) => {
        const zh = zhOf(scope && scope.locale)
        let alive = true
        const paint = () => {
          if (!alive) return
          try {
            const db = open()
            ensureWatchlist(db)
            const wl = watchlist(db)
            const instCount = db.prepare('SELECT COUNT(*) c FROM instrument').get().c
            const barCount = db.prepare('SELECT COUNT(*) c FROM kline_daily').get().c
            let bytes = 0
            try { bytes = fs.statSync(DB_PATH).size } catch {}
            const set = hasRealtime()
            emit({
              info: [
                [zh ? '数据档位' : 'Tier', config().tier || 'A'],
                [zh ? '标的数' : 'Instruments', String(instCount)],
                [zh ? '日K行数' : 'K rows', String(barCount)],
                [zh ? '自选数' : 'Watching', String(wl.length)],
                [zh ? '标的更新' : 'Instr. at', fmtTime(getState(db, 'instruments_at'), zh)],
                [zh ? 'K线更新' : 'K at', fmtTime(getState(db, 'klines_at'), zh)],
              ],
              keyState: set
                ? (zh ? 'Key 已配置：实时行情可用。' : 'Key configured.')
                : (zh ? '未填 Key：免费源只给日K与标的，实时行情不可用。' : 'No key: daily K only.'),
              keyTone: set ? 'good' : 'warn',
              keyInput: '',
              symbolsInput: wl.map((w) => bareSymbol(w.symbol)).join(', '),
              enabled: config().enabled !== false,
              enabledText: (config().enabled !== false)
                ? (zh ? '已启用：会读行情、开数据库，行情条在跑。'
                      : 'On: quotes, the database and the strip are live.')
                : (zh ? '已关闭：不读行情、不开数据库，行情条停着。'
                      : 'Off: no quotes, no database, the strip is stopped.'),
              enabledTone: (config().enabled !== false) ? 'good' : 'warn',
              enabledLabel: (config().enabled !== false)
                ? (zh ? '关闭炒股（停掉行情）' : 'Turn off (stop quotes)')
                : (zh ? '启用炒股' : 'Turn on'),
              progressPct: prog.running ? (prog.total > 0 ? Math.round((prog.done / prog.total) * 100) : 5) : 0,
              progressLabel: prog.running
                ? `${prog.task} ${prog.detail || ''}`.trim()
                : (prog.lastError || prog.lastOk || (zh ? '空闲' : 'idle')),
              storage: [
                [zh ? '库文件' : 'DB', `${(bytes / 1048576).toFixed(1)} MB`],
                [zh ? '位置' : 'Path', 'data/tickflow.db'],
              ],
            })
          } catch (e) {
            emit({
              info: [[zh ? '错误' : 'Error', String(e && e.message)]],
              keyState: zh ? '库打不开' : 'DB unavailable', keyTone: 'warn',
              progressPct: 0, progressLabel: '', storage: [], symbolsInput: '', keyInput: '',
            })
          }
        }
        paint()
        const t = setInterval(paint, 2000)
        return () => { alive = false; clearInterval(t) }
      },
      actions: {
        saveKey: (scope, event) => {
          const v = readInput(event, ['keyInput', 'apiKeyInput'])
          if (v == null) return { toast: '没读到输入内容' }
          const k = String(v).trim()
          if (k === '') return { toast: '未填 Key', refresh: true }
          try { setApiKey(k); return { toast: 'Key 已保存', refresh: true } }
          catch (e) { return { toast: `保存失败：${e.message}` } }
        },
        keyFromClip: (scope) => {
          const k = String((scope && scope.clipboard) || '').trim()
          if (!k) return { toast: '剪贴板里没有文字' }
          if (k.length < 8 || /\s/.test(k)) return { toast: '剪贴板不像 Key' }
          try { setApiKey(k); return { toast: 'Key 已保存', refresh: true } }
          catch (e) { return { toast: `保存失败：${e.message}` } }
        },
        clearKey: () => {
          try { setApiKey('') } catch {}
          return { toast: 'Key 已清除', refresh: true }
        },
        setEnabled: (scope, event) => {
          const v = readInput(event, ['enabled'])
          const on = v === true || v === 'true'
          const cf = config()
          cf.enabled = on
          saveConfig(cf)
          // 关掉就立刻把行情条收掉，不等下一次定时刷新；重开由 refresh 重画。
          if (!on) try { tickEmit?.(HIDDEN_STRIP) } catch {}
          return { toast: on ? '炒股已启用' : '炒股已关闭', refresh: true }
        },
        toggleEnabled: () => {
          const cf = config()
          const on = !(cf.enabled !== false)
          cf.enabled = on
          saveConfig(cf)
          if (!on) try { tickEmit?.(HIDDEN_STRIP) } catch {}
          return { toast: on ? '炒股已启用，行情恢复' : '炒股已关闭，行情停止', refresh: true }
        },
        saveWatch: (scope, event) => {
          const v = readInput(event, ['symbolsInput'])
          if (v == null) return { toast: '没读到输入内容' }
          const db = open()
          const raw = String(v).split(/[,，\s\n]+/).filter(Boolean)
          const syms = [], bad = []
          for (const r of raw) {
            const s = normalizeSymbol(r)
            if (s) syms.push(s); else bad.push(r)
          }
          if (syms.length === 0) return { toast: '没有有效代码' }
          db.exec('DELETE FROM watchlist')
          let n = 0
          for (const s of syms) {
            const id = ensureSymbol(db, s)
            if (id) { addWatch(db, id); n += 1 }
          }
          const cf = config(); cf.watchlist = syms; saveConfig(cf)
          if (syms[0]) selSymbol = syms[0]
          return {
            toast: bad.length ? `存 ${n} 只，跳过 ${bad.length}` : `存 ${n} 只`,
            refresh: true,
          }
        },
        addFromClip: (scope) => {
          const db = open()
          const sym = normalizeSymbol(String((scope && scope.clipboard) || '').split('\n')[0])
          if (!sym) return { toast: '剪贴板里没有股票代码' }
          const id = ensureSymbol(db, sym)
          if (!id) return { toast: '添加失败' }
          addWatch(db, id)
          const cf = config()
          cf.watchlist = watchlist(db).map((w) => w.symbol)
          saveConfig(cf)
          return { toast: `已添加 ${sym}`, refresh: true }
        },
        clearWatch: () => {
          const db = open()
          db.exec('DELETE FROM watchlist')
          const cf = config(); cf.watchlist = []; saveConfig(cf)
          return { toast: '自选已清空', refresh: true }
        },
        syncInst: () => startTask('标的同步', async () => {
          const r = await syncInstruments(open())
          return `${r.total} 只`
        }),
        syncK: () => startTask('K线同步', async () => {
          const r = await syncKlines(open(), { full: true, onStep: step })
          return `${r.bars} 根`
        }),
        rebuild: () => startTask('全量重建', async () => {
          const db = open()
          const meta = await syncInstruments(db)
          const r = await syncKlines(db, { full: true, onStep: step })
          if (hasRealtime()) { try { await syncQuotes(db) } catch {} }
          return `标的${meta.total} · K线${r.bars}根`
        }),
        toWatch: () => ({ open: 'panel:watchlist' }),
      },
    })

    // ═════════ 面板：自选股 ═════════
    ctx.dshGo.panel('watchlist', {
      view: (scope, caps) => {
        const zh = zhOf(caps && caps.locale)
        return {
          v: 2,
          type: 'stack',
          title: zh ? '自选股' : 'Watchlist',
          children: [
            { type: 'row', children: [
              { type: 'metric', label: zh ? '涨' : 'Up', value: { $: 'data.up' }, tone: 'bad' },
              { type: 'metric', label: zh ? '跌' : 'Down', value: { $: 'data.down' }, tone: 'good' },
              { type: 'metric', label: zh ? '均幅' : 'Avg', value: { $: 'data.avg' } },
            ] },
            { type: 'callout', text: { $: 'data.status' }, tone: { $: 'data.statusTone' } },
            { type: 'table',
              columns: [
                { label: zh ? '名称' : 'Name' },
                { label: zh ? '现价' : 'Last' },
                { label: zh ? '涨跌' : 'Chg' },
                { label: zh ? '额' : 'Amt' },
              ],
              rows: { $: 'data.rows' } },
            { type: 'chart', kind: 'line',
              categories: { $: 'data.cats' },
              series: [{ name: { $: 'data.chartName' }, values: { $: 'data.vals' } }],
              caption: { $: 'data.chartCaption' } },
            { type: 'list', items: { $: 'data.picks' } },
            { type: 'actions', items: [
              { label: zh ? '刷新' : 'Refresh', action: 'refresh', style: 'primary' },
              { label: zh ? '同步K线' : 'Sync K', action: 'syncK' },
              { label: zh ? '设置' : 'Settings', action: 'toSettings' },
            ] },
          ],
        }
      },
      data: (scope, emit) => {
        const zh = zhOf(scope && scope.locale)
        let alive = true
        const paint = () => {
          if (!alive) return
          try {
            const db = open()
            ensureWatchlist(db)
            const wl = watchlist(db)
            if (wl.length === 0) {
              return emit({
                up: '—', down: '—', avg: '—',
                status: zh ? '自选为空，去设置里添加。' : 'Watchlist empty.',
                statusTone: 'info', rows: [], cats: [], vals: [],
                chartName: '', chartCaption: '', picks: [],
              })
            }
            if (!selSymbol || !wl.some((w) => w.symbol === selSymbol)) selSymbol = wl[0].symbol
            const byId = new Map(readSnapshots(db).map((s) => [s.symbol_id, s]))
            let up = 0, down = 0, sum = 0, n = 0
            const rows = []
            for (const w of wl) {
              const s = byId.get(w.symbol_id)
              let pct = s ? s.pct : null
              let last = s ? s.last_price : null
              let amt = s ? s.amount : null
              if (last == null) {
                const d = readDaily(db, w.symbol_id, 2)
                if (d.length > 0) {
                  last = toFloat(d[0].close)
                  amt = d[0].amount
                  pct = d[1] && d[1].close ? ((d[0].close - d[1].close) * 100) / d[1].close : null
                }
              }
              if (pct != null) {
                if (pct > 0) up += 1; else if (pct < 0) down += 1
                sum += pct; n += 1
              }
              rows.push([w.name || bareSymbol(w.symbol), last != null ? String(last) : '—', fmtPct(pct), fmtAmt(amt)])
            }
            const selId = symbolId(db, selSymbol)
            let cats = [], vals = [], chartName = '', chartCaption = ''
            if (selId) {
              const hist = readDaily(db, selId, 60).reverse()
              cats = hist.map((b) => new Date(b.ts).toISOString().slice(5, 10))
              vals = hist.map((b) => toFloat(b.close))
              const sel = wl.find((x) => x.symbol === selSymbol)
              chartName = sel ? (sel.name || bareSymbol(sel.symbol)) : bareSymbol(selSymbol)
              chartCaption = hist.length
                ? `${selSymbol} ${zh ? '近' : ''}${hist.length}${zh ? '交易日' : 'd'}`
                : `${selSymbol} ${zh ? '暂无数据' : 'no data'}`
            }
            let status
            if (prog.running) status = `${prog.task} ${prog.detail || ''}`.trim()
            else if (prog.lastError) status = prog.lastError
            else if (!hasRealtime()) status = zh ? '免费源：日K可用，实时需在设置填 Key' : 'Free tier: daily K only'
            else status = zh ? '实时行情已接通' : 'Realtime connected'
            const picks = wl.slice(0, 12).map((w) => ({
              title: w.name || bareSymbol(w.symbol),
              subtitle: bareSymbol(w.symbol),
              trailing: w.symbol === selSymbol ? (zh ? '查看中' : 'shown') : '',
              icon: 'chart',
              action: { id: 'pick', args: { symbol: w.symbol } },
            }))
            emit({
              up: String(up), down: String(down), avg: n ? fmtPct(sum / n) : '—',
              status, statusTone: prog.lastError ? 'warn' : hasRealtime() ? 'good' : 'info',
              rows, cats, vals, chartName, chartCaption, picks,
            })
          } catch (e) {
            emit({
              up: '—', down: '—', avg: '—',
              status: `读取失败：${e && e.message}`, statusTone: 'warn',
              rows: [], cats: [], vals: [], picks: [],
            })
          }
        }
        paint()
        const t = setInterval(paint, 3000)
        return () => { alive = false; clearInterval(t) }
      },
      actions: {
        refresh: async () => {
          const db = open()
          if (hasRealtime()) {
            try {
              const wl = watchlist(db)
              const qs = await fetchQuotes(wl.map((w) => w.symbol))
              writeSnapshots(db, qs)
              setState(db, 'quotes_at', String(Date.now()))
              return { toast: '已刷新', refresh: true }
            } catch (e) { return { toast: `刷新失败：${e.message}` } }
          }
          startTask('日K增量', async () => {
            const r = await syncKlines(db, { full: false })
            return `${r.bars} 根`
          })
          return { toast: '开始同步日K' }
        },
        syncK: () => startTask('K线同步', async () => {
          const r = await syncKlines(open(), { full: true, onStep: step })
          return `${r.bars} 根`
        }),
        pick: (scope, event) => {
          const sym = event && event.value && event.value.symbol
          if (sym) selSymbol = sym
          return { refresh: true }
        },
        toSettings: () => ({ open: 'panel:settings' }),
      },
    })
  })
}

// 表单字段可能落在不同层级，统一捞。
function readInput(event, keys) {
  if (!event) return null
  const pools = [event.value, event.args, event.data, event.form, event.payload]
  for (const p of pools) {
    if (p == null) continue
    if (typeof p === 'string' && keys.length === 1) return p
    if (typeof p === 'object') {
      for (const k of keys) if (p[k] != null) return p[k]
      const vals = Object.values(p).filter((x) => typeof x === 'string')
      if (vals.length === 1) return vals[0]
    }
  }
  return typeof event.value === 'string' ? event.value : null
}
