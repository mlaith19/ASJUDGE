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
  sessionSecret: process.env.SESSION_SECRET || 'dev-session-secret-change-in-production',
  databasePath: defaultDb,
  databaseTabletsPath: process.env.DB_TABLETS_PATH || defaultDb,
  databaseJudgesPath: process.env.DB_JUDGES_PATH || defaultDb,
  backendBaseUrl: process.env.BACKEND_BASE_URL || 'http://192.168.10.100:5050',
  onlineThresholdSeconds: 60,
  adminUsername: process.env.ADMIN_USERNAME || 'admin',
  adminPassword: process.env.ADMIN_PASSWORD || 'admin123',
};
