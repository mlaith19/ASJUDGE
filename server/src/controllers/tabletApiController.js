const Tablet = require('../models/Tablet');
const TabletLog = require('../models/TabletLog');
const { sanitizeString } = require('../utils/helpers');
const { isValidUrl } = require('../middleware/validate');

function register(req, res) {
  try {
    const { deviceId, judgeName, tabletLabel, ipAddress, appVersion } = req.body;

    if (!deviceId || typeof deviceId !== 'string' || deviceId.trim().length < 4) {
      return res.status(400).json({ success: false, error: 'Valid deviceId is required (min 4 chars)' });
    }

    const tablet = Tablet.register({
      deviceId: sanitizeString(deviceId, 100),
      judgeName: sanitizeString(judgeName, 200),
      tabletLabel: sanitizeString(tabletLabel, 200),
      ipAddress: sanitizeString(ipAddress, 50),
      appVersion: sanitizeString(appVersion, 50),
    });

    TabletLog.create(tablet.id, 'register', { deviceId, judgeName });

    return res.json({
      success: true,
      tablet: {
        id: tablet.id,
        deviceId: tablet.device_id,
        judgeName: tablet.judge_name,
        tabletLabel: tablet.tablet_label,
      },
    });
  } catch (err) {
    console.error('Register error:', err);
    return res.status(500).json({ success: false, error: 'Registration failed' });
  }
}

function heartbeat(req, res) {
  try {
    const {
      deviceId, judgeName, tabletLabel,
      batteryLevel, batteryTemperature, charging,
      ipAddress, appVersion, currentWebviewUrl,
    } = req.body;

    if (!deviceId || typeof deviceId !== 'string') {
      return res.status(400).json({ success: false, error: 'deviceId is required' });
    }

    const existing = Tablet.findByDeviceId(deviceId);
    if (!existing) {
      return res.status(404).json({ success: false, error: 'Tablet not registered. Call /api/tablets/register first.' });
    }

    const updated = Tablet.heartbeat({
      deviceId: sanitizeString(deviceId, 100),
      judgeName: judgeName != null ? sanitizeString(judgeName, 200) : null,
      tabletLabel: tabletLabel != null ? sanitizeString(tabletLabel, 200) : null,
      batteryLevel: typeof batteryLevel === 'number' ? Math.max(0, Math.min(100, batteryLevel)) : null,
      batteryTemperature: typeof batteryTemperature === 'number' ? batteryTemperature : null,
      charging: !!charging,
      ipAddress: ipAddress ? sanitizeString(ipAddress, 50) : null,
      appVersion: appVersion ? sanitizeString(appVersion, 50) : null,
      currentWebviewUrl: currentWebviewUrl ? sanitizeString(currentWebviewUrl, 1000) : null,
    });

    return res.json({ success: true, received: true });
  } catch (err) {
    console.error('Heartbeat error:', err);
    return res.status(500).json({ success: false, error: 'Heartbeat failed' });
  }
}

function getConfig(req, res) {
  try {
    const { deviceId } = req.params;
    if (!deviceId) {
      return res.status(400).json({ success: false, error: 'deviceId is required' });
    }

    const config = Tablet.getConfig(deviceId);
    if (!config) {
      return res.status(404).json({ success: false, error: 'Tablet not found' });
    }

    Tablet.clearForceReload(deviceId);

    return res.json({ success: true, config });
  } catch (err) {
    console.error('Get config error:', err);
    return res.status(500).json({ success: false, error: 'Failed to get config' });
  }
}

module.exports = { register, heartbeat, getConfig };
