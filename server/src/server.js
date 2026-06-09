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
