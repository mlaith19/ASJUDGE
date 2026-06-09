import 'device_info_service.dart';

/// Builds heartbeat telemetry map with keys always present (null when unavailable).
class HeartbeatTelemetry {
  HeartbeatTelemetry._();

  static Future<Map<String, dynamic>> build({
    required DeviceInfoService deviceInfo,
    String? currentWebviewUrl,
    String loginStatus = 'UNKNOWN',
    String? foregroundState,
    bool kioskModeActive = false,
    bool screenOn = false,
    String? connectivityState,
  }) async {
    final batt = await deviceInfo.getBatteryLevelDebug();
    final chg = await deviceInfo.getChargingDebug();
    final temp = await deviceInfo.getBatteryTemperatureDebug();
    final cpu = await deviceInfo.getCpuUsageDebug();
    final wifiInfo = await deviceInfo.getWifiInfoDebug();
    final ip = await deviceInfo.getLocalIpDebug();
    final conn = connectivityState ??
        (await deviceInfo.getConnectivityStateDebug()).value;

    final battV = batt.value;
    final chgV = chg.value ?? false;
    final tempV = temp.value;
    final cpuV = cpu.value;
    final wifiV = wifiInfo.ssid;
    final ipV = ip.value;
    final rssiV = wifiInfo.rssi;

    return {
      'battery_level': battV,
      'batteryLevel': battV,
      'charging': chgV,
      'temperature': tempV,
      'battery_temperature': tempV,
      'batteryTemperature': tempV,
      'cpu_usage': cpuV,
      'cpuUsage': cpuV,
      'wifi_ssid': wifiV,
      'wifiSSID': wifiV,
      'signal_strength': rssiV,
      'signalStrength': rssiV,
      'ip_address': ipV,
      'ipAddress': ipV,
      'current_webview_url': currentWebviewUrl,
      'currentWebviewUrl': currentWebviewUrl,
      'current_url': currentWebviewUrl,
      'login_status': loginStatus,
      'loginStatus': loginStatus,
      'foregroundState': foregroundState,
      'kioskModeActive': kioskModeActive,
      'screenOn': screenOn,
      'connectivityState': conn,
    };
  }
}
