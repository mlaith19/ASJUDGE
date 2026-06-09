const https = require('https');

function _buildText(eventType, data = {}) {
  const letter = data.judgeLetter ? `[${data.judgeLetter}]` : '';
  const name = data.judgeName ? ` (${data.judgeName})` : '';
  const judge = `${letter}${name}`.trim() || 'Unknown judge';
  switch (eventType) {
    case 'judge_online':     return `Judge ${judge} connected`;
    case 'judge_offline':    return `Judge ${judge} disconnected`;
    case 'judge_assigned':   return `Judge ${judge} assigned to tablet`;
    case 'judge_unassigned': return `Judge ${judge} unassigned from tablet`;
    case 'judge_login':      return `Judge ${judge} logged in`;
    case 'judge_logout':     return `Judge ${judge} logged out`;
    case 'low_battery':      return `Judge ${judge} battery at ${data.batteryLevel ?? '?'}%`;
    default:                 return `Alert: ${eventType}`;
  }
}

function sendMessage(token, chatId, text) {
  return new Promise((resolve) => {
    const body = JSON.stringify({ chat_id: chatId, text });
    const req = https.request(
      {
        hostname: 'api.telegram.org',
        path: `/bot${token}/sendMessage`,
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
      },
      (res) => {
        let raw = '';
        res.on('data', (c) => (raw += c));
        res.on('end', () => {
          try { resolve(JSON.parse(raw)); } catch { resolve({ ok: false }); }
        });
      }
    );
    req.on('error', (e) => resolve({ ok: false, error: e.message }));
    req.write(body);
    req.end();
  });
}

function notify(eventType, data = {}) {
  let token, chatId;
  try {
    const s = require('./settingsService').get();
    token = (s.telegram_bot_token || '').trim();
    chatId = (s.telegram_chat_id || '').trim();
  } catch (_) { return; }
  if (!token || !chatId) return;
  const text = _buildText(eventType, data);
  sendMessage(token, chatId, text)
    .then((r) => { if (!r.ok) console.error('[Telegram]', r.description || r.error || 'send failed'); })
    .catch(() => {});
}

module.exports = { notify, sendMessage };
