function escapeHtml(str) {
  if (str == null || typeof str !== 'string') return '';
  return str
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function sanitizeString(str, maxLength = 500) {
  if (str == null || typeof str !== 'string') return '';
  return str.trim().slice(0, maxLength);
}

module.exports = { escapeHtml, sanitizeString };
