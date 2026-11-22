// APNs push for Claude Watch - zero deps (Node's http2 + crypto).
// env: APNS_KEY (the .p8 text, \n allowed), APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC (watch bundle id),
//      APNS_HOST (default production api.push.apple.com: TestFlight builds use production).
// Device tokens are kept in DATA_DIR/devices.json so a redeploy does not lose them.
const http2 = require('http2');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const KEY = (process.env.APNS_KEY || '').replace(/\\n/g, '\n');
const KEY_ID = process.env.APNS_KEY_ID || '', TEAM = process.env.APNS_TEAM_ID || '';
const TOPIC = process.env.APNS_TOPIC || 'au.com.strapify.claudewatch.watchkitapp';
const HOST = process.env.APNS_HOST || 'https://api.push.apple.com';
const FILE = path.join(process.env.DATA_DIR || '/data', 'devices.json');
const enabled = !!(KEY && KEY_ID && TEAM);

let devices = {};   // token -> {added, lastOk}
try { devices = JSON.parse(fs.readFileSync(FILE, 'utf8')); } catch { /* first run */ }
const save = () => { try { fs.writeFileSync(FILE, JSON.stringify(devices)); } catch (e) { console.error('devices save', e.message); } };

function register(token) {
  if (!/^[0-9a-f]{64,200}$/i.test(token || '')) return false;
  if (!devices[token]) { devices[token] = { added: Date.now() }; save(); }
  return true;
}

let jwt = null, jwtAt = 0;   // Apple wants the same token reused, refreshed under an hour
function bearer() {
  if (jwt && Date.now() - jwtAt < 40 * 60000) return jwt;
  const b64 = o => Buffer.from(JSON.stringify(o)).toString('base64url');
  const head = b64({ alg: 'ES256', kid: KEY_ID }), body = b64({ iss: TEAM, iat: Math.floor(Date.now() / 1000) });
  const sig = crypto.sign('sha256', Buffer.from(head + '.' + body), { key: KEY, dsaEncoding: 'ieee-p1363' }).toString('base64url');
  jwt = `${head}.${body}.${sig}`; jwtAt = Date.now();
  return jwt;
}

let client = null;
function conn() {
  if (client && !client.closed && !client.destroyed) return client;
  client = http2.connect(HOST);
  client.on('error', e => { console.error('apns conn', e.message); client = null; });
  client.setTimeout(10 * 60000, () => { client.close(); client = null; });
  return client;
}

function sendOne(token, payload, collapse) {
  return new Promise(resolve => {
    let req;
    try {
      req = conn().request({
        ':method': 'POST', ':path': '/3/device/' + token,
        authorization: 'bearer ' + bearer(), 'apns-topic': TOPIC, 'apns-push-type': 'alert',
        'apns-priority': '10', 'apns-collapse-id': collapse.slice(0, 64),
      });
    } catch (e) { console.error('apns req', e.message); return resolve(); }
    let status = 0, body = '';
    req.on('response', h => { status = h[':status']; });
    req.on('data', d => { body += d; });
    req.on('end', () => {
      if (status === 200) { devices[token] && (devices[token].lastOk = Date.now()); }
      else {
        console.error('apns', status, body);
        // gone for good: uninstalled, or a token from another environment
        if (status === 410 || /BadDeviceToken|Unregistered|DeviceTokenNotForTopic/.test(body)) { delete devices[token]; save(); }
      }
      resolve();
    });
    req.on('error', e => { console.error('apns send', e.message); resolve(); });
    req.end(JSON.stringify(payload));
  });
}

// Remember what each session last notified, so a flicker (ready -> working -> ready within
// one turn) or a repeat snapshot does not buzz twice for the same thing.
const notified = new Map();   // session id -> state we last pushed

/** Compare two snapshots' sessions and push for each that just became ready or waiting. */
function onSnapshot(prev, next) {
  const before = new Map((prev || []).map(s => [s.id, s.state]));
  const out = [];
  for (const s of next || []) {
    const was = before.get(s.id);
    if (s.state === 'working') { notified.delete(s.id); continue; }
    if (was === undefined || was === s.state) continue;          // new to the list, or unchanged
    if (s.state !== 'ready' && s.state !== 'waiting') continue;
    if (notified.get(s.id) === s.state) continue;
    notified.set(s.id, s.state);
    out.push(s);
  }
  if (!enabled || !out.length) return out.length;
  for (const s of out) {
    const waiting = s.state === 'waiting';
    const payload = {
      aps: {
        alert: { title: waiting ? 'Claude needs you' : 'Claude is done', subtitle: s.title, body: (s.detail || '').slice(0, 180) },
        // 'time-sensitive' would need an extra entitlement; 'active' rings and shows normally
        sound: 'default', 'thread-id': s.id, 'interruption-level': 'active',
      },
      session: s.id,
    };
    for (const t of Object.keys(devices)) sendOne(t, payload, s.id + ':' + s.state);
  }
  return out.length;
}

module.exports = { enabled, register, onSnapshot, deviceCount: () => Object.keys(devices).length };
