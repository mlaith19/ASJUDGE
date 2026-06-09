function isValidHttpUrl(str) {
  if (typeof str !== 'string' || !str.trim()) return false;
  const trimmed = str.trim();
  try {
    const u = new URL(trimmed);
    return u.protocol === 'http:' || u.protocol === 'https:';
  } catch {
    return false;
  }
}

function sanitizeUrl(str) {
  if (typeof str !== 'string') return '';
  return str.trim();
}

module.exports = { isValidHttpUrl, sanitizeUrl };
