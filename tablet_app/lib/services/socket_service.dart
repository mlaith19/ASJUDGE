import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import 'telemetry_debug_log.dart';

import '../models/tablet_config.dart';

/// WebSocket (Socket.IO) service for real-time communication with the backend.
/// Handles tablet registration, heartbeat, and commands. No polling.
class SocketService with WidgetsBindingObserver {
  SocketService({
    required this.baseUrl,
    required this.deviceId,
    required this.judgeLetter,
    required this.judgeName,
    required this.judgeColor,
    this.tabletLabel = '',
    this.appVersion = '1.0.0',
  });

  final String baseUrl;
  final String deviceId;
  final String judgeLetter;
  final String judgeName;
  final String judgeColor;
  final String tabletLabel;
  final String appVersion;

  io.Socket? _socket;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  static const int _heartbeatIntervalSeconds = 3;
  /// Short reconnect delays so that after disconnect we get register_ok (and any pending command) within a few seconds. WS-only, no polling.
  static const int _maxReconnectDelaySeconds = 3;

  /// Called when register_ok is received with initial config.
  void Function(TabletConfig? config)? onConfigReceived;

  /// Called on every register_ok **before** onConfigReceived — start telemetry timer here so it runs even if config parse fails.
  void Function()? onRegisterOkAlways;

  /// Called when a tablet_command is received. [payload] may be String or Map (e.g. force_judge_assignment: { judgeLetter, judgeName, judgeColor }).
  void Function(String action, dynamic payload)? onCommand;

  /// Called when connection state changes.
  void Function(bool connected)? onConnectionChanged;

  /// Called when register_error is received.
  void Function(String message)? onRegisterError;

  /// Every heartbeat: merge this map (battery, ip, …) before emit. Required for Setup + WebView.
  Future<Map<String, dynamic>> Function()? gatherTelemetryForEmit;

  bool _lifecycleObserverAdded = false;
  bool _appActive = true;
  bool _intentionalDisconnect = false;
  int? _lastLatencyMs;

  String get _wsUrl {
    String u = baseUrl.trim();
    if (u.endsWith('/')) u = u.substring(0, u.length - 1);
    return u;
  }

  bool get isConnected => _socket?.connected == true;

  void connect() {
    if (_socket?.connected == true) return;
    if (!_lifecycleObserverAdded) {
      try {
        WidgetsBinding.instance.addObserver(this);
        _lifecycleObserverAdded = true;
      } catch (_) {
        // If binding isn't ready yet, app_active will remain default=true.
      }
    }
    _socket?.dispose();
    try {
      final uri = _wsUrl.endsWith('/tablet') ? _wsUrl : '$_wsUrl/tablet';
      _socket = io.io(
        uri,
        io.OptionBuilder()
            .setTransports(['websocket'])
            .setPath('/socket.io')
            .enableForceNew()
            .build(),
      );
      _socket!.connect();

      _socket!.onConnect((_) {
        _reconnectAttempts = 0;
        _onConnect();
      });
      _socket!.onDisconnect((_) {
        onConnectionChanged?.call(false);
        if (!_intentionalDisconnect) _scheduleReconnect();
      });
      _socket!.onConnectError((e) {
        onConnectionChanged?.call(false);
        _scheduleReconnect();
      });
      _socket!.on('register_ok', _onRegisterOk);
      _socket!.on('register_error', _onRegisterError);
      _socket!.on('tablet_command', _onTabletCommand);
      _socket!.on('heartbeat_ack', _onHeartbeatAck);
    } catch (e) {
      _scheduleReconnect();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _appActive = true;
        _intentionalDisconnect = false;
        if (!isConnected) connect();
        break;
      case AppLifecycleState.inactive:
        _appActive = false;
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _appActive = false;
        _disconnectClean();
        break;
      case AppLifecycleState.hidden:
        _appActive = false;
        _disconnectClean();
        break;
    }
  }

  void _disconnectClean() {
    _intentionalDisconnect = true;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _reconnectTimer?.cancel();
    _socket?.disconnect();
  }

  void _onHeartbeatAck(dynamic data) {
    dynamic raw = data;
    if (data is List && data.isNotEmpty) raw = data.first;
    if (raw is! Map) return;
    int? sentAt;
    final v = raw['sent_at'] ?? raw['sentAt'];
    if (v is int) {
      sentAt = v;
    } else if (v != null) {
      sentAt = int.tryParse(v.toString());
    }
    if (sentAt == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final ms = now - sentAt;
    if (ms >= 0 && ms < 600000) {
      _lastLatencyMs = ms;
    }
  }

  void _onConnect() {
    onConnectionChanged?.call(true);
    _emitRegister();
    _startHeartbeat();
  }

  void _emitRegister() {
    _socket?.emit('tablet_register', {
      'type': 'tablet_register',
      'deviceId': deviceId,
      'judgeLetter': judgeLetter,
      'judgeName': judgeName,
      'judgeColor': judgeColor,
      'tabletLabel': tabletLabel,
      'appVersion': appVersion,
    });
  }

  void _onRegisterOk(dynamic data) {
    // [TELEM_A] Socket.IO may deliver List [map] or Map<dynamic,dynamic> — was breaking TabletConfig parse → no telemetry timer.
    dynamic raw = data;
    if (data is List && data.isNotEmpty) raw = data.first;
    Map<String, dynamic>? map;
    if (raw is Map) {
      try {
        map = Map<String, dynamic>.from(raw);
      } catch (_) {
        map = null;
      }
    }
    onRegisterOkAlways?.call();

    TabletConfig? config;
    if (map != null) {
      final cfg = map['config'];
      if (cfg is Map) {
        try {
          config = TabletConfig.fromJson(Map<String, dynamic>.from(cfg));
          final rawCfg = Map<String, dynamic>.from(cfg);
          // ignore: avoid_print
          print('[TABLET_RECEIVED_PAYLOAD]=$rawCfg');
          // ignore: avoid_print
          print('[TABLET_RECEIVED_TABLET_COLOR]=${config.tabletDisplayColor}');
        } catch (_) {
          config = null;
        }
      }
    }
    // [TELEM_A] tablet send — log next payload keys after updateHeartbeatPayload runs
    onConfigReceived?.call(config);
    _emitHeartbeatWithPayload();
  }

  void _onRegisterError(dynamic data) {
    String msg = 'Registration failed';
    if (data is Map<String, dynamic> && data['error'] != null) {
      msg = data['error'].toString();
    }
    onRegisterError?.call(msg);
  }

  void _onTabletCommand(dynamic data) {
    dynamic map = data;
    if (data is List && data.isNotEmpty) map = data.first;
    if (map is! Map<String, dynamic>) return;
    final action = (map['action'] as String?)?.trim().toLowerCase() ?? '';
    final payloadObj = map['payload'];
    final payload = payloadObj is String
        ? payloadObj
        : (payloadObj is Map<String, dynamic> ? payloadObj : (payloadObj?.toString()));
    if (action.isNotEmpty) onCommand?.call(action, payload);
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: _heartbeatIntervalSeconds),
      (_) => _emitHeartbeatWithPayload(),
    );
  }

  /// Call this to supply live data for heartbeat. Optional; can be called before each heartbeat.
  void updateHeartbeatPayload({
    int? batteryLevel,
    double? batteryTemperature,
    bool? charging,
    String? ipAddress,
    String? currentWebviewUrl,
    String? wifiSSID,
    String? wifiBSSID,
    String? gateway,
    int? signalStrength,
    int? wifiFrequency,
    int? cpuUsage,
    String? foregroundState,
    bool? kioskModeActive,
    bool? screenOn,
    String? connectivityState,
    String? loginStatus,
  }) {
    _lastHeartbeatPayload = {
      if (batteryLevel != null) 'batteryLevel': batteryLevel,
      if (batteryTemperature != null) 'batteryTemperature': batteryTemperature,
      if (charging != null) 'charging': charging,
      if (ipAddress != null) 'ipAddress': ipAddress,
      if (currentWebviewUrl != null) 'currentWebviewUrl': currentWebviewUrl,
      if (wifiSSID != null) 'wifiSSID': wifiSSID,
      if (wifiBSSID != null) 'wifiBSSID': wifiBSSID,
      if (gateway != null) 'gateway': gateway,
      if (signalStrength != null) 'signalStrength': signalStrength,
      if (wifiFrequency != null) 'wifiFrequency': wifiFrequency,
      if (cpuUsage != null) 'cpuUsage': cpuUsage,
      if (foregroundState != null) 'foregroundState': foregroundState,
      if (kioskModeActive != null) 'kioskModeActive': kioskModeActive,
      if (screenOn != null) 'screenOn': screenOn,
      if (connectivityState != null) 'connectivityState': connectivityState,
      if (loginStatus != null) 'loginStatus': loginStatus,
    };
  }

  Map<String, dynamic> _lastHeartbeatPayload = const {};

  /// Who is signed in on the scoring page right now, read from the WebView's own
  /// session. Kept as its own field rather than inside _lastHeartbeatPayload,
  /// because that map is REPLACED on every updateHeartbeatPayload call and this
  /// value has to survive between them - it changes only at sign-in/out.
  String _signedInLetter = '';
  String _signedInName = '';

  /// Pass empty strings on sign-out.
  void setSignedInJudge(String letter, String name) {
    _signedInLetter = letter.trim();
    _signedInName = name.trim();
  }

  /// For DEBUG: keys that will be merged into next emit.
  List<String> debugLastPayloadKeys() => _lastHeartbeatPayload.keys.toList();

  void _emitHeartbeatWithPayload() {
    unawaited(_emitHeartbeatWithPayloadAsync());
  }

  Future<void> _emitHeartbeatWithPayloadAsync() async {
    if (_socket?.connected != true) return;
    final sentAt = DateTime.now().millisecondsSinceEpoch;
    Map<String, dynamic> telem = {};
    if (gatherTelemetryForEmit != null) {
      try {
        telem = await gatherTelemetryForEmit!();
      } catch (e) {
        telem = {
          'telemetry_gather_error': '$e',
          'battery_level': null,
          'batteryLevel': null,
          'charging': false,
          'temperature': null,
          'battery_temperature': null,
          'cpu_usage': null,
          'wifi_ssid': null,
          'ip_address': null,
          'current_webview_url': null,
          'current_url': null,
        };
      }
    }
    final merged = <String, dynamic>{..._lastHeartbeatPayload, ...telem};
    final payload = <String, dynamic>{
      'type': 'heartbeat',
      'deviceId': deviceId,
      'judgeLetter': judgeLetter,
      'judgeName': judgeName,
      'judgeColor': judgeColor,
      'tabletLabel': tabletLabel,
      'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'sent_at': sentAt,
      if (_lastLatencyMs != null) 'latency_ms': _lastLatencyMs,
      'app_active': _appActive,
      // The judge actually signed in on the page - the tablet has no identity
      // of its own any more, so this is what names a dashboard column.
      'signedInJudgeLetter': _signedInLetter,
      'signedInJudgeName': _signedInName,
      ...merged,
    };
    try {
      // ignore: avoid_print
      print('FINAL_HEARTBEAT_PAYLOAD=${jsonEncode(payload)}');
    } catch (_) {
      // ignore: avoid_print
      print('FINAL_HEARTBEAT_PAYLOAD=$payload');
    }
    if (kTelemetryDebug) {
      try {
        final forLog = Map<String, dynamic>.from(payload);
        if (forLog['current_webview_url'] != null &&
            forLog['current_webview_url'].toString().length > 120) {
          forLog['current_webview_url'] =
              '${forLog['current_webview_url'].toString().substring(0, 120)}…';
        }
        // ignore: avoid_print
        print('[TELEM_B_emit] event=heartbeat json=${jsonEncode(forLog)}');
      } catch (e) {
        // ignore: avoid_print
        print('[TELEM_B_emit] event=heartbeat keys=${payload.keys.toList()} encode_err=$e');
      }
    }
    _socket!.emit('heartbeat', payload);
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectAttempts++;
    final delay = _reconnectDelaySeconds();
    _reconnectTimer = Timer(Duration(seconds: delay), () {
      connect();
    });
  }

  int _reconnectDelaySeconds() {
    if (_reconnectAttempts <= 0) return 1;
    // Retry quickly: 1s, then 2s, then 2s… so we reconnect within a few seconds and get pending commands via register_ok (WS only).
    return _reconnectAttempts == 1 ? 1 : 2;
  }

  void sendCommandCompleted(String action, {bool success = true}) {
    _socket?.emit('command_completed', {
      'type': 'command_completed',
      'deviceId': deviceId,
      'action': action,
      'success': success,
      'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });
  }

  /// Notify server that login status changed so admin dashboard updates immediately (no polling).
  void sendLoginStatusChanged(String loginStatus) {
    if (_socket?.connected != true) return;
    _socket!.emit('login_status_changed', {
      'type': 'login_status_changed',
      'deviceId': deviceId,
      'loginStatus': loginStatus,
      'signedInJudgeLetter': _signedInLetter,
      'signedInJudgeName': _signedInName,
      'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });
  }

  void dispose() {
    _intentionalDisconnect = true;
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    _socket?.dispose();
    _socket = null;
    if (_lifecycleObserverAdded) {
      try {
        WidgetsBinding.instance.removeObserver(this);
      } catch (_) {}
      _lifecycleObserverAdded = false;
    }
  }
}
