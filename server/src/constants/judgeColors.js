/**
 * Shared judge/tablet color palette. Keys are stable; use same in admin and Flutter app.
 * Each entry: { key, hex }
 */
const JUDGE_COLORS = [
  { key: 'red', hex: '#dc3545' },
  { key: 'blue', hex: '#0d6efd' },
  { key: 'green', hex: '#198754' },
  { key: 'orange', hex: '#fd7e14' },
  { key: 'yellow', hex: '#ffc107' },
  { key: 'purple', hex: '#6f42c1' },
  { key: 'pink', hex: '#d63384' },
  { key: 'teal', hex: '#20c997' },
  { key: 'cyan', hex: '#0dcaf0' },
  { key: 'lime', hex: '#84cc16' },
  { key: 'indigo', hex: '#6610f2' },
  { key: 'brown', hex: '#795548' },
  { key: 'gold', hex: '#ffb300' },
  { key: 'magenta', hex: '#c2185b' },
  { key: 'dark_blue', hex: '#1e3a5f' },
];

const COLOR_BY_KEY = Object.fromEntries(JUDGE_COLORS.map((c) => [c.key, c.hex]));

function getHex(key) {
  if (!key || typeof key !== 'string') return null;
  return COLOR_BY_KEY[key.trim().toLowerCase()] || null;
}

function isValidKey(key) {
  return !!getHex(key);
}

/** V0/admin sends hex; map to backend key. Exact match or first key. */
function hexToKey(hex) {
  if (!hex || typeof hex !== 'string') return '';
  const h = hex.trim().toLowerCase();
  if (!h.startsWith('#')) return '';
  for (const { key, hex: hx } of JUDGE_COLORS) {
    if (hx && hx.toLowerCase() === h) return key;
  }
  return JUDGE_COLORS[0] ? JUDGE_COLORS[0].key : '';
}

module.exports = {
  JUDGE_COLORS,
  COLOR_BY_KEY,
  getHex,
  isValidKey,
  hexToKey,
};
