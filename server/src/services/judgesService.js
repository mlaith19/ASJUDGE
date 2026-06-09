const db = require('../db/connection');
const { sanitizeString } = require('../utils/sanitize');
const { isValidKey, getHex, hexToKey } = require('../constants/judgeColors');
const config = require('../config');

const LETTERS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split('');

function list() {
  return db.prepare('SELECT * FROM judges ORDER BY judge_letter ASC').all();
}

function getById(id) {
  return db.prepare('SELECT * FROM judges WHERE id = ?').get(id) || null;
}

function getByLetter(letter) {
  if (!letter || typeof letter !== 'string') return null;
  const normalized = letter.trim().toUpperCase();
  return db.prepare('SELECT * FROM judges WHERE judge_letter = ?').get(normalized) || null;
}

function getNextAvailableLetter() {
  const used = db.prepare('SELECT judge_letter FROM judges ORDER BY judge_letter').all().map((r) => r.judge_letter.toUpperCase());
  for (const L of LETTERS) {
    if (!used.includes(L)) return L;
  }
  return null;
}

function create(data) {
  const name = sanitizeString(data.judge_name || '', 200);
  const colorRaw = data.judge_color;
  let color = '';
  if (colorRaw) {
    const s = String(colorRaw).trim();
    color = s.startsWith('#') ? hexToKey(s) : (isValidKey(s) ? s.toLowerCase() : '');
  }
  const username = sanitizeString(data.username || '', 100);
  const password = typeof data.password === 'string' ? data.password : '';
  let letter = (data.judge_letter || '').toString().trim().toUpperCase();
  if (letter && letter.length >= 2) {
    if (letter.length > 10) throw new Error('Judge code must be 2–10 characters');
    if (!/^[A-Z0-9]+$/.test(letter)) throw new Error('Judge code may only contain letters and numbers');
    const existing = getByLetter(letter);
    if (existing) throw new Error(`Code "${letter}" is already in use`);
  } else if (letter && letter.length === 1) {
    const existing = getByLetter(letter);
    if (existing) throw new Error(`Judge letter ${letter} is already in use`);
  } else {
    letter = getNextAvailableLetter();
  }
  if (!letter) throw new Error('No available judge letter (A–Z in use)');
  db.prepare(
    'INSERT INTO judges (judge_letter, judge_name, judge_color, username, password) VALUES (?, ?, ?, ?, ?)'
  ).run(letter, name, color, username, password);
  return getByLetter(letter);
}

function update(id, data) {
  const judge = getById(id);
  if (!judge) throw new Error('Judge not found');
  const updates = [];
  const params = [];
  if (data.judge_name !== undefined) {
    updates.push('judge_name = ?');
    params.push(sanitizeString(String(data.judge_name), 200));
  }
  let newLetter = null;
  if (data.judge_letter !== undefined) {
    const letter = sanitizeString(String(data.judge_letter).trim().toUpperCase(), 10);
    if (letter.length >= 2) {
      if (letter.length > 10) throw new Error('Judge code must be 2–10 characters');
      if (!/^[A-Z0-9]+$/.test(letter)) throw new Error('Judge code may only contain letters and numbers');
    } else if (letter.length === 1) {
      // single letter: no extra validation
    } else {
      throw new Error('Judge letter or code is required');
    }
    const existing = getByLetter(letter);
    if (existing && existing.id !== id) throw new Error(`Letter/code "${letter}" is already in use`);
    newLetter = letter;
    updates.push('judge_letter = ?');
    params.push(letter);
  }
  if (data.judge_color !== undefined) {
    const val = String(data.judge_color).trim();
    const colorVal = val.startsWith('#') ? hexToKey(val) : (isValidKey(val) ? val.toLowerCase() : '');
    updates.push('judge_color = ?');
    params.push(colorVal);
  }
  if (data.username !== undefined) {
    updates.push('username = ?');
    params.push(sanitizeString(String(data.username), 100));
  }
  if (data.password !== undefined) {
    updates.push('password = ?');
    params.push(typeof data.password === 'string' ? data.password : '');
  }
  if (updates.length === 0) return judge;
  params.push(id);
  db.prepare(`UPDATE judges SET ${updates.join(', ')}, updated_at = datetime('now') WHERE id = ?`).run(...params);
  if (newLetter && (judge.judge_letter || '').toUpperCase() !== newLetter) {
    const tabletService = require('./tabletService');
    tabletService.updateTabletsByJudgeLetter((judge.judge_letter || '').toUpperCase(), newLetter, data.judge_name !== undefined ? data.judge_name : judge.judge_name);
  }
  return getById(id);
}

function remove(id) {
  const judge = getById(id);
  if (!judge) throw new Error('Judge not found');
  db.prepare('DELETE FROM judges WHERE id = ?').run(id);
  return true;
}

/** For tablet API: list of { letter, name, color } for dropdown */
function listForTablet() {
  return list().map((j) => ({
    letter: j.judge_letter || '',
    name: j.judge_name || '',
    color: j.judge_color || '',
  }));
}

/** Judge is online if a tablet with this judge_letter has recent heartbeat */
function getTabletForJudge(letter) {
  if (!letter || typeof letter !== 'string') return null;
  const normalized = letter.trim().toUpperCase();
  const cutoff = new Date(Date.now() - (config.onlineThresholdSeconds || 60) * 1000).toISOString();
  return db.prepare(
    'SELECT * FROM tablets WHERE UPPER(TRIM(judge_letter)) = ? AND last_seen_at >= ? ORDER BY last_seen_at DESC LIMIT 1'
  ).get(normalized, cutoff) || null;
}

/** All judges with their linked tablet (if any) and online status */
function listWithTabletStatus() {
  const judges = list();
  const result = [];
  for (const j of judges) {
    const tablet = getTabletForJudge(j.judge_letter);
    const online = !!tablet;
    result.push({
      ...j,
      online,
      tablet_id: tablet ? tablet.id : null,
      device_id: tablet ? tablet.device_id : null,
    });
  }
  return result;
}

module.exports = {
  list,
  getById,
  getByLetter,
  getNextAvailableLetter,
  create,
  update,
  remove,
  listForTablet,
  getTabletForJudge,
  listWithTabletStatus,
};
