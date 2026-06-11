import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'services/storage_service.dart';
import 'services/kiosk_service.dart';
import 'screens/backend_resolver_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final storage = StorageService(prefs);

  String deviceId = storage.deviceId ?? '';
  if (deviceId.isEmpty) {
    deviceId = const Uuid().v4();
    await storage.setDeviceId(deviceId);
  }

  runApp(TabletMonitorApp(
    storage: storage,
    deviceId: deviceId,
  ));
}

class TabletMonitorApp extends StatefulWidget {
  const TabletMonitorApp({
    super.key,
    required this.storage,
    required this.deviceId,
  });

  final StorageService storage;
  final String deviceId;

  @override
  State<TabletMonitorApp> createState() => _TabletMonitorAppState();
}

class _TabletMonitorAppState extends State<TabletMonitorApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _kioskService = KioskService();
  int _colorTapCount = 0;
  Timer? _colorTapTimer;
  Timer? _repinTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _kioskService.setKeepScreenOn(true);
      await Future.delayed(const Duration(milliseconds: 400));
      final alreadyPinned = await _kioskService.isLockTaskMode();
      if (!alreadyPinned) await _kioskService.startLockTask();
    });
  }

  @override
  void dispose() {
    _kioskService.setKeepScreenOn(false);
    _colorTapTimer?.cancel();
    _repinTimer?.cancel();
    super.dispose();
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
    final ctx = _navigatorKey.currentContext;
    if (ctx == null) return;
    final result = await showDialog<String>(
      context: ctx,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Kiosk'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(null),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop('unassign'),
            child: const Text('Unassign'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogCtx).pop('unlock'),
            child: const Text('Unlock'),
          ),
        ],
      ),
    );
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
      _navigatorKey.currentState?.pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => BackendResolverScreen(
            storage: widget.storage,
            deviceId: widget.deviceId,
          ),
        ),
        (_) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tablet Monitor',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue, brightness: Brightness.light),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      builder: (_, child) => Stack(
        children: [
          child!,
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
      home: BackendResolverScreen(
        storage: widget.storage,
        deviceId: widget.deviceId,
      ),
    );
  }
}
