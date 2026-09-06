require('dotenv').config();

const defaultDb = process.env.DATABASE_PATH || process.env.DB_PATH || './data/database.sqlite';
const nodeEnv = process.env.NODE_ENV || 'development';

if (!process.env.SESSION_SECRET && nodeEnv === 'production') {
  console.error('FATAL: SESSION_SECRET environment variable must be set in production');
  process.exit(1);
}
if (!process.env.SESSION_SECRET) {
  console.warn('WARNING: SESSION_SECRET is not set — using insecure default (development only)');
}

module.exports = {
  port: parseInt(process.env.PORT || '5050', 10),
  nodeEnv,
  /*
   * Whether the admin session cookie is marked Secure.
   *
   * It used to be `nodeEnv === 'production'`, which is true inside the container -
   * and there express-session then refuses to send Set-Cookie over plain HTTP. The
   * scoring app calls this server at http://localhost:5050, so POST /api/admin/login
   * answered 200 with no cookie at all, judge-proxy got no session id, and every
   * judge screen showed "Judge server is offline" while 5050 was perfectly alive.
   * That is the whole difference between `pnpm dev` and `pnpm launch`.
   *
   * Same split the scoring app already made (commit "decouple cookie secure flag
   * from NODE_ENV"), and docker-compose.yml already passes COOKIE_SECURE=false.
   * Set it to true only when this server is actually reached over TLS.
   */
  cookieSecure: process.env.COOKIE_SECURE === 'true',
  sessionSecret: process.env.SESSION_SECRET || 'dev-session-secret-change-in-production',
  databasePath: defaultDb,
  databaseTabletsPath: process.env.DB_TABLETS_PATH || defaultDb,
  databaseJudgesPath: process.env.DB_JUDGES_PATH || defaultDb,
  backendBaseUrl: process.env.BACKEND_BASE_URL || 'http://192.168.10.100:5050',
  onlineThresholdSeconds: 60,
  adminUsername: process.env.ADMIN_USERNAME || 'admin',
  adminPassword: process.env.ADMIN_PASSWORD || 'admin123',
};
