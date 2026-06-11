let bcrypt; try { bcrypt = require('bcrypt'); } catch { bcrypt = require('bcryptjs'); }
let Database; try { Database = require('better-sqlite3'); new Database(':memory:').close(); } catch { const {DatabaseSync}=require('node:sqlite'); Database=class{constructor(p){this._db=new DatabaseSync(p);}pragma(s){this._db.exec(`PRAGMA ${s}`);}prepare(s){const st=this._db.prepare(s);const w=(a)=>{if(a.length===1&&a[0]&&typeof a[0]==='object'&&!Array.isArray(a[0])){const o={};for(const[k,v]of Object.entries(a[0]))o[/^[:@$]/.test(k)?k:`:`+k]=v;return[o];}return a;};return{run:(...a)=>st.run(...w(a)),get:(...a)=>st.get(...w(a)),all:(...a)=>st.all(...w(a))};}close(){this._db.close();}}; }
const config = require('../config');
const path = require('path');

const dbPath = path.isAbsolute(config.databaseJudgesPath)
  ? config.databaseJudgesPath
  : path.join(process.cwd(), config.databaseJudgesPath);

const db = new Database(dbPath);

const DEV_USERNAME = 'admin';
const DEV_PASSWORD = 'admin123';

async function seed() {
  const hash = await bcrypt.hash(DEV_PASSWORD, 10);
  const stmt = db.prepare(`
    INSERT OR REPLACE INTO admins (id, username, password_hash, updated_at)
    VALUES (1, ?, ?, datetime('now'))
  `);
  stmt.run(DEV_USERNAME, hash);
  db.close();
  console.log('Development admin user created.');
  console.log('  Username:', DEV_USERNAME);
  console.log('  Password:', DEV_PASSWORD);
  console.log('  ⚠️  DEVELOPMENT ONLY - change in production!');
}

seed().catch((err) => {
  console.error(err);
  process.exit(1);
});
