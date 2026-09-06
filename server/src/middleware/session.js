const session = require('express-session');
const path    = require('path');
const config  = require('../config');

let store;
try {
  const SQLiteStore = require('connect-sqlite3')(session);
  const dataDir = path.isAbsolute(config.databasePath)
    ? path.dirname(config.databasePath)
    : path.join(process.cwd(), path.dirname(config.databasePath));
  store = new SQLiteStore({ db: 'sessions.db', dir: dataDir });
} catch {
  store = undefined; // MemoryStore fallback (sessions lost on restart — fine for single admin)
}

module.exports = session({
  ...(store ? { store } : {}),
  secret: config.sessionSecret,
  resave: false,
  saveUninitialized: false,
  name: 'tablet_admin_sid',
  cookie: {
    maxAge: 24 * 60 * 60 * 1000,
    httpOnly: true,
    secure: config.cookieSecure,
    sameSite: 'lax',
  },
});
