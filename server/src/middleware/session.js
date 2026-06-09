const session = require('express-session');
const SQLiteStore = require('connect-sqlite3')(session);
const path = require('path');
const config = require('../config');

const dataDir = path.isAbsolute(config.databasePath)
  ? path.dirname(config.databasePath)
  : path.join(process.cwd(), path.dirname(config.databasePath));
const store = new SQLiteStore({ db: 'sessions.db', dir: dataDir });

module.exports = session({
  store,
  secret: config.sessionSecret,
  resave: false,
  saveUninitialized: false,
  name: 'tablet_admin_sid',
  cookie: {
    maxAge: 24 * 60 * 60 * 1000,
    httpOnly: true,
    secure: config.nodeEnv === 'production',
    sameSite: 'lax',
  },
});
