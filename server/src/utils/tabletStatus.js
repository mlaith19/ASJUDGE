/**
 * Reusable status class for tablet telemetry fields.
 * Returns: 'status-good' | 'status-warn' | 'status-bad' | 'status-neutral'
 *
 * Threshold mapping:
 * - battery: green >= 50%, orange 20-49%, red < 20%
 * - temperature: green <= 35°C, orange 35-42°C, red > 42°C
 * - latency: green <= 150ms, orange 151-400ms, red > 400ms
 * - wifi/connection: green = online + SSID + app_active; orange = online but no SSID or app_active false; red = offline
 * - app_active: green = true, red = false
 * - cpu: green 0-60%, orange 61-85%, red > 85%
 * - online: green = online, red = offline
 */

const THRESHOLDS = {
  battery: { good: 50, warn: 20 },
  temperature: { good: 35, warn: 42 },
  latency: { good: 150, warn: 400 },
  cpu: { good: 60, warn: 85 },
  wifiRssi: { good: -67, warn: -80 },
};

/**
 * WiFi signal (RSSI in dBm). Returns { bars: 1|2|3, statusClass } or null if no valid value.
 * green >= -67 (3 bars), orange -68 to -80 (2 bars), red < -80 (1 bar).
 */
function getWifiSignalInfo(rssi) {
  if (rssi === null || rssi === undefined || rssi === '') return null;
  const n = parseInt(String(rssi), 10);
  if (Number.isNaN(n)) return null;
  if (n >= THRESHOLDS.wifiRssi.good) return { bars: 3, statusClass: 'status-good' };
  if (n >= THRESHOLDS.wifiRssi.warn) return { bars: 2, statusClass: 'status-warn' };
  return { bars: 1, statusClass: 'status-bad' };
}

function getStatusClass(field, value, opts) {
  opts = opts || {};
  const online = opts.online === true;
  const hasValue = value !== null && value !== undefined && value !== '';

  switch (field) {
    case 'battery': {
      if (!online || !hasValue) return 'status-neutral';
      const n = parseInt(String(value), 10);
      if (Number.isNaN(n)) return 'status-neutral';
      if (n >= THRESHOLDS.battery.good) return 'status-good';
      if (n >= THRESHOLDS.battery.warn) return 'status-warn';
      return 'status-bad';
    }
    case 'temperature': {
      if (!online || !hasValue) return 'status-neutral';
      const n = parseFloat(String(value));
      if (Number.isNaN(n)) return 'status-neutral';
      if (n <= THRESHOLDS.temperature.good) return 'status-good';
      if (n <= THRESHOLDS.temperature.warn) return 'status-warn';
      return 'status-bad';
    }
    case 'latency': {
      if (!online || !hasValue) return 'status-neutral';
      const n = parseInt(String(value), 10);
      if (Number.isNaN(n)) return 'status-neutral';
      if (n <= THRESHOLDS.latency.good) return 'status-good';
      if (n <= THRESHOLDS.latency.warn) return 'status-warn';
      return 'status-bad';
    }
    case 'wifi':
    case 'connection': {
      if (!online) return 'status-bad';
      const ssid = opts.ssid != null && String(opts.ssid).trim() !== '';
      const appActive = opts.appActive !== false;
      if (ssid && appActive) return 'status-good';
      if (!ssid || !appActive) return 'status-warn';
      return 'status-neutral';
    }
    case 'app_active': {
      if (!online || value === null || value === undefined) return 'status-neutral';
      return value === true ? 'status-good' : 'status-bad';
    }
    case 'cpu': {
      if (!online || !hasValue) return 'status-neutral';
      const n = parseInt(String(value), 10);
      if (Number.isNaN(n)) return 'status-neutral';
      if (n <= THRESHOLDS.cpu.good) return 'status-good';
      if (n <= THRESHOLDS.cpu.warn) return 'status-warn';
      return 'status-bad';
    }
    case 'online': {
      return value === true ? 'status-good' : 'status-bad';
    }
    default:
      return 'status-neutral';
  }
}

module.exports = {
  getStatusClass,
  getWifiSignalInfo,
  THRESHOLDS,
};
