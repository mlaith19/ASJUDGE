const Tablet = require('../models/Tablet');
const Settings = require('../models/Settings');
const { timeAgo } = require('../utils/helpers');

function dashboard(req, res) {
  Tablet.updateOnlineStatus();

  const { q, status, low_battery } = req.query;
  const tablets = Tablet.search({
    query: q || '',
    status: status || '',
    lowBattery: low_battery === '1',
  });

  const settings = Settings.get();
  const stats = {
    total: tablets.length,
    online: tablets.filter(t => t.is_online).length,
    offline: tablets.filter(t => !t.is_online).length,
    lowBattery: tablets.filter(t => t.battery_level !== null && t.battery_level <= 20).length,
  };

  res.render('dashboard', {
    title: 'Dashboard',
    tablets,
    settings,
    stats,
    filters: { q, status, low_battery },
    timeAgo,
    admin: { username: req.session.adminUsername },
    error: req.flash('error'),
    success: req.flash('success'),
  });
}

module.exports = { dashboard };
