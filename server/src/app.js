const path = require('path');
const fs = require('fs');
const express = require('express');
const morgan = require('morgan');
const sessionMiddleware = require('./middleware/session');
const apiTablets = require('./routes/api/tablets');
const apiAdmin = require('./routes/api/admin');
const judgesService = require('./services/judgesService');
const adminAuth = require('./routes/admin/auth');
const adminDashboard = require('./routes/admin/dashboard');

const app = express();

// Discovery endpoints first (no middleware that could interfere)
const pingResponse = { ok: true, service: 'judge-backend', version: '1.0.0' };
app.get('/api/ping', (req, res) => res.json(pingResponse));
app.get('/api/health', (req, res) => res.json(pingResponse));

app.set('view engine', 'ejs');
app.set('views', path.join(__dirname, 'views'));

// Static assets (logo, etc.) – served at / e.g. /logo.png
app.use(express.static(path.join(__dirname, 'public')));

app.use(morgan('combined'));
app.use(express.json({ limit: '256kb' }));
app.use(express.urlencoded({ extended: true, limit: '256kb' }));
app.use(sessionMiddleware);

app.use((req, res, next) => {
  res.locals.flash = req.session?.flash;
  if (req.session && req.session.flash) delete req.session.flash;
  next();
});

app.get('/api/judges/list', (req, res) => {
  try {
    const list = judgesService.listForTablet();
    return res.json(list);
  } catch (err) {
    return res.status(500).json({ error: err.message || 'Failed' });
  }
});
app.use('/api/tablets', apiTablets);
app.use('/api/admin', apiAdmin);
app.get('/admin', (req, res) => {
  res.redirect(req.session?.adminId ? '/admin/dashboard' : '/admin/login');
});
app.use('/admin', adminAuth);
app.use('/admin', adminDashboard);

app.get('/', (req, res) => {
  res.redirect(req.session?.adminId ? '/admin/dashboard' : '/admin/login');
});

app.use((err, req, res, next) => {
  console.error(err);
  res.status(500).send('Server error');
});

module.exports = app;
