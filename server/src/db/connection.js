const path = require('path');
const Database = require('better-sqlite3');
const config = require('../config');

function resolvePath(p) {
  return path.isAbsolute(p) ? p : path.join(process.cwd(), p);
}

const tabletsPath = resolvePath(config.databaseTabletsPath);
const judgesPath = resolvePath(config.databaseJudgesPath);
const singleDb = tabletsPath === judgesPath;

const dbTablets = new Database(tabletsPath);
dbTablets.pragma('journal_mode = WAL');

const dbJudges = singleDb ? dbTablets : (() => {
  const db = new Database(judgesPath);
  db.pragma('journal_mode = WAL');
  return db;
})();

const conn = dbJudges;
conn.dbTablets = dbTablets;
conn.dbJudges = dbJudges;
conn.db = dbJudges;
module.exports = conn;
