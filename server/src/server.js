// Schema first, before anything opens the database.
//
// init.js is idempotent - every statement is CREATE TABLE IF NOT EXISTS or INSERT OR
// IGNORE - so on an existing database this does nothing. On an empty one it is the
// difference between a working server and "no such table: tablets", which is what a
// fresh `db-data` volume gave every time the container was rebuilt.
require('./db/init');
require('./db/bootstrap-admin');

const http = require('http');
const app = require('./app');
const config = require('./config');
const sessionMiddleware = require('./middleware/session');

const server = http.createServer(app);
require('./socket').init(server, sessionMiddleware);

server.listen(config.port, '0.0.0.0', () => {
  console.log(`Tablet Monitor Backend listening on port ${config.port}`);
  console.log(`Admin: http://localhost:${config.port}/admin/login`);
  console.log(`WebSocket: /socket.io (namespaces: /tablet, /admin)`);
});

server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') {
    console.error(`Port ${config.port} is already in use. Stop the other process or set PORT in .env.`);
    console.error('Windows: netstat -ano | findstr :' + config.port + ' then taskkill /PID <pid> /F');
  } else {
    console.error(err);
  }
  process.exit(1);
});
