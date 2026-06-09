function requireAuth(req, res, next) {
  if (req.session && req.session.adminId) {
    return next();
  }
  if (req.xhr || req.headers.accept?.includes('application/json')) {
    return res.status(401).json({ error: 'Unauthorized' });
  }
  return res.redirect('/admin/login');
}

function optionalAuth(req, res, next) {
  req.isAdmin = !!(req.session && req.session.adminId);
  next();
}

module.exports = { requireAuth, optionalAuth };
