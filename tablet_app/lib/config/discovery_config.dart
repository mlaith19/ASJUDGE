/// Backend discovery: ping path and expected response signature.
/// Backend must respond to GET /api/ping with { "ok": true, "service": "judge-backend" }.
const String kPingPath = '/api/ping';
const String kExpectedServiceName = 'judge-backend';
/// Backend runs on port 5000 only.
const List<int> kDiscoveryPorts = [5000];
const int kDiscoveryPort = 5000;
const Duration kProbeTimeout = Duration(milliseconds: 800);
const int kProbeRetries = 1;

/// Max time for full LAN discovery before giving up.
const Duration kDiscoveryTotalTimeout = Duration(seconds: 60);

/// Max concurrent ping requests (scan more IPs in parallel).
const int kMaxConcurrentProbes = 24;

/// Common host octets to try first: router, PCs, typical servers (covers e.g. .56, .33, .77).
const List<int> kPreferredHosts = [
  1, 2, 3, 4, 5, 10, 33, 50, 52, 56, 77, 88, 100, 101, 102, 150, 200, 254,
];

/// Full subnet range so we find backend on any IP.
const int kScanRangeStart = 2;
const int kScanRangeEnd = 254;
