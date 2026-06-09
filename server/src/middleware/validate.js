const { validationResult } = require('express-validator');

function handleValidation(req, res, next) {
  const errors = validationResult(req);
  if (!errors.isEmpty()) {
    return res.status(400).json({ success: false, errors: errors.array() });
  }
  next();
}

function isValidUrl(str) {
  if (!str) return true;
  try {
    new URL(str);
    return true;
  } catch {
    return false;
  }
}

module.exports = { handleValidation, isValidUrl };
