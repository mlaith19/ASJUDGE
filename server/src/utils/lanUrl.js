/**
 * Resolve the address the tablets should load.
 *
 * The tablets used to be pointed at the public domain, so a show ran over the
 * internet even though every device was standing on the same LAN as the server.
 * The obvious fix - hardcode the server's IP - does not survive DHCP handing out
 * a different address next week.
 *
 * So the setting accepts the literal word "auto" (and an empty value behaves the
 * same): the address is resolved from the machine's own network interfaces every
 * time a tablet asks for its config, and therefore follows the server wherever
 * DHCP puts it. Anything else is used verbatim, so an explicit URL still works.
 */
const os = require('os');

/** Port the tablets load - Next.js, NOT this Express process (which runs on 5050). */
const TABLET_WEB_PORT = parseInt(process.env.TABLET_WEB_PORT || '3050', 10);

const PRIVATE_IPV4 = /^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/;

/**
 * Interfaces that look like a machine talking to itself. Picking one of these
 * hands the tablets an address only this PC can reach - the symptom is a white
 * screen on every tablet while the server looks perfectly healthy.
 * Windows names them "vEthernet (WSL)", "VirtualBox Host-Only Network" and so on.
 */
const VIRTUAL_IFACE = /(vethernet|wsl|hyper-?v|virtualbox|vmware|docker|loopback|npcap|tap-|tunnel|bluetooth|vpn)/i;

/**
 * The show server sits on a cable, never on WiFi - a wired link is the one that
 * stays up while an arena full of phones fights over the access point. So when
 * the machine has both, the cable wins.
 */
const WIRED_IFACE    = /(ethernet|^eth\d|^en[ospx]|\blan\b|gigabit|realtek|broadcom netxtreme)/i;
const WIRELESS_IFACE = /(wi-?fi|wlan|wireless|802\.11)/i;

function rankIface(name) {
  if (WIRED_IFACE.test(name) && !WIRELESS_IFACE.test(name)) return 0;
  if (WIRELESS_IFACE.test(name)) return 2;
  return 1; // unknown name - between the two, not ahead of a real cable
}

/**
 * Ranking, best first. A real LAN is almost always 192.168.x or 10.x; the
 * 172.16-31 block is technically private but in practice it is where WSL,
 * Docker and Hyper-V put their virtual switches, so it comes last.
 */
function rankIp(addr) {
  if (/^192\.168\./.test(addr)) return 0;
  if (/^10\./.test(addr)) return 1;
  return 2;
}

/** This machine's LAN address. null when nothing usable was found. */
function detectLanIp() {
  // An explicit override always wins - for the case where the guess is wrong
  // and there is no time to argue with it.
  const forced = (process.env.TABLET_LAN_IP || '').trim();
  if (forced) return forced;

  const ifaces = os.networkInterfaces();
  const candidates = [];
  for (const name of Object.keys(ifaces)) {
    for (const ni of ifaces[name] || []) {
      // Node <18 reports family as 'IPv4', newer builds as the number 4.
      const isV4 = ni.family === 'IPv4' || ni.family === 4;
      if (!isV4 || ni.internal) continue;
      if (!PRIVATE_IPV4.test(ni.address)) continue;
      candidates.push({
        name,
        address: ni.address,
        virtual: VIRTUAL_IFACE.test(name),
        link: rankIface(name) === 0 ? 'wired' : (rankIface(name) === 2 ? 'wifi' : 'other'),
      });
    }
  }
  if (candidates.length === 0) return null;

  candidates.sort((a, b) => {
    if (a.virtual !== b.virtual) return a.virtual ? 1 : -1;   // real card first
    const li = rankIface(a.name) - rankIface(b.name);          // cable before WiFi
    if (li !== 0) return li;
    return rankIp(a.address) - rankIp(b.address);              // then by range
  });

  // Worth a line in the log: when a tablet shows a white screen this is the
  // first thing anyone will want to see.
  console.log('[LAN] candidates=' + JSON.stringify(candidates) + ' chosen=' + candidates[0].address);
  return candidates[0].address;
}

function autoWebviewUrl() {
  const ip = detectLanIp();
  return ip ? `http://${ip}:${TABLET_WEB_PORT}/` : null;
}

/**
 * The host the tablet actually reached us on.
 *
 * detectLanIp() answers a question this machine has no information about: which
 * of its own network cards can the tablet see. It guesses well on a bare Windows
 * box and cannot possibly guess right inside a container, where the only card is
 * `eth0` on Docker's own 172.x bridge - a name that matches WIRED_IFACE and an
 * address the tablet can never reach. The tablet then loads nothing and shows a
 * white screen while the server looks healthy.
 *
 * But the tablet already reached us: it is asking this very question over a
 * connection it opened itself. The Host header of that request is, by definition,
 * an address that works from where the tablet is standing. No guessing needed.
 *
 * Only the hostname is kept - the port is always TABLET_WEB_PORT, because the
 * tablet asks the API (5050, or 3050 over the socket) but loads Next.js.
 *
 * Requests that did not come from a tablet - the scoring app proxying through
 * localhost - are rejected here and fall back to the interface guess.
 */
function hostFromRequest(rawHost) {
  const host = String(rawHost || '').trim();
  if (!host) return null;
  // Strip the port, and the brackets an IPv6 literal arrives in.
  const hostname = host.startsWith('[')
    ? host.slice(1, host.indexOf(']'))
    : host.split(':')[0];
  if (!hostname) return null;
  if (/^(localhost|127\.|0\.0\.0\.0$|::1$)/i.test(hostname)) return null;
  return hostname;
}

/** `http://<what the tablet dialled>:3050/`, or null when there is no usable host. */
function clientSeenWebviewUrl(rawHost) {
  const hostname = hostFromRequest(rawHost);
  return hostname ? `http://${hostname}:${TABLET_WEB_PORT}/` : null;
}

/** True for the values that mean "work it out yourself". */
function isAutoValue(configured) {
  const v = (configured == null ? '' : String(configured)).trim().toLowerCase();
  return v === '' || v === 'auto';
}

/**
 * @param {string} configured - global_webview_url or a tablet's custom_webview_url
 * @param {string} [clientSeenHost] - the Host header of the request the tablet made
 * @returns {string} the URL to hand the tablet ('' when auto and nothing was found)
 */
function resolveWebviewUrl(configured, clientSeenHost) {
  if (!isAutoValue(configured)) return String(configured).trim();
  // A fact from the tablet beats a guess about our own cards. The guess stays as
  // the fallback for callers with no request behind them.
  return clientSeenWebviewUrl(clientSeenHost) || autoWebviewUrl() || '';
}

/**
 * Where an Admin View tablet should land. It is not a judge: its job is the
 * tablets dashboard, not the judge login screen every other device gets.
 */
const ADMIN_VIEW_PATH = '/judge/app/dashboard';

function withPath(baseUrl, pathname) {
  if (!baseUrl) return '';
  try {
    return new URL(pathname, baseUrl).toString();
  } catch (_) {
    return baseUrl;
  }
}

module.exports = {
  detectLanIp,
  autoWebviewUrl,
  hostFromRequest,
  clientSeenWebviewUrl,
  isAutoValue,
  resolveWebviewUrl,
  withPath,
  ADMIN_VIEW_PATH,
  TABLET_WEB_PORT,
};
