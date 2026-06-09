import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:network_info_plus/network_info_plus.dart';

import 'telemetry_debug_log.dart';

/// Per-field result for DEBUG: value + why null.
class TelemField<T> {
  final T? value;
  final String support;
  final String detail;
  const TelemField(this.value, this.support, [this.detail = '']);
}

class DeviceInfoService {
  static const _channel = MethodChannel('com.example.tablet_app/device_info');
  final Battery _battery = Battery();
  final NetworkInfo _networkInfo = NetworkInfo();

  Future<TelemField<int?>> getBatteryLevelDebug() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return const TelemField(null, 'unsupported_platform', 'not Android/iOS');
    }
    try {
      final level = await _battery.batteryLevel;
      return TelemField(level, 'supported', 'battery_plus');
        } catch (e) {
      telemLog('[TELEM_DEVICE]', 'battery_plus failed', {'error': '$e'});
    }
    if (Platform.isAndroid) {
      try {
        final r = await _channel.invokeMethod<dynamic>('getBatteryLevel');
        if (r is num) {
          return TelemField(r.toInt().clamp(0, 100), 'supported', 'native');
        }
        return const TelemField(null, 'null_plugin', 'native non-num');
      } catch (e) {
        return TelemField(null, 'exception', '$e');
      }
    }
    return const TelemField(null, 'null_plugin', 'battery_plus returned null');
  }

  Future<int?> getBatteryLevel() async {
    final d = await getBatteryLevelDebug();
    return d.value;
  }

  Future<TelemField<bool>> getChargingDebug() async {
    try {
      final status = await _battery.batteryState;
      final c = status == BatteryState.charging || status == BatteryState.full;
      return TelemField(c, 'supported', 'battery_plus');
    } catch (e) {
      telemLog('[TELEM_DEVICE]', 'batteryState failed', {'error': '$e'});
    }
    if (Platform.isAndroid) {
      try {
        final r = await _channel.invokeMethod<dynamic>('getBatteryCharging');
        if (r is bool) return TelemField(r, 'supported', 'native');
      } catch (e) {
        return TelemField(false, 'exception', '$e');
      }
    }
    return const TelemField(false, 'fallback', 'assume not charging');
  }

  Future<bool> getCharging() async {
    final d = await getChargingDebug();
    return d.value ?? false;
  }

  Future<TelemField<double?>> getBatteryTemperatureDebug() async {
    if (!Platform.isAndroid) {
      return const TelemField(null, 'unsupported_platform', 'Android only');
    }
    try {
      final r = await _channel.invokeMethod<dynamic>('getBatteryTemperature');
      if (r is num) return TelemField(r.toDouble(), 'supported', 'native');
      return const TelemField(null, 'null_plugin', 'native null');
    } catch (e) {
      return TelemField(null, 'exception', '$e');
    }
  }

  Future<double?> getBatteryTemperature() async {
    final d = await getBatteryTemperatureDebug();
    return d.value;
  }

  Future<TelemField<int?>> getCpuUsageDebug() async {
    if (!Platform.isAndroid) {
      return const TelemField(null, 'unsupported_platform', 'Android only');
    }
    try {
      final r = await _channel.invokeMethod<dynamic>('getCpuUsage');
      if (r is Map) {
        final pct = r['pct'];
        final src = r['source']?.toString() ?? '';
        final reason = r['reason']?.toString() ?? '';
        // ignore: avoid_print
        print('[CPU_DEBUG] pct=$pct source=$src reason=$reason');
        if (pct is num) {
          return TelemField(pct.toInt().clamp(0, 100), 'supported', '$src|$reason');
        }
        return TelemField(null, 'failed', reason.isEmpty ? src : reason);
      }
      if (r is num) {
        return TelemField(r.toInt().clamp(0, 100), 'supported', 'legacy_double');
      }
      return const TelemField(null, 'null_plugin', 'unexpected_native_response');
    } catch (e) {
      // ignore: avoid_print
      print('[CPU_DEBUG] exception=$e');
      return TelemField(null, 'exception', '$e');
    }
  }

  Future<int?> getCpuUsage() async {
    final d = await getCpuUsageDebug();
    return d.value;
  }

  Future<TelemField<String?>> getConnectivityStateDebug() async {
    try {
      final result = await Connectivity().checkConnectivity();
      if (result.contains(ConnectivityResult.wifi)) {
        return const TelemField('wifi', 'supported', '');
      }
      if (result.contains(ConnectivityResult.mobile)) {
        return const TelemField('mobile', 'supported', '');
      }
      if (result.contains(ConnectivityResult.ethernet)) {
        return const TelemField('ethernet', 'supported', '');
      }
      return const TelemField('none', 'supported', '');
    } catch (e) {
      return TelemField(null, 'exception', '$e');
    }
  }

  Future<String?> getConnectivityState() async {
    final d = await getConnectivityStateDebug();
    return d.value;
  }

  Future<TelemField<String?>> getLocalIpDebug() async {
    try {
      final ip = await _networkInfo.getWifiIP();
      if (ip != null && ip.isNotEmpty && !ip.startsWith('127.')) {
        return TelemField(ip, 'supported', 'getWifiIP');
      }
    } catch (e) {
      telemLog('[TELEM_DEVICE]', 'getWifiIP', {'error': '$e', 'note': 'Android10+ often needs LOCATION for WiFi IP'});
    }
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (ip.isNotEmpty && !ip.startsWith('127.')) {
            return TelemField(ip, 'supported', 'NetworkInterface');
          }
        }
      }
    } catch (e) {
      return TelemField(null, 'exception', 'interfaces: $e');
    }
    return const TelemField(null, 'permission_likely', 'getWifiIP empty; grant Location or no WiFi');
  }

  Future<String?> getLocalIp() async {
    final d = await getLocalIpDebug();
    return d.value;
  }

  Future<TelemField<String?>> getWifiSSIDDebug() async {
    final info = await getWifiInfoDebug();
    return TelemField(info.ssid, info.support, info.detail);
  }

  /// One native call: returns SSID and RSSI (signal_strength in dBm) when on Android.
  Future<({String? ssid, int? rssi, String support, String detail})> getWifiInfoDebug() async {
    if (Platform.isAndroid) {
      try {
        final r = await _channel.invokeMethod<dynamic>('getWifiSsid');
        if (r is Map) {
          final ssid = r['ssid']?.toString();
          final reason = r['reason']?.toString() ?? '';
          int? rssi;
          final rssiVal = r['rssi'];
          if (rssiVal is int) {
            rssi = rssiVal;
          } else if (rssiVal is num) {
            rssi = rssiVal.toInt();
          }
          // ignore: avoid_print
          print('[WIFI_SSID_DEBUG] ssid=$ssid rssi=$rssi reason=$reason');
          if (ssid != null && ssid.isNotEmpty) {
            return (ssid: ssid, rssi: rssi, support: 'supported', detail: reason);
          }
          return (ssid: null, rssi: rssi, support: 'no_ssid', detail: reason);
        }
      } catch (e) {
        // ignore: avoid_print
        print('[WIFI_SSID_DEBUG] native_exception=$e');
      }
    }
    try {
      final name = await _networkInfo.getWifiName();
      if (name != null && name.isNotEmpty && name != 'null') {
        final clean = name.replaceAll('"', '');
        if (clean.isNotEmpty && clean != '<unknown ssid>') {
          return (ssid: clean, rssi: null, support: 'supported', detail: 'network_info_plus_fallback');
        }
      }
    } catch (e) {
      return (ssid: null, rssi: null, support: 'exception', detail: '$e');
    }
    return (ssid: null, rssi: null, support: 'permission_likely', detail: 'native+plugin_failed');
  }

  Future<String?> getWifiSSID() async {
    final d = await getWifiSSIDDebug();
    return d.value;
  }

  Future<int?> getWifiSignalStrength() async {
    final info = await getWifiInfoDebug();
    return info.rssi;
  }

  Future<String?> getWifiBSSID() async {
    try {
      return await _networkInfo.getWifiBSSID();
    } catch (_) {
      return null;
    }
  }

  Future<String?> getGateway() async => null;

  Future<int?> getWifiFrequency() async => null;
}
