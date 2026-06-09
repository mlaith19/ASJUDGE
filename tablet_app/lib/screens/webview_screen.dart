import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vibration/vibration.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../config/judge_colors.dart';
import '../models/tablet_config.dart';
import '../services/storage_service.dart';
import '../services/api_service.dart';
import '../services/device_info_service.dart';
import '../services/kiosk_service.dart';
import '../services/heartbeat_telemetry.dart';
import '../services/socket_service.dart';
import '../services/telemetry_debug_log.dart';
import '../utils/url_validator.dart';
import 'setup_screen.dart';

class _UrlNorm {
  final String origin;
  final String pathWithSlash;
  _UrlNorm({required this.origin, required this.pathWithSlash});
}

class WebViewScreen extends StatefulWidget {
  const WebViewScreen({
    super.key,
    required this.storage,
    required this.api,
    required this.deviceId,
  });

  final StorageService storage;
  final ApiService api;
  final String deviceId;

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen>
    with WidgetsBindingObserver {
  final DeviceInfoService _deviceInfo = DeviceInfoService();
  final KioskService _kioskService = KioskService();
  WebViewController? _controller;
  String? _currentTargetUrl;
  bool _loading = true;
  String? _error;
  bool _backendUnavailable = false;
  SocketService? _socketService;
  Timer? _heartbeatPayloadTimer;
  bool _kioskEnabled = true;
  bool _keepScreenOn = true;
  String _foregroundState = 'foreground';
  int _adminTapCount = 0;
  Timer? _adminTapTimer;
  int _colorTapCount = 0;
  Timer? _colorTapTimer;
  Timer? _repinTimer;
  bool _navigatingToSetup = false;
  String _judgeUsername = '';
  String _judgePassword = '';
  String _lastLoginStatus = 'UNKNOWN';
  bool _autoLoginAttemptedOnCurrentPage = false;
  int _autoLoginAttemptsForCurrentPage = 0;
  /// When false, tablet must NOT auto-login (e.g. after admin forced logout).
  bool _autoLoginAllowed = true;
  /// When we started loading the target URL; used to avoid acting before navigation settles (e.g. after Assign).
  DateTime? _targetUrlLoadStartedAt;
  /// Location permission: null/false = show banner and dialog until granted.
  bool? _locationPermissionGranted = false;
  /// So we show the permission dialog only once per session.
  bool _permissionDialogShown = false;
  bool _adminAlertsEnabled = true;

  static const String _logTag = 'WebView';
  static const Duration _postAssignWaitBeforeConnect = Duration(milliseconds: 2500);
  static const Duration _urlSettleGracePeriod = Duration(seconds: 4);
  static const Duration _delayedAutoLoginAfterLoad = Duration(seconds: 2);
  void _log(String msg) => debugPrint('[$_logTag] $msg');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _applyFullscreen();
    _loadConfigAndWebView();
    // On Android: check permission after build; show dialog if not granted (user tap = system shows permission dialog)
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final alreadyPinned = await _kioskService.isLockTaskMode();
      if (!alreadyPinned) _kioskService.startLockTask();
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      if (!Platform.isAndroid) return;
      await _checkLocationPermission();
      if (!mounted) return;
      if (_locationPermissionGranted != true && !_permissionDialogShown) {
        _permissionDialogShown = true;
        _showPermissionDialog();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _heartbeatPayloadTimer?.cancel();
    _socketService?.dispose();
    _adminTapTimer?.cancel();
    _colorTapTimer?.cancel();
    _repinTimer?.cancel();
    _kioskService.setKeepScreenOn(false);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _foregroundState = 'foreground';
        if (_kioskEnabled) _applyFullscreen();
        _checkLocationPermission();
        break;
      case AppLifecycleState.inactive:
        _foregroundState = 'inactive';
        break;
      case AppLifecycleState.paused:
        _foregroundState = 'background';
        break;
      case AppLifecycleState.detached:
        _foregroundState = 'detached';
        break;
      case AppLifecycleState.hidden:
        _foregroundState = 'hidden';
        break;
    }
  }

  void _applyFullscreen() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  Future<void> _checkLocationPermission() async {
    if (!Platform.isAndroid) {
      if (mounted) setState(() => _locationPermissionGranted = true);
      return;
    }
    try {
      final status = await Permission.locationWhenInUse.status;
      if (mounted) setState(() => _locationPermissionGranted = status.isGranted);
    } catch (_) {
      if (mounted) setState(() => _locationPermissionGranted = false);
    }
  }

  /// Request permission (shows system dialog). Call from user action for best results.
  /// Handles denial gracefully; app continues without crashing.
  Future<void> _requestLocationPermission() async {
    if (!Platform.isAndroid) return;
    try {
      final status = await Permission.locationWhenInUse.request();
      if (mounted) {
        setState(() => _locationPermissionGranted = status.isGranted);
        if (!status.isGranted && status.isPermanentlyDenied == false) {
          _showPermissionDeniedExplanation();
        }
      }
    } catch (_) {
      if (mounted) setState(() => _locationPermissionGranted = false);
    }
  }

  void _showPermissionDeniedExplanation() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text(
          'Location was denied. The app still works, but the server will not receive WiFi network name. '
          'Battery and other data are still sent. You can enable Location later in Settings.',
        ),
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
          label: 'Settings',
          onPressed: () => _openAppSettings(),
        ),
      ),
    );
  }

  /// Open app settings so user can enable Location manually. Safe to call; never throws.
  Future<void> _openAppSettings() async {
    try {
      await openAppSettings();
      await Future.delayed(const Duration(milliseconds: 500));
      _checkLocationPermission();
    } catch (_) {}
  }

  void _showPermissionDialog() {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Permission required'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'This monitoring app sends device status to the server: battery level, network connectivity, '
                'WiFi network name (SSID), and device info. On Android 10 and above, reading the WiFi name '
                'requires Location permission (we do not track your position).',
              ),
              const SizedBox(height: 12),
              Text(
                'Tap "Grant permission" to allow. If the system does not show a prompt, use "Open Settings" '
                'and enable Location for this app.',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Text(
                'If you deny: the app will still work and will send battery and other data. Only the WiFi '
                'network name will be missing on the server. You can enable Location later in app Settings.',
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                      fontStyle: FontStyle.italic,
                    ),
              ),
              const SizedBox(height: 12),
              Text(
                'Tip: If you see "Restrict app when not in use", turn it OFF for this app so permissions stay active.',
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                      color: Theme.of(ctx).colorScheme.primary,
                    ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Later'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              await _requestLocationPermission();
            },
            child: const Text('Grant permission'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              await _openAppSettings();
            },
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  static const String _kAdminJudgeLetter = '__ADMIN__';
  bool get _isAdminMode => (widget.storage.judgeLetter ?? '').trim() == _kAdminJudgeLetter;

  Future<void> _loadConfigAndWebView() async {
    final judgeLetter = (widget.storage.judgeLetter ?? '').trim();
    if (judgeLetter == _kAdminJudgeLetter) {
      _loadAdminView();
      return;
    }
    if (judgeLetter.isEmpty) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'No judge selected. Complete setup first.';
          _backendUnavailable = true;
        });
      }
      return;
    }
    final storedUrl = (widget.storage.lastKnownTargetUrl ?? '').trim();
    final hasStoredTargetUrl = storedUrl.isNotEmpty && isValidHttpUrl(storedUrl);
    if (!hasStoredTargetUrl) {
      _log('No stored target URL (e.g. after Assign); waiting ${_postAssignWaitBeforeConnect.inMilliseconds}ms before connect');
      await Future.delayed(_postAssignWaitBeforeConnect);
      if (!mounted) return;
    }
    _initSocket();
    _socketService!.connect();
  }

  void _loadAdminView() {
    final base = widget.api.baseUrl;
    final adminUrl = '${base.endsWith('/') ? base : '$base/'}admin';
    _log('Admin mode: loading $adminUrl');
    setState(() {
      _kioskEnabled = false;
      _keepScreenOn = false;
    });
    _kioskService.setKioskEnabled(false);
    _kioskService.setKeepScreenOn(false);
    _loadUrl(adminUrl);
    _initAdminSocket();
  }

  /// Connect socket for admin tablet so it can receive admin_alert commands (vibrate + sound).
  void _initAdminSocket() {
    _socketService?.dispose();
    _socketService = SocketService(
      baseUrl: widget.api.baseUrl,
      deviceId: widget.deviceId,
      judgeLetter: _kAdminJudgeLetter,
      judgeName: 'Admin View',
      judgeColor: '',
      tabletLabel: widget.storage.tabletLabel ?? '',
      appVersion: '1.0.0',
    );
    _socketService!.onConfigReceived = (config) {
      if (config == null || !mounted) return;
      setState(() => _adminAlertsEnabled = config.adminTabletAlertsEnabled);
    };
    _socketService!.onCommand = _onAdminCommand;
    _socketService!.connect();
  }

  void _onAdminCommand(String action, dynamic payload) {
    _log('admin_command received: action=$action enabled=$_adminAlertsEnabled payload=$payload');
    if (action != 'admin_alert') return;

    // Always show visual notification so we can confirm the command arrived.
    if (mounted) {
      String label = 'Alert';
      if (payload is Map) {
        final eventType = (payload['eventType'] ?? '').toString();
        final judge = (payload['judgeLetter'] ?? '').toString();
        final batt = (payload['batteryLevel'] ?? '').toString();
        switch (eventType) {
          case 'judge_online':    label = 'Judge $judge connected'; break;
          case 'judge_offline':   label = 'Judge $judge disconnected'; break;
          case 'judge_assigned':  label = 'Judge $judge assigned'; break;
          case 'judge_unassigned':label = 'Judge $judge unassigned'; break;
          case 'judge_login':     label = 'Judge $judge logged in'; break;
          case 'judge_logout':    label = 'Judge $judge logged out'; break;
          case 'low_battery':     label = 'Judge $judge battery $batt%'; break;
          default: label = eventType.isNotEmpty ? eventType : 'Admin alert';
        }
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(children: [
            const Icon(Icons.notifications_active, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Text(label, style: const TextStyle(color: Colors.white)),
          ]),
          backgroundColor: Colors.indigo.shade700,
          duration: const Duration(seconds: 4),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }

    if (_adminAlertsEnabled) {
      _triggerAdminAlert();
    }
  }

  Future<void> _triggerAdminAlert() async {
    try {
      final bool hasVibrator = await Vibration.hasVibrator();
      if (hasVibrator == true) {
        Vibration.vibrate(pattern: [0, 300, 100, 200, 100, 400]);
      } else {
        HapticFeedback.heavyImpact();
      }
    } catch (_) {
      try { HapticFeedback.heavyImpact(); } catch (_) {}
    }
    try {
      await FlutterRingtonePlayer().playNotification();
    } catch (e) {
      _log('admin alert sound error: $e');
    }
  }

  void _initSocket() {
    _socketService?.dispose();
    _heartbeatPayloadTimer?.cancel();
    _socketService = SocketService(
      baseUrl: widget.api.baseUrl,
      deviceId: widget.deviceId,
      judgeLetter: (widget.storage.judgeLetter ?? '').trim(),
      judgeName: widget.storage.judgeName ?? '',
      judgeColor: '',
      tabletLabel: widget.storage.tabletLabel ?? '',
      appVersion: '1.0.0',
    );
    _socketService!.onRegisterOkAlways = () {
      _heartbeatPayloadTimer?.cancel();
      _heartbeatPayloadTimer = Timer.periodic(const Duration(seconds: 3), (_) => _updateHeartbeatPayload());
      _updateHeartbeatPayload();
      _requestLocationForHeartbeatIfNeeded();
    };
    _socketService!.gatherTelemetryForEmit = () async {
      final di = _deviceInfo;
      String? currentUrl;
      if (_controller != null) {
        try {
          currentUrl = await _controller!.currentUrl();
        } catch (_) {}
      }
      var loginStatus = 'UNKNOWN';
      final targetUrl = _currentTargetUrl;
      if (mounted) {
        loginStatus = _computeLoginStatusFromUrls(currentUrl, targetUrl);
        if (loginStatus == 'LOGGED_OUT' &&
            (currentUrl == null ||
                currentUrl.trim().isEmpty ||
                (targetUrl == null || targetUrl.trim().isEmpty))) {
          final domStatus = await _detectLoginStatus();
          if (domStatus == 'LOGGED_IN' || domStatus == 'LOGGED_OUT') {
            loginStatus = domStatus;
          }
        }
      }
      return HeartbeatTelemetry.build(
        deviceInfo: di,
        currentWebviewUrl: currentUrl,
        loginStatus: loginStatus,
        foregroundState: mounted ? _foregroundState : null,
        kioskModeActive: mounted && _kioskEnabled,
        screenOn: mounted && _keepScreenOn,
        connectivityState: await di.getConnectivityState(),
      );
    };
    _socketService!.onConfigReceived = _onSocketConfig;
    _socketService!.onCommand = _onSocketCommand;
    _socketService!.onConnectionChanged = (connected) {
      if (mounted) setState(() => _backendUnavailable = !connected);
    };
    _socketService!.onRegisterError = (message) async {
      if (!mounted) return;
      final isJudgeNotFound = message.toLowerCase().contains('not found') ||
          message.toLowerCase().contains('judge letter') ||
          message.toLowerCase().contains('invalid');
      if (isJudgeNotFound) {
        await widget.storage.clearJudgeSelection();
        await widget.storage.setJudgeSelectionInvalidated(true);
        if (!mounted) return;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(
              builder: (_) => SetupScreen(
                storage: widget.storage,
                api: widget.api,
                deviceId: widget.deviceId,
                returnToWebView: false,
              ),
            ),
            (_) => false,
          );
        });
      } else {
        setState(() {
          _error = message;
          _loading = false;
          _backendUnavailable = true;
        });
      }
    };
  }

  /// Request location permission in background when we start sending heartbeats, so WiFi/IP appear on server.
  void _requestLocationForHeartbeatIfNeeded() {
    if (!Platform.isAndroid || _locationPermissionGranted == true) return;
    Permission.locationWhenInUse.request().then((status) {
      if (!mounted) return;
      if (status.isGranted) {
        setState(() => _locationPermissionGranted = true);
        _updateHeartbeatPayload(); // refresh so next heartbeat includes WiFi/IP
      }
    });
  }

  void _onSocketConfig(TabletConfig? config) {
    if (!mounted || config == null) return;
    // Tablet color source is tabletDisplayColor only; judgeColor must not drive badge color.
    final tabletDisplayColor = (config.tabletDisplayColor ?? '').trim().toLowerCase();
    final colorToStore = tabletDisplayColor;
    debugPrint('[TABLET_RECEIVED_TABLET_COLOR]=$tabletDisplayColor');
    if (colorToStore.isNotEmpty && colorToStore != (widget.storage.tabletColor ?? '').trim().toLowerCase()) {
      widget.storage.setTabletColor(colorToStore);
      debugPrint('[STORAGE_TABLET_COLOR_SAVED]=$colorToStore');
    }
    setState(() {
      _backendUnavailable = false;
      _error = null;
      _kioskEnabled = config.kioskModeEnabled;
      _keepScreenOn = config.keepScreenOn;
    });
    _kioskService.setKioskEnabled(_kioskEnabled);
    if (_keepScreenOn) {
      _kioskService.setKeepScreenOn(true);
    }
    _kioskService.enableImmersiveMode();
    // If server sent pending "Edit Judge Setup" (e.g. after reconnect), open setup immediately so user doesn't have to touch the tablet.
    final pending = (config.pendingAction ?? '').trim().toLowerCase();
    if (pending == 'edit_judge_setup' || pending == 'reset_setup') {
      // Prevent reassignment oscillation: before opening Setup, sync judgeLetter from server config (DB source of truth).
      final serverJudgeLetter = config.judgeLetter.trim().toUpperCase();
      if (serverJudgeLetter.isNotEmpty && serverJudgeLetter != (widget.storage.judgeLetter ?? '').trim().toUpperCase()) {
        widget.storage.setJudgeLetter(serverJudgeLetter);
        _log('sync storage judgeLetter from config: $serverJudgeLetter');
      }
      _navigatingToSetup = true;
      // IMPORTANT: send command_completed and only then dispose socket.
      // If we dispose immediately, the event may be dropped and server will keep re-sending the pendingAction.
      final s = _socketService;
      s?.sendCommandCompleted(pending);
      // Prevent stale judge assignment while Setup is open.
      _heartbeatPayloadTimer?.cancel();
      _heartbeatPayloadTimer = null;
      _socketService = null;
      Future.delayed(const Duration(milliseconds: 200), () {
        s?.dispose();
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _navigatingToSetup = false;
        if (!mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => SetupScreen(
              storage: widget.storage,
              api: widget.api,
              deviceId: widget.deviceId,
              returnToWebView: true,
            ),
          ),
        ).then((_) {
          if (!mounted) return;
          // User may have changed judge assignment in Setup.
          // Recreate socket/register using fresh storage values.
          _log('returned from setup -> reinit socket with latest judge assignment');
          _loadConfigAndWebView();
        });
      });
      return;
    }
    final url = config.targetWebviewUrl.trim();
    if (url.isEmpty || !isValidHttpUrl(url)) {
      setState(() {
        _loading = false;
        _error = 'No valid URL from server. Set default URL in admin settings.';
        _currentTargetUrl = null;
      });
      return;
    }
    final sameUrlAlreadyLoaded = _currentTargetUrl != null &&
        _currentTargetUrl!.trim() == url &&
        _controller != null;
    if (sameUrlAlreadyLoaded) {
      _log('config received again (e.g. reconnect); same URL already loaded, skip reload');
      setState(() {
        _judgeUsername = config.judgeUsername;
        _judgePassword = config.judgePassword;
      });
      _heartbeatPayloadTimer?.cancel();
      _heartbeatPayloadTimer = Timer.periodic(const Duration(seconds: 3), (_) => _updateHeartbeatPayload());
      _updateHeartbeatPayload();
      _requestLocationForHeartbeatIfNeeded();
      return;
    }
    setState(() {
      _judgeUsername = config.judgeUsername;
      _judgePassword = config.judgePassword;
    });
    _heartbeatPayloadTimer?.cancel();
    _heartbeatPayloadTimer = Timer.periodic(const Duration(seconds: 3), (_) => _updateHeartbeatPayload());
    _updateHeartbeatPayload();
    _requestLocationForHeartbeatIfNeeded();
    _loadUrl(url, forceReload: config.forceReload);
  }

  Future<void> _updateHeartbeatPayload() async {
    // ignore: avoid_print
    print('TELEM_MARKER _updateHeartbeatPayload reached');
    final s = _socketService;
    if (s == null || !s.isConnected) {
      // ignore: avoid_print
      print('TELEM_MARKER _updateHeartbeatPayload SKIP socket=${s == null} connected=${s?.isConnected}');
      if (kTelemetryDebug) {
        developer.log('SKIP not connected socket=${s == null}', name: '[TELEM_A_hb_start]');
      }
      return;
    }
    if (kTelemetryDebug) developer.log('START', name: '[TELEM_A_hb]');

    final battD = await _deviceInfo.getBatteryLevelDebug();
    final tempD = await _deviceInfo.getBatteryTemperatureDebug();
    final chgD = await _deviceInfo.getChargingDebug();
    final cpuD = await _deviceInfo.getCpuUsageDebug();
    final wifiD = await _deviceInfo.getWifiSSIDDebug();
    final ipD = await _deviceInfo.getLocalIpDebug();

    final batteryLevel = battD.value;
    final batteryTemp = tempD.value;
    final charging = chgD.value ?? false;
    final cpuUsage = cpuD.value;
    final wifiSSID = wifiD.value;
    final ip = ipD.value;
    final wifiBSSID = await _deviceInfo.getWifiBSSID();
    final gateway = await _deviceInfo.getGateway();
    final signalStrength = await _deviceInfo.getWifiSignalStrength();
    final wifiFrequency = await _deviceInfo.getWifiFrequency();

    String? currentUrl;
    String currentUrlSupport = 'no_controller';
    if (_controller != null) {
      try {
        currentUrl = await _controller!.currentUrl();
        currentUrlSupport =
            currentUrl == null || currentUrl.isEmpty ? 'empty' : 'supported';
      } catch (e) {
        currentUrlSupport = 'exception: $e';
      }
    }

    if (kTelemetryDebug) {
      developer.log(
        'battery=${battD.value} [${battD.support}] ${battD.detail} | '
        'charging=${chgD.value} [${chgD.support}] | '
        'temp=${tempD.value} [${tempD.support}] ${tempD.detail} | '
        'cpu=${cpuD.value} [${cpuD.support}] ${cpuD.detail} | '
        'wifi_ssid=${wifiD.value} [${wifiD.support}] ${wifiD.detail} | '
        'ip=${ipD.value} [${ipD.support}] ${ipD.detail} | '
        'current_url=${currentUrl != null && currentUrl.length > 80 ? "${currentUrl.substring(0, 80)}..." : currentUrl} [$currentUrlSupport]',
        name: '[TELEM_A_hb_values]',
      );
    }

    final targetUrl = _currentTargetUrl;
    String loginStatus = _computeLoginStatusFromUrls(currentUrl, targetUrl);
    // Always verify with DOM for accuracy — handles hash-routing SPAs where URL path is always '/'
    // and any SPA navigation that _onUrlChange might have mis-detected.
    if (currentUrl != null && currentUrl.trim().isNotEmpty) {
      try {
        final domStatus = await _detectLoginStatus();
        if (domStatus == 'LOGGED_IN' || domStatus == 'LOGGED_OUT') loginStatus = domStatus;
      } catch (_) {}
    } else if (loginStatus == 'LOGGED_OUT') {
      final domStatus = await _detectLoginStatus();
      if (domStatus == 'LOGGED_IN' || domStatus == 'LOGGED_OUT') loginStatus = domStatus;
    }
    // Heartbeat-based fallback: notify server immediately if status changed (catches SPA logouts
    // that _onUrlChange might miss).
    if ((loginStatus == 'LOGGED_IN' || loginStatus == 'LOGGED_OUT') &&
        loginStatus != _lastLoginStatus) {
      if (mounted) setState(() => _lastLoginStatus = loginStatus);
      s.sendLoginStatusChanged(loginStatus);
    }
    s.updateHeartbeatPayload(
      batteryLevel: batteryLevel,
      batteryTemperature: batteryTemp,
      charging: charging,
      ipAddress: ip,
      currentWebviewUrl: currentUrl,
      wifiSSID: wifiSSID,
      wifiBSSID: wifiBSSID,
      gateway: gateway,
      signalStrength: signalStrength,
      wifiFrequency: wifiFrequency,
      cpuUsage: cpuUsage,
      foregroundState: _foregroundState,
      kioskModeActive: _kioskEnabled,
      screenOn: _keepScreenOn,
      connectivityState: await _deviceInfo.getConnectivityState(),
      loginStatus: loginStatus,
    );
    if (kTelemetryDebug) {
      final keys = s.debugLastPayloadKeys();
      developer.log('END payload_keys=$keys', name: '[TELEM_A_hb]');
    }
  }

  void _onSocketCommand(String action, dynamic payload) {
    if (action == 'force_judge_assignment') {
      _log('force_judge_assignment (judge assignment) received');
      String? letter;
      String name = '';
      if (payload is Map<String, dynamic>) {
        letter = (payload['judgeLetter'] ?? payload['judge_letter'])?.toString().trim().toUpperCase();
        name = (payload['judgeName'] ?? payload['judge_name'])?.toString().trim() ?? '';
      }
      if (letter == null || letter.isEmpty) return;
      _socketService?.sendCommandCompleted(action);
      _socketService?.dispose();
      _socketService = null;
      widget.storage.saveSetup(
        judgeLetter: letter,
        judgeName: name,
        // Keep tablet-owned color; assignment changes only the letter/name.
        judgeColor: '',
        tabletLabel: widget.storage.tabletLabel ?? '',
      ).then((_) {
        if (!mounted) return;
        _log('judge assignment applied: $letter');
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => WebViewScreen(
              storage: widget.storage,
              api: widget.api,
              deviceId: widget.deviceId,
            ),
          ),
        );
      });
      return;
    }
    if (action == 'login_webview') {
      _log('login_webview received; setting autoLoginAllowed=true');
      _autoLoginAllowed = true;
      _runLoginWebView().then((_) {
        if (mounted) {
          _socketService?.sendCommandCompleted(action);
          _log('command_completed sent (login_webview)');
        }
      });
      return;
    }
    if (action == 'logout_webview') {
      _log('logout_webview received; setting autoLoginAllowed=false');
      _autoLoginAllowed = false;
    }
    if (action == 'set_auto_login_enabled') {
      final p = payload?.toString().toLowerCase();
      final enabled = p == 'true' || p == '1';
      _autoLoginAllowed = enabled;
      _log('set_auto_login_enabled: $enabled');
    }
    if (action == 'edit_judge_setup' || action == 'reset_setup') {
      _socketService?.sendCommandCompleted(action);
      if (_navigatingToSetup || !mounted) return;
      _navigatingToSetup = true;
      // Critical for reassignment: stop old socket so it cannot keep sending stale judgeLetter.
      _heartbeatPayloadTimer?.cancel();
      _heartbeatPayloadTimer = null;
      _socketService?.dispose();
      _socketService = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _navigatingToSetup = false;
        if (!mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => SetupScreen(
              storage: widget.storage,
              api: widget.api,
              deviceId: widget.deviceId,
              returnToWebView: true,
            ),
          ),
        ).then((_) {
          if (!mounted) return;
          _log('returned from setup command -> reinit socket with latest judge assignment');
          _loadConfigAndWebView();
        });
      });
      return;
    }
    final targetUrl = _currentTargetUrl != null && _currentTargetUrl!.trim().isNotEmpty && isValidHttpUrl(_currentTargetUrl!.trim())
        ? _currentTargetUrl!.trim()
        : null;
    final payloadStr = payload is String ? payload : (payload?.toString());
    _runPendingAction(action, payloadStr, targetUrl: targetUrl).then((_) {
      if (mounted) {
        _socketService?.sendCommandCompleted(action);
        _log('command_completed sent ($action)');
      }
    });
  }

  /// Runs auto-login in WebView (fill form + submit). Used for login_webview command and on page load.
  Future<void> _runLoginWebView() async {
    final c = _controller;
    if (c == null) return;
    if (_judgeUsername.isEmpty && _judgePassword.isEmpty) {
      _log('auto-login skipped: no credentials');
      return;
    }
    try {
      _log('login form fill and submit');
      await c.runJavaScript(_buildAutoLoginJs(_judgeUsername, _judgePassword));
      await Future.delayed(const Duration(milliseconds: 500));
      String? currentUrl;
      try { currentUrl = await c.currentUrl(); } catch (_) {}
      String status = _computeLoginStatusFromUrls(currentUrl, _currentTargetUrl);
      if (status == 'LOGGED_OUT') status = await _detectLoginStatus();
      if (mounted) setState(() => _lastLoginStatus = status);
      _socketService?.updateHeartbeatPayload(loginStatus: status);
      if (status == 'LOGGED_IN' || status == 'LOGGED_OUT') _socketService?.sendLoginStatusChanged(status);
      _log('login button clicked, status=$status');
    } catch (e) {
      _log('_runLoginWebView error: $e');
    }
  }

  /// Fires on every URL change including SPA pushState navigation (Angular router).
  /// onPageFinished does NOT fire for client-side route changes, so this is the only
  /// path for instant login-status detection without waiting for the next heartbeat.
  Future<void> _onUrlChange(String? url) async {
    if (!mounted) return;
    final targetUrl = _currentTargetUrl;
    final detected = _computeLoginStatusFromUrls(url, targetUrl);
    if (detected == 'LOGGED_IN' || detected == 'LOGGED_OUT') {
      final prev = _lastLoginStatus;
      if (prev != detected) {
        if (mounted) setState(() => _lastLoginStatus = detected);
        _log('SPA url change: loginStatus $prev -> $detected');
        _socketService?.sendLoginStatusChanged(detected);
        _socketService?.updateHeartbeatPayload(loginStatus: detected);
      }
      return;
    }
    // URL is ambiguous (root or login path) — check DOM once the SPA transition settles.
    Future.delayed(const Duration(milliseconds: 600), () async {
      if (!mounted) return;
      final domStatus = await _detectLoginStatus();
      if (domStatus != 'LOGGED_IN' && domStatus != 'LOGGED_OUT') return;
      final prev = _lastLoginStatus;
      if (prev == domStatus) return;
      if (mounted) setState(() => _lastLoginStatus = domStatus);
      _log('SPA url change (DOM): loginStatus $prev -> $domStatus');
      _socketService?.sendLoginStatusChanged(domStatus);
      _socketService?.updateHeartbeatPayload(loginStatus: domStatus);
    });
  }

  Future<void> _loadUrl(String url, {bool forceReload = false}) async {
    if (url.isEmpty || !isValidHttpUrl(url)) return;
    _targetUrlLoadStartedAt = DateTime.now();
    _autoLoginAttemptedOnCurrentPage = false;
    _autoLoginAttemptsForCurrentPage = 0;
    setState(() {
      _currentTargetUrl = url;
      _loading = true;
      _error = null;
    });
    widget.storage.setLastKnownTargetUrl(url);

    if (_controller == null) {
      final platform = WebViewPlatform.instance;
      _controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageStarted: (_) => setState(() => _loading = true),
            onPageFinished: (uri) => _onPageFinished(uri),
            onWebResourceError: (e) => setState(() {
              _error = 'Page error: ${e.description}';
              _loading = false;
            }),
            onUrlChange: (change) => _onUrlChange(change.url),
          ),
        );
      if (platform is AndroidWebViewPlatform) {
        (_controller!.platform as AndroidWebViewController)
            .setMediaPlaybackRequiresUserGesture(false);
      }
    }

    await _controller!.loadRequest(Uri.parse(url));
    if (mounted) setState(() => _loading = false);
  }

  /// Hide #toggle_mobile and show one small judge marker (letter in colored circle). Marker has pointer-events:none so it never blocks interaction.
  /// Also hide logout buttons/links on the page so logout is only possible from the server (Control). After auto-login, judge must not logout from the tablet.
  static String _buildHideAndMarkerJs(String letter, String hex) {
    final safeLetter = letter.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
    final safeHex = hex.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
    return '''
(function() {
  var letter = '$safeLetter';
  var hex = '$safeHex';
  function hideToggle() {
    var el = document.getElementById("toggle_mobile");
    if (el) {
      el.style.setProperty("display", "none", "important");
      el.style.setProperty("pointer-events", "none", "important");
    }
  }
  function hideLogout() {
    try {
      var sel = "a[href*='logout'], a[href*='Logout'], button[type='submit'][name*='logout'], .logout, [id*='logout']";
      var nodes = document.querySelectorAll(sel);
      for (var i = 0; i < nodes.length; i++) {
        var n = nodes[i];
        var txt = (n.textContent || "").toLowerCase();
        var href = (n.getAttribute("href") || "").toLowerCase();
        if (txt.indexOf("logout") !== -1 || href.indexOf("logout") !== -1) {
          n.style.setProperty("display", "none", "important");
          n.style.setProperty("pointer-events", "none", "important");
          n.style.setProperty("visibility", "hidden", "important");
        }
      }
    } catch (e) {}
  }
  function ensureMarker() {
    var existing = document.getElementById("judge_marker");
    if (existing) {
      existing.textContent = letter;
      existing.style.backgroundColor = hex;
      return;
    }
    var div = document.createElement("div");
    div.id = "judge_marker";
    div.textContent = letter;
    div.style.cssText = "position:fixed;top:12px;left:12px;width:39px;height:39px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-weight:700;font-size:20px;color:white;background-color:" + hex + ";box-shadow:0 0 4px rgba(0,0,0,0.4);pointer-events:none !important;z-index:9999;";
    if (document.body) document.body.appendChild(div);
  }
  hideToggle();
  hideLogout();
  ensureMarker();
  if (typeof MutationObserver !== "undefined") {
    var obs = new MutationObserver(function() {
      hideToggle();
      hideLogout();
      if (!document.getElementById("judge_marker")) ensureMarker();
    });
    obs.observe(document.documentElement || document.body, { childList: true, subtree: true });
  }
})();
''';
  }

  /// Auto-login for Angular login pages: wait for form, fill once, use MutationObserver to click button when it appears (e.g. button.general_btn_lg).
  String _buildAutoLoginJs(String username, String password) {
    final u = jsonEncode(username);
    final p = jsonEncode(password);
    return '''
(function(){
  var user = $u;
  var pass = $p;
  if (!user && !pass) return;
  var attempts = 0;
  var maxAttempts = 10;

  function tryLogin(){
    var username = document.querySelector('input[type="text"], input[name="username"], input[name="user"], input[id="username"]');
    var password = document.querySelector('input[type="password"]');
    var button = document.querySelector('button.general_btn_lg');

    if (!username || !password) return false;

    username.value = user;
    username.dispatchEvent(new Event('input', { bubbles: true }));
    username.dispatchEvent(new Event('change', { bubbles: true }));

    password.value = pass;
    password.dispatchEvent(new Event('input', { bubbles: true }));
    password.dispatchEvent(new Event('change', { bubbles: true }));

    if (button) {
      button.click();
      return true;
    }
    return false;
  }

  function attemptLoop(){
    attempts++;
    if (tryLogin()) return;
    if (attempts < maxAttempts) setTimeout(attemptLoop, 500);
  }

  setTimeout(attemptLoop, 500);

  var observer = new MutationObserver(function(){
    if (tryLogin()) observer.disconnect();
  });
  observer.observe(document.body, { childList: true, subtree: true });
})();
''';
  }

  /// Sync JS that returns 'LOGGED_OUT' if a *visible* login form is present (Angular-friendly), else 'LOGGED_IN'.
  /// Rules:
  /// - If there is a visible password input OR a visible button.general_btn_lg (כניסה) => LOGGED_OUT.
  /// - Otherwise => LOGGED_IN.
  static const String _detectLoginStatusJs = r'''
(function() {
  try {
    function isVisible(el) {
      if (!el) return false;
      if (el.offsetParent === null) return false;
      var style = window.getComputedStyle(el);
      if (!style) return true;
      if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') return false;
      return true;
    }

    // Angular login page: visible password input or visible כניסה button means LOGGED_OUT
    var passwordInputs = Array.prototype.slice.call(document.querySelectorAll('input[type=password]') || []);
    for (var i = 0; i < passwordInputs.length; i++) {
      if (isVisible(passwordInputs[i])) return 'LOGGED_OUT';
    }

    var loginBtn = document.querySelector('button.general_btn_lg');
    if (isVisible(loginBtn)) return 'LOGGED_OUT';

    // Fallback: if we see any obvious login form elements visible, treat as LOGGED_OUT
    var userInput = document.querySelector('input[name=username], input[name=user], input[id=username], input[id=user], input[type=text]');
    if (isVisible(userInput)) return 'LOGGED_OUT';

    return 'LOGGED_IN';
  } catch(e) {
    return 'UNKNOWN';
  }
})();
''';

  Future<String> _detectLoginStatus() async {
    final c = _controller;
    if (c == null) return 'UNKNOWN';
    try {
      final result = await c.runJavaScriptReturningResult(_detectLoginStatusJs);
      final s = (result is String ? result : result.toString()).trim().toUpperCase();
      if (s == 'LOGGED_IN' || s == 'LOGGED_OUT') return s;
    } catch (_) {}
    return 'UNKNOWN';
  }

  Future<void> _onPageFinished(Object? uri) async {
    setState(() => _loading = false);
    final c = _controller;
    if (c == null) return;
    if (!_isAdminMode) {
      try {
        // Marker rules:
        // - Color: tabletColor only (neutral fallback only when missing).
        // - Text: judge letter only.
        final rawLetter = (widget.storage.judgeLetter ?? '').toString().trim().toUpperCase();
        final displayLetter = rawLetter.isEmpty ? '' : rawLetter.substring(0, 1);
        final colorKey = (widget.storage.tabletColor ?? '').toString().trim().toLowerCase();
        debugPrint('[OVERLAY_TABLET_COLOR]=$colorKey');
        debugPrint('[DISPLAY_COLOR_SOURCE]=${colorKey.isNotEmpty ? "tabletColor" : "default"}');
        final hex = JudgeColors.hexForKey(colorKey) ?? '#888888';
        await c.runJavaScript(_buildHideAndMarkerJs(displayLetter, hex));
      } catch (_) {}
    }
    final currentUrl = uri?.toString();
    final targetUrl = _currentTargetUrl;
    String detected = _computeLoginStatusFromUrls(currentUrl, targetUrl);
    if (detected == 'LOGGED_OUT' && (currentUrl == null || currentUrl.trim().isEmpty || (targetUrl == null || targetUrl.trim().isEmpty))) {
      final domStatus = await _detectLoginStatus();
      if (domStatus == 'LOGGED_IN' || domStatus == 'LOGGED_OUT') detected = domStatus;
    }
    if (detected != 'LOGGED_IN' && detected != 'LOGGED_OUT') detected = await _detectLoginStatus();
    final prevStatus = _lastLoginStatus;
    if (mounted) setState(() => _lastLoginStatus = detected);
    if (prevStatus != detected) {
      _log('loginStatus changed: $prevStatus -> $detected');
      if (detected == 'LOGGED_IN' || detected == 'LOGGED_OUT') _socketService?.sendLoginStatusChanged(detected);
    }
    _socketService?.updateHeartbeatPayload(loginStatus: detected);
    final inGracePeriod = _targetUrlLoadStartedAt != null &&
        DateTime.now().difference(_targetUrlLoadStartedAt!) < _urlSettleGracePeriod;
    // Auto-login only when allowed (admin may have forced logout and disabled it).
    final shouldTryAutoLogin = _autoLoginAllowed &&
        (_judgeUsername.isNotEmpty || _judgePassword.isNotEmpty) &&
        (detected == 'LOGGED_OUT' || detected == 'UNKNOWN') &&
        !_autoLoginAttemptedOnCurrentPage;
    if (shouldTryAutoLogin) {
      _autoLoginAttemptedOnCurrentPage = true;
      _log('auto-login: credentials present, status=$detected, inGracePeriod=$inGracePeriod');
      void runAutoLogin() async {
        if (!mounted || _controller != c) return;
        if (_autoLoginAttemptsForCurrentPage >= 2) return;
        _autoLoginAttemptsForCurrentPage++;
        try {
          await c.runJavaScript(_buildAutoLoginJs(_judgeUsername, _judgePassword));
          _log('auto-login: form filled, submit triggered (attempt $_autoLoginAttemptsForCurrentPage)');
        } catch (e) {
          _log('auto-login error: $e');
        }
      }
      final initialDelay = inGracePeriod ? _delayedAutoLoginAfterLoad : const Duration(milliseconds: 500);
      Future.delayed(initialDelay, runAutoLogin);
      Future.delayed(inGracePeriod ? const Duration(milliseconds: 3500) : const Duration(milliseconds: 1500), () async {
        if (!mounted || _controller != c) return;
        final status = await _detectLoginStatus();
        if (status == 'LOGGED_OUT' || status == 'UNKNOWN') {
          _log('auto-login: second attempt (form may load late)');
          runAutoLogin();
        }
      });
    }
    // If we landed on blank/invalid URL, load target so we never stay on white page. In grace period add short delay so navigation can settle.
    final uriStr = uri?.toString();
    if (_isBlankOrInvalidUrl(uriStr) && _currentTargetUrl != null && _currentTargetUrl!.trim().isNotEmpty && isValidHttpUrl(_currentTargetUrl!.trim())) {
      await Future.delayed(inGracePeriod ? const Duration(milliseconds: 400) : const Duration(milliseconds: 100));
      if (!mounted) return;
      setState(() => _loading = true);
      try {
        await c.loadRequest(Uri.parse(_currentTargetUrl!.trim()));
      } catch (_) {}
      if (mounted) setState(() => _loading = false);
    }
  }

  static const String _clearStorageJs = r'''
(function() {
  try { localStorage.clear(); } catch(e) {}
  try { sessionStorage.clear(); } catch(e) {}
})();
''';

  static const String _tryLogoutJs = r'''
(function() {
  var el = document.querySelector('a[href*="logout"]') || document.querySelector('#logout') ||
    document.querySelector('.logout') || document.querySelector('a[href="#logout"]') ||
    document.querySelector('button[type="submit"][name*="logout"]') ||
    document.querySelector('input[type="submit"][value*="logout" i]');
  if (el) { el.click(); }
})();
''';

  /// Normalize URL: trim, lowercase host, ignore trailing slash, add protocol if missing.
  static _UrlNorm? _normalizeUrlForLogin(String? url) {
    final s = (url ?? '').trim();
    if (s.isEmpty) return null;
    String toParse = s;
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(toParse)) {
      toParse = 'https://${toParse.replaceFirst(RegExp(r'^/+'), '')}';
    }
    try {
      final u = Uri.parse(toParse);
      if (!u.hasScheme || (u.host.isEmpty && u.authority.isEmpty)) return null;
      final origin = u.origin.toLowerCase();
      final path = (u.path.isEmpty ? '/' : u.path).replaceFirst(RegExp(r'/+$'), '');
      final pathWithSlash = path.isEmpty ? '/' : (path.startsWith('/') ? path : '/$path');
      return _UrlNorm(origin: origin, pathWithSlash: pathWithSlash.toLowerCase());
    } catch (_) {
      return null;
    }
  }

  static bool _isLoginOrPublicPath(_UrlNorm? n) {
    if (n == null) return true;
    final p = n.pathWithSlash;
    return p == '/' || p.isEmpty || p == '/login' || p.startsWith('/login/') || p.contains('/login') ||
        p.startsWith('/auth') || p.contains('/auth/') || p.startsWith('/signin') || p.contains('/signin');
  }

  static bool _isJudgeAuthenticatedPath(_UrlNorm? n) {
    if (n == null) return false;
    final p = n.pathWithSlash;
    return p == '/judge' || p.startsWith('/judge/') || p.contains('/judge/') || p.endsWith('/judge');
  }

  /// Login status from Current URL vs Target URL only. LOGGED_IN only when same site AND path is inside judge area.
  static String _computeLoginStatusFromUrls(String? currentUrl, String? targetUrl) {
    final tarNorm = _normalizeUrlForLogin(targetUrl);
    if (tarNorm == null) return 'LOGGED_OUT';
    final curNorm = _normalizeUrlForLogin(currentUrl);
    if (curNorm == null) return 'LOGGED_OUT';
    if (curNorm.origin != tarNorm.origin) return 'LOGGED_OUT';
    if (_isLoginOrPublicPath(curNorm)) return 'LOGGED_OUT';
    if (!_isJudgeAuthenticatedPath(curNorm)) return 'LOGGED_OUT';
    return 'LOGGED_IN';
  }

  /// Returns true if URL is blank/invalid and we should load target URL instead.
  bool _isBlankOrInvalidUrl(String? url) {
    if (url == null) return true;
    final u = url.trim().toLowerCase();
    return u.isEmpty || u == 'about:blank';
  }

  /// After logout we must not stay on a white page. Load [targetUrl] if valid.
  Future<void> _ensureNotBlankPage(String? targetUrl) async {
    final c = _controller;
    if (c == null) return;
    if (targetUrl == null || targetUrl.trim().isEmpty || !isValidHttpUrl(targetUrl.trim())) return;
    final url = targetUrl.trim();
    try {
      final current = await c.currentUrl();
      if (_isBlankOrInvalidUrl(current)) {
        if (mounted) setState(() { _currentTargetUrl = url; _loading = true; _error = null; });
        widget.storage.setLastKnownTargetUrl(url);
        await c.loadRequest(Uri.parse(url));
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  /// Run pending action. For logout_webview, [targetUrl] must be set; we clear session then load targetUrl and report only after that.
  Future<void> _runPendingAction(String action, String? payload, {String? targetUrl}) async {
    final c = _controller;
    if (c == null) return;
    try {
      if (action == 'reload_webview') {
        if (targetUrl != null && targetUrl.trim().isNotEmpty && isValidHttpUrl(targetUrl.trim())) {
          if (mounted) setState(() { _currentTargetUrl = targetUrl.trim(); _loading = true; });
          widget.storage.setLastKnownTargetUrl(targetUrl.trim());
          await c.loadRequest(Uri.parse(targetUrl.trim()));
        } else {
          await c.reload();
        }
        if (mounted) setState(() => _loading = false);
        return;
      }
      if (action == 'clear_session') {
        try { await c.runJavaScript(_clearStorageJs); } catch (_) {}
        try { await c.clearLocalStorage(); } catch (_) {}
        try { await WebViewCookieManager().clearCookies(); } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 300));
        if (targetUrl != null && targetUrl.trim().isNotEmpty && isValidHttpUrl(targetUrl.trim())) {
          if (mounted) setState(() { _currentTargetUrl = targetUrl.trim(); _loading = true; });
          widget.storage.setLastKnownTargetUrl(targetUrl.trim());
          await c.loadRequest(Uri.parse(targetUrl.trim()));
        } else {
          await c.reload();
        }
        if (mounted) setState(() => _loading = false);
        return;
      }
      if (action == 'logout_webview') {
        _log('logout action: try logout button/link');
        try { await c.runJavaScript(_tryLogoutJs); } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 300));
        _log('logout action: clear cookies and storage');
        try { await c.runJavaScript(_clearStorageJs); } catch (_) {}
        try { await c.clearLocalStorage(); } catch (_) {}
        try { await WebViewCookieManager().clearCookies(); } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 300));
        if (targetUrl != null && targetUrl.trim().isNotEmpty && isValidHttpUrl(targetUrl.trim())) {
          if (mounted) setState(() { _currentTargetUrl = targetUrl.trim(); _loading = true; _error = null; });
          widget.storage.setLastKnownTargetUrl(targetUrl.trim());
          await c.loadRequest(Uri.parse(targetUrl.trim()));
          _log('logout action: loaded login page (no white page)');
        } else {
          await c.reload();
        }
        if (mounted) setState(() => _loading = false);
        _socketService?.sendLoginStatusChanged('LOGGED_OUT');
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
      await _ensureNotBlankPage(targetUrl);
    }
  }

  void _onAdminTap() {
    _adminTapTimer?.cancel();
    _adminTapCount++;
    if (_adminTapCount >= 5) {
      _adminTapCount = 0;
      _showAdminMenu();
      return;
    }
    _adminTapTimer = Timer(const Duration(seconds: 2), () {
      _adminTapCount = 0;
    });
  }

  void _onColorTap() {
    _colorTapTimer?.cancel();
    _colorTapCount++;
    if (_colorTapCount >= 5) {
      _colorTapCount = 0;
      _showKioskMenu();
      return;
    }
    _colorTapTimer = Timer(const Duration(seconds: 3), () {
      _colorTapCount = 0;
    });
  }

  Future<void> _showKioskMenu() async {
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Kiosk'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('unassign'),
            child: const Text('Unassign'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop('unlock'),
            child: const Text('Unlock'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (result == 'unlock') {
      await _kioskService.stopLockTask();
      _repinTimer?.cancel();
      _repinTimer = Timer(const Duration(seconds: 15), () {
        _kioskService.startLockTask();
      });
    } else if (result == 'unassign') {
      _repinTimer?.cancel();
      await _kioskService.stopLockTask();
      await widget.storage.clearJudgeSelection();
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => SetupScreen(
            storage: widget.storage,
            api: widget.api,
            deviceId: widget.deviceId,
            returnToWebView: false,
          ),
        ),
        (_) => false,
      );
    }
  }

  Future<void> _showAdminMenu() async {
    final isAdmin = _isAdminMode;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Admin'),
        content: Text(isAdmin ? 'Exit admin view and return to setup.' : 'Open tablet setup.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Open Setup'),
          ),
        ],
      ),
    );
    if (go == true && mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => SetupScreen(
            storage: widget.storage,
            api: widget.api,
            deviceId: widget.deviceId,
            returnToWebView: false,
          ),
        ),
        (_) => false,
      );
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _error = null;
      _loading = true;
    });
    _socketService?.dispose();
    _loadConfigAndWebView();
  }


  Future<void> _onPopInvoked(bool didPop) async {
    if (didPop) return;
    final controller = _controller;
    if (controller != null) {
      try {
        if (await controller.canGoBack()) {
          await controller.goBack();
          return;
        }
      } catch (_) {}
    }
    if (_kioskEnabled) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Back disabled. Tap top-left corner 5 times to exit.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    _showAdminMenu();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null && _currentTargetUrl == null && !_loading) {
      return Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              if (_locationPermissionGranted != true) _buildPermissionBanner(context),
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          size: 64,
                          color: Theme.of(context).colorScheme.error,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                        if (_backendUnavailable) ...[
                          const SizedBox(height: 8),
                          Text(
                            'Backend: ${widget.api.baseUrl}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                        const SizedBox(height: 24),
                        FilledButton.icon(
                          onPressed: _refresh,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        await _onPopInvoked(didPop);
      },
      child: Scaffold(
        body: Stack(
          children: [
            if (_currentTargetUrl != null && _controller != null)
              Positioned.fill(
                child: WebViewWidget(controller: _controller!),
              )
            else
              const Center(child: CircularProgressIndicator()),
            if (_loading)
              const Positioned.fill(
                child: Center(
                  child: Card(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: CircularProgressIndicator(),
                    ),
                  ),
                ),
              ),
            if (_locationPermissionGranted != true) _buildPermissionBanner(context),
            Positioned(
              top: 0,
              left: 0,
              width: 80,
              height: 80,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _onAdminTap,
                child: const SizedBox.expand(),
              ),
            ),
            Positioned(
              top: 12,
              left: 12,
              width: 39,
              height: 39,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _onColorTap,
                child: const SizedBox.expand(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPermissionBanner(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Material(
        elevation: 4,
        color: Theme.of(context).colorScheme.errorContainer,
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Enable Location so the server can show WiFi, battery and device data. '
                  'In Settings, turn OFF "Restrict app when not in use" for this app if permissions are removed.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () async {
                        await _requestLocationPermission();
                      },
                      child: const Text('Allow'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () async {
                        await _openAppSettings();
                      },
                      child: const Text('Open Settings'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
