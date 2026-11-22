// Claude Watch relay - zero deps.
//   PC watcher: POST /api/sessions (snapshot: sessions, catalog, results, quickReplies)
//               GET  /api/commands            (takes queued commands, clears the queue)
//   Watch:      GET  /api/sessions?since=N    (long poll, up to 25 s; watchOS has no WebSockets)
//               POST /api/commands            {session, prompt, model?, effort?, tier?}
//   Pairing:    POST /api/pair (PC, token)    -> {code}   6 digits, 10 min, single use
//               POST /api/pair/claim {code}   -> {token}  (no auth; rate limited)
// env: PORT (8792), TOKEN (shared secret, required)
const http = require('http');
const crypto = require('crypto');
const PORT = +process.env.PORT || 8792, TOKEN = process.env.TOKEN || '';
if (!TOKEN) { console.error('TOKEN env required'); process.exit(1); }

let state = { version: 0, pcSeen: 0, sessions: [], catalog: [], results: [], quickReplies: [] };
let queue = [];      // commands not yet picked up by the PC
let waiters = [];
let pair = null;       // {code, expires, misses}
let pairFails = [];    // timestamps of wrong claims (last hour)

const send = (res, code, obj) => { res.writeHead(code, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }); res.end(JSON.stringify(obj)); };
const authed = req => (req.headers.authorization || '') === 'Bearer ' + TOKEN;
const view = () => ({ ...state, queued: queue.map(c => c.id), pcOnline: Date.now() - state.pcSeen < 90000, now: Date.now() });
const fingerprint = s => JSON.stringify([
  (s.sessions || []).map(x => [x.id, x.state, x.detail, x.model, x.effort]),
  s.catalog, s.results, s.quickReplies]);
const bump = () => { state.version++; const w = waiters; waiters = []; w.forEach(f => f()); };
const readBody = (req, cb) => {
  let body = '';
  req.on('data', c => { body += c; if (body.length > 300000) req.destroy(); });
  req.on('end', () => { try { cb(JSON.parse(body || '{}')); } catch { cb(null); } });
};
const str = (v, max) => typeof v === 'string' ? v.slice(0, max) : '';

http.createServer((req, res) => {
  const url = new URL(req.url, 'http://x');
  if (url.pathname === '/health') return send(res, 200, { ok: true });

  // Pairing: the PC (holding the token) asks for a 6-digit code; the watch trades the code for
  // the token. One code at a time, 10 minutes, single use, 5 wrong guesses kill it, and more
  // than 20 wrong guesses in an hour shut pairing off until the hour is up.
  if (url.pathname === '/api/pair/claim' && req.method === 'POST') {
    return readBody(req, b => {
      const now = Date.now();
      pairFails = pairFails.filter(t => now - t < 3600000);
      if (pairFails.length >= 20) return send(res, 429, { error: 'Too many tries. Wait an hour.' });
      const ok = pair && now < pair.expires && b && typeof b.code === 'string' &&
        crypto.timingSafeEqual(Buffer.from(b.code.padEnd(6).slice(0, 6)), Buffer.from(pair.code));
      if (!ok) {
        pairFails.push(now);
        if (pair && ++pair.misses >= 5) pair = null;
        return send(res, 403, { error: pair ? 'Wrong code' : 'No active code. Make a new one on the PC.' });
      }
      pair = null;
      send(res, 200, { token: TOKEN });
    });
  }

  if (!authed(req)) return send(res, 401, { error: 'bad token' });

  if (url.pathname === '/api/pair' && req.method === 'POST') {
    pair = { code: String(crypto.randomInt(0, 1000000)).padStart(6, '0'), expires: Date.now() + 600000, misses: 0 };
    return send(res, 200, { code: pair.code, expiresIn: 600 });
  }

  if (url.pathname === '/api/sessions' && req.method === 'POST') {
    return readBody(req, b => {
      if (!b) return send(res, 400, { error: 'bad json' });
      const next = {
        sessions: (b.sessions || []).slice(0, 30), catalog: (b.catalog || []).slice(0, 40),
        results: (b.results || []).slice(0, 20), quickReplies: (b.quickReplies || []).slice(0, 12),
      };
      const changed = fingerprint(next) !== fingerprint(state);
      state = { ...state, ...next, pcSeen: Date.now() };
      if (changed) bump();
      send(res, 200, { version: state.version });
    });
  }

  if (url.pathname === '/api/commands' && req.method === 'POST') {
    return readBody(req, b => {
      if (!b || !str(b.session, 80) || !str(b.prompt, 4000).trim()) return send(res, 400, { error: 'session and prompt required' });
      // model / effort / tier are validated on the PC against the live catalog, not here
      const cmd = { id: crypto.randomUUID(), session: str(b.session, 80), prompt: str(b.prompt, 4000),
                    model: str(b.model, 80), effort: str(b.effort, 20), tier: str(b.tier, 40), at: Date.now() };
      queue.push(cmd); queue = queue.slice(-20);
      bump();
      send(res, 200, { id: cmd.id });
    });
  }

  if (url.pathname === '/api/commands' && req.method === 'GET') {
    const out = queue; queue = [];
    if (out.length) bump();
    return send(res, 200, { commands: out });
  }

  if (url.pathname === '/api/sessions' && req.method === 'GET') {
    const since = +url.searchParams.get('since');
    if (!url.searchParams.has('since') || since !== state.version) return send(res, 200, view());
    const done = () => { clearTimeout(t); send(res, 200, view()); };
    const t = setTimeout(() => { waiters = waiters.filter(f => f !== done); send(res, 200, view()); }, 25000);
    waiters.push(done);
    req.on('close', () => { clearTimeout(t); waiters = waiters.filter(f => f !== done); });
    return;
  }
  send(res, 404, { error: 'not found' });
}).listen(PORT, () => console.log('claude-watch relay on', PORT));
