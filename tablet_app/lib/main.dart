import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'services/storage_service.dart';
import 'services/kiosk_service.dart';
import 'screens/backend_resolver_screen.dart';
import 'screens/webview_screen.dart';

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

  /// Kiosk escape hatch, reached by five taps in the top-left corner.
  ///
  /// Unlocking has no timer. A countdown re-pinned the screen while the tablet
  /// was still in someone's hands, mid-task; now the screen stays open until it
  /// is locked back deliberately, from this same menu.
  ///
  /// 'Unassign' used to live here too - it cleared the judge selection and sent
  /// the tablet to the judge picker. Both are gone: whoever signs in on the
  /// scoring page is the judge, so signing out is what replaces it.
  Future<void> _showKioskMenu() async {
    final ctx = _navigatorKey.currentContext;
    if (ctx == null) return;

    bool pinned = true;
    try {
      pinned = await _kioskService.isLockTaskMode();
    } catch (_) {}
    if (!mounted) return;

    final ctx2 = _navigatorKey.currentContext;
    if (ctx2 == null) return;
    final theme = Theme.of(ctx2);
    final canLogout = WebViewScreen.logoutHook != null;

    final result = await showDialog<String>(
      context: ctx2,
      barrierDismissible: true,
      builder: (dialogCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
        contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
        title: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: pinned
                    ? theme.colorScheme.primaryContainer
                    : theme.colorScheme.tertiaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(
                pinned ? Icons.lock_outline : Icons.lock_open,
                size: 22,
                color: pinned
                    ? theme.colorScheme.onPrimaryContainer
                    : theme.colorScheme.onTertiaryContainer,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Tablet', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 20)),
                  Text(
                    pinned ? 'Screen is pinned' : 'Screen is unlocked',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: pinned
                          ? theme.colorScheme.onSurfaceVariant
                          : theme.colorScheme.tertiary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 4),
            _MenuRow(
              icon: pinned ? Icons.lock_open : Icons.lock_outline,
              label: pinned ? 'Unlock screen' : 'Lock screen again',
              detail: pinned
                  ? 'Leaves the app pinned off until you lock it back here.'
                  : 'Pins the app so it cannot be closed during judging.',
              tone: pinned ? _RowTone.normal : _RowTone.primary,
              onTap: () => Navigator.of(dialogCtx).pop(pinned ? 'unlock' : 'lock'),
            ),
            if (canLogout) ...[
              const SizedBox(height: 8),
              _MenuRow(
                icon: Icons.logout,
                label: 'Sign out judge',
                detail: 'Ends the session and returns to the login page.',
                tone: _RowTone.danger,
                onTap: () => Navigator.of(dialogCtx).pop('logout'),
              ),
            ],
          ],
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(null),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    if (result == 'unlock') {
      await _kioskService.stopLockTask();
    } else if (result == 'lock') {
      await _kioskService.startLockTask();
    } else if (result == 'logout') {
      await WebViewScreen.logoutHook?.call();
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

enum _RowTone { normal, primary, danger }

/// One tappable row in the kiosk menu: icon, label, and a line saying what it
/// actually does - the previous menu was three bare words and it was never
/// obvious which one would take the tablet out of the show.
class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.label,
    required this.detail,
    required this.tone,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String detail;
  final _RowTone tone;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Color fg = switch (tone) {
      _RowTone.danger => scheme.error,
      _RowTone.primary => scheme.primary,
      _RowTone.normal => scheme.onSurface,
    };
    final Color bg = switch (tone) {
      _RowTone.danger => scheme.errorContainer.withValues(alpha: 0.35),
      _RowTone.primary => scheme.primaryContainer.withValues(alpha: 0.45),
      _RowTone.normal => scheme.surfaceContainerHighest,
    };

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(icon, size: 22, color: fg),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: fg),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant, height: 1.25),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
