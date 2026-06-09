import 'package:shared_preferences/shared_preferences.dart';

import '../models/tablet_identity.dart';

class StorageService {
  static const _keyDeviceId = 'device_id';
  static const _keyJudgeName = 'judge_name';
  static const _keyJudgeLetter = 'judge_letter';
  static const _keyJudgeColor = 'judge_color';
  static const _keyTabletLabel = 'tablet_label';
  static const _keySetupDone = 'setup_done';
  static const _keyLastKnownTargetUrl = 'last_known_target_url';
  static const _keyBackendApiBaseUrl = 'backend_api_base_url';
  static const _keyJudgeSelectionInvalidated = 'judge_selection_invalidated';
  static const _keyAdminPin = 'admin_pin';

  final SharedPreferences _prefs;

  StorageService(this._prefs);

  String? get deviceId => _prefs.getString(_keyDeviceId);
  String? get judgeName => _prefs.getString(_keyJudgeName);
  String? get judgeLetter => _prefs.getString(_keyJudgeLetter);
  String? get judgeColor => _prefs.getString(_keyJudgeColor);
  String? get tabletColor {
    final v = _prefs.getString(_keyJudgeColor);
    // ignore: avoid_print
    print('[STORAGE_TABLET_COLOR_LOADED]=${v ?? ""}');
    return v;
  }
  String? get tabletLabel => _prefs.getString(_keyTabletLabel);
  bool get setupDone => _prefs.getBool(_keySetupDone) ?? false;
  String? get lastKnownTargetUrl => _prefs.getString(_keyLastKnownTargetUrl);
  String? get backendApiBaseUrl => _prefs.getString(_keyBackendApiBaseUrl);

  Future<void> setDeviceId(String id) => _prefs.setString(_keyDeviceId, id);
  Future<void> setJudgeName(String name) => _prefs.setString(_keyJudgeName, name);
  Future<void> setJudgeLetter(String letter) async {
    await _prefs.setString(_keyJudgeLetter, letter);
    // ignore: avoid_print
    print('[STORAGE_JUDGE_LETTER_SAVED]=$letter');
  }
  Future<void> setJudgeColor(String colorKey) async {
    await _prefs.setString(_keyJudgeColor, colorKey);
    // ignore: avoid_print
    print('[STORAGE_TABLET_COLOR_SAVED]=$colorKey');
  }
  Future<void> setTabletColor(String colorKey) => setJudgeColor(colorKey);
  Future<void> saveTabletColor(String colorKey) => setTabletColor(colorKey);
  Future<void> setTabletLabel(String label) => _prefs.setString(_keyTabletLabel, label);
  Future<void> setSetupDone(bool value) => _prefs.setBool(_keySetupDone, value);
  Future<void> setLastKnownTargetUrl(String? url) {
    if (url == null || url.isEmpty) return _prefs.remove(_keyLastKnownTargetUrl);
    return _prefs.setString(_keyLastKnownTargetUrl, url);
  }

  Future<void> setBackendApiBaseUrl(String? url) async {
    if (url == null || url.isEmpty) {
      await _prefs.remove(_keyBackendApiBaseUrl);
      return;
    }
    await _prefs.setString(_keyBackendApiBaseUrl, url.trim());
  }

  /// Returns current identity from stored values; deviceId must be passed in (caller ensures it exists).
  TabletIdentity getIdentity(String deviceId) => TabletIdentity(
        deviceId: deviceId,
        judgeName: judgeName ?? '',
        judgeLetter: judgeLetter ?? TabletIdentity.judgeLetterOptions.first,
        judgeColor: judgeColor ?? '',
        tabletLabel: tabletLabel ?? '',
      );

  /// True when we navigated to setup because saved judge was not found on backend (show banner).
  bool get judgeSelectionInvalidated => _prefs.getBool(_keyJudgeSelectionInvalidated) ?? false;
  Future<void> setJudgeSelectionInvalidated(bool value) => _prefs.setBool(_keyJudgeSelectionInvalidated, value);

  String get adminPin => _prefs.getString(_keyAdminPin) ?? '';
  bool get hasPinSet => adminPin.length == 4;
  Future<void> setAdminPin(String pin) => _prefs.setString(_keyAdminPin, pin);

  /// Clear saved judge selection and mark setup not done. Keeps deviceId and backend URL. Call when backend reports judge not found.
  Future<void> clearJudgeSelection() async {
    await _prefs.remove(_keyJudgeLetter);
    await _prefs.remove(_keyJudgeName);
    await _prefs.remove(_keyJudgeColor);
    await _prefs.setBool(_keySetupDone, false);
  }

  /// Save first-time setup: judge name, letter, color, optional label; mark setup completed.
  Future<void> saveSetup({
    required String judgeName,
    required String judgeLetter,
    String judgeColor = '',
    String tabletLabel = '',
  }) async {
    await _prefs.setString(_keyJudgeName, judgeName);
    await _prefs.setString(_keyJudgeLetter, judgeLetter);
    await _prefs.setString(_keyJudgeColor, judgeColor);
    await _prefs.setString(_keyTabletLabel, tabletLabel);
    await _prefs.setBool(_keySetupDone, true);
  }
}
