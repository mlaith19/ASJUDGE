const express = require('express');
const router = express.Router();
const rateLimit = require('express-rate-limit');
const adminService = require('../../services/adminService');
const { requireAuth } = require('../../middleware/auth');

const loginLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 20,
  standardHeaders: true,
  legacyHeaders: false,
  handler: (req, res) => {
    res.render('admin/login', { title: 'Admin Login', error: 'Too many login attempts, please try again later' });
  },
});

router.get('/login', (req, res) => {
  if (req.session && req.session.adminId) {
    return res.redirect('/admin/dashboard');
  }
  res.render('admin/login', { title: 'Admin Login', error: null });
});

router.post('/login', loginLimiter, async (req, res) => {
  const { username, password } = req.body || {};
  if (!username || !password) {
    return res.render('admin/login', { title: 'Admin Login', error: 'Username and password required' });
  }
  try {
    const admin = await adminService.verifyPassword(String(username).trim(), password);
    if (!admin) {
      return res.render('admin/login', { title: 'Admin Login', error: 'Invalid username or password' });
    }
    req.session.adminId = admin.id;
    req.session.adminUsername = admin.username;
    return res.redirect('/admin/dashboard');
  } catch (err) {
    return res.render('admin/login', { title: 'Admin Login', error: 'Login failed' });
  }
});

router.post('/logout', (req, res) => {
  req.session.destroy(() => {
    res.redirect('/admin/login');
  });
});

module.exports = router;
