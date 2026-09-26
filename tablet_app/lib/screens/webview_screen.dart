import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vibration/vibration.dart';
/*
 * flutter_inappwebview, not webview_flutter.
 *
 * webview_flutter has no pull-to-refresh and no way to bolt one on: the WebView
 * swallows the vertical drag before any Flutter widget above it sees it, so a
 * RefreshIndicator wrapped around it never fires. inappwebview exposes Android's
 * own SwipeRefreshLayout through PullToRefreshController - the same gesture
 * every other app on the tablet has, and the only one that behaves correctly
 * over a page that scrolls its own inner panes rather than the document.
 *
 * Nothing else about this screen changes. The kiosk, the heartbeat, the socket
 * and the admin corner never touched the WebView API and are untouched here.
 */
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

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

  /// Set by the live screen while it is mounted, so the kiosk menu in main.dart
  /// can run exactly the same logout the server's 'logout_webview' command runs
  /// - click the page's logout, clear cookies and storage, load the login page,
  /// and report LOGGED_OUT. Null when no WebView is on screen.
  static Future<void> Function()? logoutHook;

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
  InAppWebViewController? _controller;
  PullToRefreshController? _pullToRefresh;
  String? _currentTargetUrl;
  bool _loading = true;
  String? _error;
  bool _backendUnavailable = false;
  SocketService? _socketService;
  /*
   * THE LOADING CARD'S DEAD-MAN SWITCH.
   *
   * _loading raises a Card over the whole screen, and until now exactly one
   * thing could lower it again: onLoadStop. That is an event, not a promise. A
   * page whose load never completes - a request that never returns, a server
   * that went away mid-build, a network that dropped between onLoadStart and the
   * first byte - leaves the tablet under a modal spinner with no way out but
   * killing the app. Measured on 25/09 after a judge logged out: the login page
   * was underneath, drawn and working, behind a card nobody could dismiss.
   *
   * In a browser the same unfinished load is a tab that keeps spinning and you
   * carry on reading the page. That is the behaviour to match, so this timer
   * lifts the card whether or not the event ever arrives. It does not cancel the
   * load and it does not reload anything - the page underneath stays exactly as
   * it is, and it is usually complete.
   */
  Timer? _loadingWatchdog;
  Timer? _heartbeatPayloadTimer;
  bool _kioskEnabled = true;
  bool _keepScreenOn = true;
  String _foregroundState = 'foreground';
  int _adminTapCount = 0;
  Timer? _adminTapTimer;
  bool _navigatingToSetup = false;
  String _lastLoginStatus = 'UNKNOWN';
  /// When false, tablet must NOT auto-login (e.g. after admin forced logout).
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
  void _log(String msg) => debugPrint('[$_logTag] $msg');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WebViewScreen.logoutHook = _menuLogout;
    /*
     * Pull down to refresh, always armed - and the pull DISTANCE is the only
     * guard on it.
     *
     * Android arms this gesture whenever the page is scrolled to the top. On an
     * ordinary page that is rare, because you have to scroll all the way up
     * first. The judge screen is a fixed 100dvh layout whose panes scroll inside
     * themselves and whose document never scrolls at all, so it is at the top
     * permanently and the gesture is live on every part of the screen that is
     * not one of those inner panes.
     *
     * Keeping it live is deliberate. The case this exists for is a tablet stuck
     * mid-show, and a guard that asks the page whether anything is unsent would
     * be asking the very page that has stopped answering - it would switch the
     * refresh off exactly when it is needed.
     *
     * The pull distance is Android's default, ON PURPOSE. A longer one was set
     * first, reasoning that a fixed-height page arms the gesture everywhere and a
     * stray touch should not reload a judge mid-class. Then the gesture did not
     * fire in the hall, and with a non-default distance in the way there was no
     * telling whether the gesture was broken or merely stiff. Get it working at
     * the distance every other app on the tablet uses; tighten it only if it
     * turns out to fire by accident, with the evidence in hand rather than ahead
     * of it.
     */
    _pullToRefresh = PullToRefreshController(
      settings: PullToRefreshSettings(
        color: const Color(0xFFFF9800),
      ),
      onRefresh: _refresh,
    );
    _applyFullscreen();
    _loadConfigAndWebView();
    // On Android: check permission after build; show dialog if not granted (user tap = system shows permission dialog)
    WidgetsBinding.instance.addPostFrameCallback((_) async {
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
    // Only clear the hook if it is still ours - a newer screen may have replaced it.
    if (identical(WebViewScreen.logoutHook, _menuLogout)) WebViewScreen.logoutHook = null;
    _heartbeatPayloadTimer?.cancel();
    _loadingWatchdog?.cancel();
    _socketService?.dispose();
    _adminTapTimer?.cancel();
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

  late final Future<void> Function() _menuLogout = () async {
    final target = (_currentTargetUrl ?? widget.storage.lastKnownTargetUrl ?? '').trim();
    await _runPendingAction('logout_webview', null, targetUrl: target.isEmpty ? null : target);
  };

  Future<void> _loadConfigAndWebView() async {
    final judgeLetter = (widget.storage.judgeLetter ?? '').trim();
    if (judgeLetter == _kAdminJudgeLetter) {
      _loadAdminView();
      return;
    }
    // An empty judge letter is the NORMAL state now: the tablet carries no judge
    // identity of its own, it just shows the login page and whoever signs in is
    // the judge. It used to stop here with 'No judge selected'.
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
          currentUrl = (await _controller!.getUrl())?.toString();
        } catch (_) {}
      }
      var loginStatus = 'UNKNOWN';
      if (mounted) {
        loginStatus = await _resolveLoginStatus(currentUrl);
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
      _heartbeatPayloadTimer?.cancel();
      _heartbeatPayloadTimer = Timer.periodic(const Duration(seconds: 3), (_) => _updateHeartbeatPayload());
      _updateHeartbeatPayload();
      _requestLocationForHeartbeatIfNeeded();
      return;
    }
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
        currentUrl = (await _controller!.getUrl())?.toString();
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

    final String loginStatus = await _resolveLoginStatus(currentUrl);
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
    // Auto-login is gone. The server used to hand the tablet a judge's username
    // and password in clear text so the app could type them into the page; the
    // judge signs in themselves now, so there is nothing to automate and nothing
    // to leak. The commands are still acknowledged so an older admin build does
    // not sit waiting for a reply.
    if (action == 'login_webview' || action == 'set_auto_login_enabled') {
      _log('$action ignored: auto-login was removed');
      _socketService?.sendCommandCompleted(action);
      return;
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
    setState(() {
      _currentTargetUrl = url;
      _loading = true;
      _error = null;
    });
    widget.storage.setLastKnownTargetUrl(url);

    /*
     * The widget owns the controller now, and that inverts the order here.
     *
     * webview_flutter built a controller and handed it to the widget, so this
     * method could navigate before anything was on screen. inappwebview builds
     * the widget first and hands a controller back in onWebViewCreated, so the
     * FIRST url travels in initialUrlRequest - read from _currentTargetUrl, set
     * in the setState above - and every later one goes through loadUrl.
     *
     * A null controller is therefore not a failure: it means the WebView has not
     * been built yet, and it will be built pointing at this very url.
     */
    final c = _controller;
    if (c != null) {
      await c.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    }
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
  // The tablet-colour dot used to be drawn here, in the top-left corner, as a
  // visual hint for the 5-tap kiosk gesture. It sat right next to the scoring
  // page's own judge badge, so every tablet showed two coloured circles that
  // did different things - the app's one and the judge's one. The gesture area
  // is a Flutter widget and works with nothing drawn, so the marker is gone and
  // the judge badge is the only circle on screen.
  function removeMarker() {
    var existing = document.getElementById("judge_marker");
    if (existing && existing.parentNode) existing.parentNode.removeChild(existing);
  }
  hideToggle();
  hideLogout();
  removeMarker();
  if (typeof MutationObserver !== "undefined") {
    var obs = new MutationObserver(function() {
      hideToggle();
      hideLogout();
      removeMarker();
    });
    obs.observe(document.documentElement || document.body, { childList: true, subtree: true });
  }
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

  /// Kicks off the session lookup and parks the answer on `window`.
  ///
  /// It has to be split in two: `evaluateJavascript` evaluates an expression and
  /// returns its value IMMEDIATELY - it does not await a Promise. Returning
  /// `fetch(...)` handed back an unresolved Promise every time, the letter came
  /// out empty, and the code silently fell back to guessing from the URL. So:
  /// one call starts the request, a second one reads the result.
  ///
  /// Kept as-is through the move to inappwebview. That package does offer
  /// callAsyncJavaScript, which awaits a Promise and would collapse this into one
  /// call - but it needs a newer Android WebView than some of these tablets are
  /// known to have, and this is the code that decides whether a judge reads as
  /// signed in. Not worth finding out during a show.
  static const String _whoAmIStartJs = r"""
(function() {
  try {
    window.__asWhoAmI = 'PENDING';
    fetch('/api/auth/me', { credentials: 'include', cache: 'no-store' })
      .then(function(r) { return r.ok ? r.json() : null; })
      .then(function(j) {
        window.__asWhoAmI = JSON.stringify({
          letter: (j && j.judgeLetter) || '',
          name: (j && (j.judgeName || j.username)) || ''
        });
      })
      .catch(function() { window.__asWhoAmI = JSON.stringify({ letter: '', name: '' }); });
  } catch (e) {
    window.__asWhoAmI = JSON.stringify({ letter: '', name: '' });
  }
})();
""";

  static const String _whoAmIReadJs = r"""(window.__asWhoAmI || '')""";

  /// Android returns JS strings JSON-encoded, so a string arrives wrapped in
  /// quotes and escaped. Unwrap once before parsing what is inside.
  static String _unwrapJsString(Object? raw) {
    var text = (raw is String ? raw : raw.toString()).trim();
    if (text.startsWith('"')) {
      try { text = jsonDecode(text) as String; } catch (_) {}
    }
    return text;
  }

  /// (letter, name) of the signed-in judge; empty strings when nobody is.
  Future<(String, String)> _fetchSignedInJudge() async {
    final c = _controller;
    if (c == null) return ('', '');
    try {
      await c.evaluateJavascript(source: _whoAmIStartJs);
      // ~1.5s is plenty for a request to a server on the same LAN; if it has not
      // answered by then the fallbacks below take over for this cycle only.
      for (var i = 0; i < 15; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
        final text = _unwrapJsString(await c.evaluateJavascript(source: _whoAmIReadJs));
        if (text.isEmpty || text == 'PENDING' || text == 'null') continue;
        final map = jsonDecode(text);
        if (map is Map) {
          final letter = (map['letter'] ?? '').toString().trim();
          final name = (map['name'] ?? '').toString().trim();
          if (letter.isNotEmpty) _log('signed in as: letter=$letter name=$name');
          return (letter, name);
        }
        break;
      }
    } catch (e) {
      _log('whoami failed: $e');
    }
    return ('', '');
  }

  /// The one place that answers "is a judge signed in, and who".
  ///
  /// The session is the authority, so it is asked FIRST. Everything else here is
  /// a fallback for when /api/auth/me cannot be reached at all.
  ///
  /// The old order guessed from the URL and only asked the server once the guess
  /// already said LOGGED_IN - so a wrong guess could never be corrected. And it
  /// was wrong: the judge screen lives at **/judge-2**, while the path test only
  /// accepted '/judge' followed by a slash. A judge who was very much signed in
  /// read as signed out for a whole show.
  Future<String> _resolveLoginStatus(String? currentUrl) async {
    final (letter, name) = await _fetchSignedInJudge();
    if (letter.isNotEmpty) {
      _socketService?.setSignedInJudge(letter, name);
      return 'LOGGED_IN';
    }
    _socketService?.setSignedInJudge('', '');

    final targetUrl = _currentTargetUrl;
    var status = _computeLoginStatusFromUrls(currentUrl, targetUrl);
    if (status != 'LOGGED_IN' && status != 'LOGGED_OUT') {
      status = await _detectLoginStatus();
    }
    return status;
  }

  Future<String> _detectLoginStatus() async {
    final c = _controller;
    if (c == null) return 'UNKNOWN';
    try {
      final result = await c.evaluateJavascript(source: _detectLoginStatusJs);
      final s = (result is String ? result : result.toString()).trim().toUpperCase();
      if (s == 'LOGGED_IN' || s == 'LOGGED_OUT') return s;
    } catch (_) {}
    return 'UNKNOWN';
  }

  /*
   * THE PAGE'S WAY OF SAYING "A SCORE JUST WENT".
   *
   * The judging screen runs inside this WebView and cannot photograph itself -
   * a page has no way to capture the pixels it is drawn as, and no way to reach
   * the camera the way this evidence needs it. Flutter can do both. So the page
   * announces the moment and this side does the work.
   *
   * STAGE 1 OF THE PLAN, AND DELIBERATELY EMPTY.
   * Right now it only writes down what it was told. No screenshot, no camera, no
   * upload - those are stages 2, 3 and 4. What is being proven here is that the
   * call arrives at all, and arrives with the right horse on it. Building the
   * capture on top of a bridge nobody had watched work would mean debugging two
   * new things at once, on a tablet, in a hall.
   *
   * It answers, always. The page does not wait for the answer, but a handler that
   * throws would surface in the page's console as a rejected promise, and this
   * must never be the reason anybody looks twice at the scoring screen.
   */
  void _installEvidenceHandler(InAppWebViewController c) {
    c.addJavaScriptHandler(
      handlerName: 'captureEvidence',
      callback: (args) {
        try {
          final payload = (args.isNotEmpty && args.first is Map)
              ? Map<String, dynamic>.from(args.first as Map)
              : <String, dynamic>{};
          _log('[EVIDENCE] ${jsonEncode(payload)}');

          /*
           * Onto the heartbeat, so it is visible on the management screen within
           * three seconds instead of inside a logcat nobody can reach.
           *
           * Deliberately short - the heartbeat goes out every 3 seconds and this
           * rides along on every one of them. Horse and judge are what identify
           * the moment; the full payload stays in the log.
           */
          final horse = payload['horseNumber'];
          final who = (payload['judgeNickname'] ?? '').toString();
          _socketService?.setLastEvidence('#$horse $who');

          return {'ok': true, 'stage': 1};
        } catch (e) {
          // Swallowed on purpose: see the note above. A broken bridge is a
          // missing photograph, never a disturbed judge.
          _log('[EVIDENCE] handler error: $e');
          return {'ok': false, 'error': e.toString()};
        }
      },
    );
    _log('[EVIDENCE] handler installed');
  }

  /*
   * IS THE BRIDGE ACTUALLY THERE?
   *
   * captureEvidence is announced by the page and swallowed silently on this side
   * if anything goes wrong - deliberately, because a judge pressing SEND must
   * never see a problem of ours. The cost of that choice is that a bridge which
   * is simply absent looks exactly like a bridge that works and had nothing to
   * report. This tells the two apart.
   *
   * The question is real and not theoretical. The plugin's own documentation says
   * that on Android, when the WebView does not support DOCUMENT_START_SCRIPT,
   * window.flutter_inappwebview does not exist until a
   * flutterInAppWebViewPlatformReady event has fired - so on an older tablet the
   * object the page calls may never appear at all.
   *
   * The answer rides the heartbeat to the management screen rather than going to
   * a log, for the same reason the evidence line does: a log on a tablet in a
   * hall is a log nobody can reach without a cable.
   *
   * It keeps earning its place after today. A tablet whose bridge is dead is a
   * tablet that will score a whole class and photograph none of it, and that is
   * worth seeing before a show rather than after.
   */
  Future<void> _probeEvidenceBridge() async {
    final c = _controller;
    if (c == null) return;
    try {
      final raw = await c.evaluateJavascript(source: """
        (function () {
          try {
            var b = window.flutter_inappwebview;
            if (!b) return 'missing';
            return (typeof b.callHandler === 'function') ? 'ok' : 'no-callHandler';
          } catch (e) { return 'error'; }
        })()
      """);
      final status = _unwrapJsString(raw).trim();
      _log('[EVIDENCE] bridge probe: $status');
      _socketService?.setBridgeStatus(status.isEmpty ? 'unknown' : status);
    } catch (e) {
      _log('[EVIDENCE] bridge probe failed: $e');
      _socketService?.setBridgeStatus('probe-failed');
    }
  }

  /// How long the loading card may stay up without onLoadStop arriving.
  ///
  /// Long enough that a slow page is not interrupted by its own spinner
  /// vanishing, short enough that nobody in the ring is left looking at a white
  /// card wondering whether the tablet died.
  static const Duration _loadingWatchdogTimeout = Duration(seconds: 8);

  void _armLoadingWatchdog() {
    _loadingWatchdog?.cancel();
    _loadingWatchdog = Timer(_loadingWatchdogTimeout, () {
      if (!mounted || !_loading) return;
      _log('loading watchdog: no onLoadStop after ${_loadingWatchdogTimeout.inSeconds}s - lifting the overlay');
      setState(() => _loading = false);
    });
  }

  void _clearLoadingWatchdog() {
    _loadingWatchdog?.cancel();
    _loadingWatchdog = null;
  }

  Future<void> _onPageFinished(Object? uri) async {
    _clearLoadingWatchdog();
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
        await c.evaluateJavascript(source: _buildHideAndMarkerJs(displayLetter, hex));
      } catch (_) {}
    }
    final currentUrl = uri?.toString();
    final detected = await _resolveLoginStatus(currentUrl);

    final prevStatus = _lastLoginStatus;
    if (mounted) setState(() => _lastLoginStatus = detected);
    if (prevStatus != detected) {
      _log('loginStatus changed: $prevStatus -> $detected');
      if (detected == 'LOGGED_IN' || detected == 'LOGGED_OUT') _socketService?.sendLoginStatusChanged(detected);
    }
    _socketService?.updateHeartbeatPayload(loginStatus: detected);
    final inGracePeriod = _targetUrlLoadStartedAt != null &&
        DateTime.now().difference(_targetUrlLoadStartedAt!) < _urlSettleGracePeriod;
    // If we landed on blank/invalid URL, load target so we never stay on white page. In grace period add short delay so navigation can settle.
    final uriStr = uri?.toString();
    if (_isBlankOrInvalidUrl(uriStr) && _currentTargetUrl != null && _currentTargetUrl!.trim().isNotEmpty && isValidHttpUrl(_currentTargetUrl!.trim())) {
      await Future.delayed(inGracePeriod ? const Duration(milliseconds: 400) : const Duration(milliseconds: 100));
      if (!mounted) return;
      setState(() => _loading = true);
      try {
        await c.loadUrl(urlRequest: URLRequest(url: WebUri(_currentTargetUrl!.trim())));
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
      final current = (await c.getUrl())?.toString();
      if (_isBlankOrInvalidUrl(current)) {
        if (mounted) setState(() { _currentTargetUrl = url; _loading = true; _error = null; });
        widget.storage.setLastKnownTargetUrl(url);
        await c.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
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
          await c.loadUrl(urlRequest: URLRequest(url: WebUri(targetUrl.trim())));
        } else {
          await c.reload();
        }
        if (mounted) setState(() => _loading = false);
        return;
      }
      if (action == 'clear_session') {
        try { await c.evaluateJavascript(source: _clearStorageJs); } catch (_) {}
        try { await c.webStorage.localStorage.clear(); } catch (_) {}
        try { await CookieManager.instance().deleteAllCookies(); } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 300));
        if (targetUrl != null && targetUrl.trim().isNotEmpty && isValidHttpUrl(targetUrl.trim())) {
          if (mounted) setState(() { _currentTargetUrl = targetUrl.trim(); _loading = true; });
          widget.storage.setLastKnownTargetUrl(targetUrl.trim());
          await c.loadUrl(urlRequest: URLRequest(url: WebUri(targetUrl.trim())));
        } else {
          await c.reload();
        }
        if (mounted) setState(() => _loading = false);
        return;
      }
      if (action == 'logout_webview') {
        _log('logout action: try logout button/link');
        try { await c.evaluateJavascript(source: _tryLogoutJs); } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 300));
        _log('logout action: clear cookies and storage');
        try { await c.evaluateJavascript(source: _clearStorageJs); } catch (_) {}
        try { await c.webStorage.localStorage.clear(); } catch (_) {}
        try { await CookieManager.instance().deleteAllCookies(); } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 300));
        if (targetUrl != null && targetUrl.trim().isNotEmpty && isValidHttpUrl(targetUrl.trim())) {
          if (mounted) setState(() { _currentTargetUrl = targetUrl.trim(); _loading = true; _error = null; });
          widget.storage.setLastKnownTargetUrl(targetUrl.trim());
          await c.loadUrl(urlRequest: URLRequest(url: WebUri(targetUrl.trim())));
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

  Future<void> _showAdminMenu() async {
    final isAdmin = _isAdminMode;
    /*
     * Reload sits here beside Setup, and it reloads the PAGE rather than running
     * the full refresh.
     *
     * The full sequence re-reads the tablet's configuration from the server first,
     * which is the right thing when the target address has moved and the slow
     * thing when it has not. In the hall the common case is a screen that has
     * stopped responding, and there the fastest thing that works beats the most
     * thorough one - so the quick path is the one on the menu, and the thorough
     * one stays behind Retry on the error screen.
     */
    final go = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Admin'),
        content: Text(isAdmin
            ? 'Reload the page, or exit admin view and return to setup.'
            : 'Reload the page, or open tablet setup.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('cancel'),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('reload'),
            child: const Text('Reload page'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop('setup'),
            child: const Text('Open Setup'),
          ),
        ],
      ),
    );
    if (go == 'reload') {
      try {
        await _controller?.reload();
      } catch (_) {
        // A controller that cannot reload is a controller that has no page; the
        // error screen and its Retry are already the answer to that.
      }
      return;
    }
    if (go == 'setup' && mounted) {
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

  /*
   * One refresh, reached two ways: the Retry button and the pull.
   *
   * Deliberately the whole sequence and not controller.reload(). A tablet that
   * needs refreshing in the hall is usually a tablet whose target url moved, and
   * re-reading the config is the part that actually fixes it; a bare reload puts
   * the same dead page back and looks like the refresh did nothing.
   */
  Future<void> _refresh() async {
    setState(() {
      _error = null;
      _loading = true;
    });
    _socketService?.dispose();
    try {
      await _loadConfigAndWebView();
    } finally {
      // The spinner belongs to the gesture, not to the page load: if the config
      // call never answers there is no page event coming to end it, and it would
      // sit there turning for the rest of the show.
      await _pullToRefresh?.endRefreshing();
    }
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
            if (_currentTargetUrl != null)
              Positioned.fill(
                child: InAppWebView(
                  initialUrlRequest: URLRequest(url: WebUri(_currentTargetUrl!)),
                  initialSettings: InAppWebViewSettings(
                    javaScriptEnabled: true,
                    mediaPlaybackRequiresUserGesture: false,
                  ),
                  pullToRefreshController: _pullToRefresh,
                  onWebViewCreated: (c) {
                    _controller = c;
                    _installEvidenceHandler(c);
                  },
                  onLoadStart: (_, __) {
                    if (!mounted) return;
                    setState(() => _loading = true);
                    _armLoadingWatchdog();
                  },
                  /*
                   * The earlier of the two signals that the page is usable.
                   *
                   * onLoadStop waits for the load to COMPLETE; progress reaching
                   * 100 says the document is there and drawn, which is all the
                   * overlay was ever waiting for. A page still holding one open
                   * request reaches 100 and never stops, and that is precisely
                   * the case that used to trap the screen.
                   */
                  onProgressChanged: (_, progress) {
                    if (progress < 100 || !mounted || !_loading) return;
                    _clearLoadingWatchdog();
                    setState(() => _loading = false);
                  },
                  onLoadStop: (_, url) async {
                    await _pullToRefresh?.endRefreshing();
                    await _onPageFinished(url);
                    // After the page is up, so the answer is about the page the
                    // judge is actually looking at.
                    await _probeEvidenceBridge();
                  },
                  /*
                   * Main frame only.
                   *
                   * webview_flutter's onWebResourceError fired for the page;
                   * this one fires for every resource that fails, so a missing
                   * favicon or one dead image would have replaced a working
                   * judge screen with a full-screen error. isForMainFrame is the
                   * difference between "the page did not load" and "something on
                   * it did not".
                   */
                  onReceivedError: (_, request, error) async {
                    if (request.isForMainFrame != true) return;
                    _clearLoadingWatchdog();
                    await _pullToRefresh?.endRefreshing();
                    if (!mounted) return;
                    setState(() {
                      _error = 'Page error: ${error.description}';
                      _loading = false;
                    });
                  },
                  onUpdateVisitedHistory: (_, url, __) => _onUrlChange(url?.toString()),
                ),
              )
            else
              const Center(child: CircularProgressIndicator()),
            /*
             * NO LOADING CARD OVER A PAGE THAT IS ALREADY THERE.
             *
             * There used to be a Card with a spinner in the middle of the screen
             * for the whole of every load. Two things were wrong with it, and the
             * operator named both: it is a second spinner saying what the pull to
             * refresh indicator at the top already says, and it covers the page
             * while it says it. When a load did not report a clean finish it also
             * stayed there for good - a working page behind a card nobody could
             * dismiss, which is how a tablet got bricked mid-show on 25/09.
             *
             * Removed rather than fixed. A browser does not grey out the old page
             * while the new one loads either; the pull indicator is the feedback,
             * and the page underneath stays readable the whole time.
             *
             * _loading itself stays - it still tells the error screen below
             * whether a load is in flight - and the watchdog still keeps it
             * honest. Neither of them draws anything any more.
             */
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
