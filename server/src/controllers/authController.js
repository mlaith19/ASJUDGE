const bcrypt = require('bcrypt');
const Admin = require('../models/Admin');

function loginPage(req, res) {
  res.render('login', {
    title: 'Login',
    error: req.flash('error'),
    success: req.flash('success'),
  });
}

async function login(req, res) {
  try {
    const { username, password } = req.body;
    if (!username || !password) {
      req.flash('error', 'Username and password are required');
      return res.redirect('/admin/login');
    }

    const admin = Admin.findByUsername(username.trim());
    if (!admin) {
      req.flash('error', 'Invalid credentials');
      return res.redirect('/admin/login');
    }

    const match = await bcrypt.compare(password, admin.password_hash);
    if (!match) {
      req.flash('error', 'Invalid credentials');
      return res.redirect('/admin/login');
    }

    req.session.adminId = admin.id;
    req.session.adminUsername = admin.username;
    return res.redirect('/admin/dashboard');
  } catch (err) {
    console.error('Login error:', err);
    req.flash('error', 'An error occurred');
    return res.redirect('/admin/login');
  }
}

function logout(req, res) {
  req.session.destroy(() => {
    res.redirect('/admin/login');
  });
}

module.exports = { loginPage, login, logout };
