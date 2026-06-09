import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/discovery_config.dart';

/// Discovers the judge backend on the LAN. No hardcoded IP: try saved URL first, then scan subnet.
/// Backend is valid only if GET /api/ping returns { "ok": true, "service": "judge-backend" }.
class BackendDiscoveryService {
  /// Subnet prefix from local IP, e.g. "192.168.1." from "192.168.1.88".
  static String? deriveSubnet(String localIp) {
    final parts = localIp.trim().split('.');
    if (parts.length != 4) return null;
    for (final p in parts) {
      final n = int.tryParse(p);
      if (n == null || n < 0 || n > 255) return null;
    }
    return '${parts[0]}.${parts[1]}.${parts[2]}.';
  }

  /// Preferred hosts only: x.x.x.1, .10, .50, ... (port 5000).
  static List<String> getPreferredCandidates(String subnet) {
    final base = subnet.endsWith('.') ? subnet : '$subnet.';
    final urls = <String>[];
    for (final port in kDiscoveryPorts) {
      for (final host in kPreferredHosts) {
        urls.add('http://$base$host:$port');
      }
    }
    return urls;
  }

  /// Preferred hosts + range .2–.254 (tries both ports).
  static List<String> getCandidatesWithRange(
    String subnet, {
    int rangeStart = kScanRangeStart,
    int rangeEnd = kScanRangeEnd,
  }) {
    final base = subnet.endsWith('.') ? subnet : '$subnet.';
    final set = <String>{};
    for (final port in kDiscoveryPorts) {
      for (final host in kPreferredHosts) {
        set.add('http://$base$host:$port');
      }
      for (var h = rangeStart; h <= rangeEnd; h++) {
        set.add('http://$base$h:$port');
      }
    }
    return set.toList();
  }

  /// Verifies backend via GET /api/ping. Response must be { "ok": true, "service": "judge-backend" }.
  Future<bool> verify(String baseUrl) async {
    final url = _normalizeBaseUrl(baseUrl);
    if (url == null || url.isEmpty) return false;
    final uri = Uri.parse('$url$kPingPath');
    for (var attempt = 0; attempt <= kProbeRetries; attempt++) {
      try {
        final r = await http.get(uri).timeout(kProbeTimeout);
        if (r.statusCode != 200) continue;
        final map = _parseJson(r.body);
        if (map == null) continue;
        final service = map['service'] as String?;
        final ok = map['ok'];
        if (service == kExpectedServiceName && ok == true) return true;
      } catch (_) {}
    }
    return false;
  }

  static Map<String, dynamic>? _parseJson(String body) {
    try {
      final decoded = jsonDecode(body.trim());
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v));
      }
    } catch (_) {}
    return null;
  }

  /// Scans [candidates] in parallel batches of [kMaxConcurrentProbes]. Stops as soon as one passes verify.
  Future<String?> _scanCandidatesConcurrent(
    List<String> candidates,
    Stopwatch stopwatch,
    Duration timeout,
  ) async {
    const concurrency = kMaxConcurrentProbes;
    for (var i = 0; i < candidates.length; i += concurrency) {
      if (stopwatch.elapsed >= timeout) return null;
      final batch = candidates.skip(i).take(concurrency).toList();
      final results = await Future.wait(
        batch.map((url) async => await verify(url) ? url : null),
      );
      for (final r in results) {
        if (r != null) return r;
      }
    }
    return null;
  }

  /// 1) Try preferred IPs in current subnet with concurrent probes; 2) if not found, try small range; 3) fallback subnets.
  Future<String?> discover(String? localIp) async {
    final stopwatch = Stopwatch()..start();
    const timeout = kDiscoveryTotalTimeout;

    if (localIp != null && localIp.trim().isNotEmpty) {
      final subnet = deriveSubnet(localIp);
      if (subnet != null) {
        // First: only common IPs (fast).
        var found = await _scanCandidatesConcurrent(
          getPreferredCandidates(subnet),
          stopwatch,
          timeout,
        );
        if (found != null) return _normalizeBaseUrl(found);

        // Then: extended range.
        found = await _scanCandidatesConcurrent(
          getCandidatesWithRange(subnet),
          stopwatch,
          timeout,
        );
        if (found != null) return _normalizeBaseUrl(found);
      }
    }

    final fallback = await _discoverWithFallbackSubnets(stopwatch, timeout);
    return fallback != null ? _normalizeBaseUrl(fallback) : null;
  }

  Future<String?> _discoverWithFallbackSubnets(
    Stopwatch stopwatch,
    Duration timeout,
  ) async {
    const fallbacks = ['192.168.1.', '192.168.10.', '192.168.0.', '10.0.0.'];
    for (final subnet in fallbacks) {
      if (stopwatch.elapsed >= timeout) return null;
      final found = await _scanCandidatesConcurrent(
        getPreferredCandidates(subnet),
        stopwatch,
        timeout,
      );
      if (found != null) return found;
      final foundRange = await _scanCandidatesConcurrent(
        getCandidatesWithRange(subnet),
        stopwatch,
        timeout,
      );
      if (foundRange != null) return foundRange;
    }
    return null;
  }

  String? _normalizeBaseUrl(String baseUrl) {
    final s = baseUrl.trim();
    if (s.isEmpty) return null;
    return s.endsWith('/') ? s.substring(0, s.length - 1) : s;
  }
}
