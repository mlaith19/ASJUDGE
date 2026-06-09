const Tablet = require('../models/Tablet');
const TabletLog = require('../models/TabletLog');
const Settings = require('../models/Settings');
const { isValidUrl } = require('../middleware/validate');
const { timeAgo } = require('../utils/helpers');

function tabletsList(req, res) {
  Tablet.updateOnlineStatus();
  const tablets = Tablet.findAll();
  const settings = Settings.get();
  res.render('tablets-list', {
    title: 'All Tablets',
    tablets,
    settings,
    timeAgo,
    admin: { username: req.session.adminUsername },
    error: req.flash('error'),
    success: req.flash('success'),
  });
}

function tabletDetail(req, res) {
  Tablet.updateOnlineStatus();
  const tablet = Tablet.findById(req.params.id);
  if (!tablet) {
    req.flash('error', 'Tablet not found');
    return res.redirect('/admin/tablets');
  }

  const settings = Settings.get();
  const logs = TabletLog.findByTabletId(tablet.id, 30);
  const effectiveUrl = tablet.custom_webview_url || settings.global_webview_url;

  res.render('tablet-detail', {
    title: `Tablet: ${tablet.judge_name || tablet.device_id}`,
    tablet,
    settings,
    logs,
    effectiveUrl,
    timeAgo,
    admin: { username: req.session.adminUsername },
    error: req.flash('error'),
    success: req.flash('success'),
  });
}

function updateTablet(req, res) {
  try {
    const tablet = Tablet.findById(req.params.id);
    if (!tablet) {
      req.flash('error', 'Tablet not found');
      return res.redirect('/admin/tablets');
    }

    const { judge_name, tablet_label, custom_webview_url, note } = req.body;

    if (custom_webview_url && !isValidUrl(custom_webview_url)) {
      req.flash('error', 'Invalid custom WebView URL');
      return res.redirect(`/admin/tablets/${req.params.id}`);
    }

    Tablet.update(req.params.id, {
      judgeName: (judge_name || '').trim(),
      tabletLabel: (tablet_label || '').trim(),
      customWebviewUrl: (custom_webview_url || '').trim(),
      note: (note || '').trim(),
    });

    TabletLog.create(tablet.id, 'admin_update', {
      judgeName: judge_name,
      tabletLabel: tablet_label,
      customWebviewUrl: custom_webview_url,
    });

    req.flash('success', 'Tablet updated successfully');
    return res.redirect(`/admin/tablets/${req.params.id}`);
  } catch (err) {
    console.error('Tablet update error:', err);
    req.flash('error', 'Failed to update tablet');
    return res.redirect(`/admin/tablets/${req.params.id}`);
  }
}

function forceReload(req, res) {
  try {
    const tablet = Tablet.findById(req.params.id);
    if (!tablet) {
      req.flash('error', 'Tablet not found');
      return res.redirect('/admin/tablets');
    }

    Tablet.setForceReload(req.params.id);
    TabletLog.create(tablet.id, 'force_reload', {});

    req.flash('success', 'Force reload scheduled for tablet');
    return res.redirect(`/admin/tablets/${req.params.id}`);
  } catch (err) {
    console.error('Force reload error:', err);
    req.flash('error', 'Failed to schedule force reload');
    return res.redirect(`/admin/tablets/${req.params.id}`);
  }
}

module.exports = { tabletsList, tabletDetail, updateTablet, forceReload };
