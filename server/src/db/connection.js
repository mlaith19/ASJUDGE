const path = require('path');
const config = require('../config');

function resolvePath(p) {
  return path.isAbsolute(p) ? p : path.join(process.cwd(), p);
}

// ── node:sqlite compatibility wrapper (same API as better-sqlite3) ────────────
class _Stmt {
  constructor(s) { this._s = s; }
  _named(o) {
    const out = {};
    for (const [k, v] of Object.entries(o))
      out[/^[:@$]/.test(k) ? k : `:${k}`] = v;
    return out;
  }
  _args(a) {
    return a.length === 1 && a[0] !== null && typeof a[0] === 'object' && !Array.isArray(a[0])
      ? [this._named(a[0])] : a;
  }
  run(...a) { return this._s.run(...this._args(a)); }
  get(...a) { return this._s.get(...this._args(a)); }
  all(...a) { return this._s.all(...this._args(a)); }
}

class _NodeDb {
  constructor(p) { const { DatabaseSync } = require('node:sqlite'); this._db = new DatabaseSync(p); }
  pragma(s)  { this._db.exec(`PRAGMA ${s}`); }
  exec(s)    { this._db.exec(s); }
  prepare(s) { return new _Stmt(this._db.prepare(s)); }
  close()    { this._db.close(); }
}
// ─────────────────────────────────────────────────────────────────────────────

let Database;
try {
  Database = require('better-sqlite3');
  new Database(':memory:').close();
} catch {
  Database = _NodeDb;
}

const tabletsPath = resolvePath(config.databaseTabletsPath);
const judgesPath  = resolvePath(config.databaseJudgesPath);
const singleDb    = tabletsPath === judgesPath;

const dbTablets = new Database(tabletsPath);
dbTablets.pragma('journal_mode = WAL');

const dbJudges = singleDb ? dbTablets : (() => {
  const db = new Database(judgesPath);
  db.pragma('journal_mode = WAL');
  return db;
})();

const conn    = dbJudges;
conn.dbTablets = dbTablets;
conn.dbJudges  = dbJudges;
conn.db        = dbJudges;
module.exports = conn;
