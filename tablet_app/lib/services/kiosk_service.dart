import 'dart:io';

import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Kiosk / full-screen behaviour: immersive mode, keep screen on, back button handling.
/// On standard Android we use the strongest restrictions possible without device-owner mode.
class KioskService {
  static const _channel = MethodChannel('com.example.tablet_app/kiosk');

  bool _kioskEnabled = true;
  bool get kioskEnabled => _kioskEnabled;

  void setKioskEnabled(bool value) {
    _kioskEnabled = value;
  }

  /// Enable immersive sticky full-screen (hide status and nav bar).
  Future<void> enableImmersiveMode() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('setImmersiveMode', true);
    } catch (_) {}
  }

  /// Keep screen on (wakelock). Call when entering kiosk; disable when leaving.
  Future<void> setKeepScreenOn(bool on) async {
    if (on) {
      await WakelockPlus.enable();
    } else {
      await WakelockPlus.disable();
    }
  }

  /// Request to start lock task mode (screen pinning). Requires appropriate Android setup.
  /// On standard Android this may only work when triggered by user (e.g. recent apps → pin).
  Future<void> startLockTask() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('startLockTask');
    } catch (_) {}
  }

  /// Stop lock task mode.
  Future<void> stopLockTask() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('stopLockTask');
    } catch (_) {}
  }

  /// Check if lock task mode is currently active (device is pinned).
  Future<bool> isLockTaskMode() async {
    if (!Platform.isAndroid) return false;
    try {
      final r = await _channel.invokeMethod<bool>('isLockTaskMode');
      return r == true;
    } catch (_) {
      return false;
    }
  }
}
