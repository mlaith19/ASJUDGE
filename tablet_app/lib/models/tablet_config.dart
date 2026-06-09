class TabletConfig {
  final String targetWebviewUrl;
  final String judgeName;
  final String judgeLetter;
  final String judgeColor;
  /// When no judge is assigned, server sends a stable display color for this tablet (palette key).
  final String tabletDisplayColor;
  final String judgeUsername;
  final String judgePassword;
  final String tabletLabel;
  final int pollingIntervalSeconds;
  final bool forceReload;
  final bool kioskModeEnabled;
  final bool keepScreenOn;
  final String? expectedWifiSSID;
  final String? pendingAction;
  final String? pendingActionPayload;
  final bool adminTabletAlertsEnabled;

  const TabletConfig({
    required this.targetWebviewUrl,
    required this.judgeName,
    this.judgeLetter = '',
    this.judgeColor = '',
    this.tabletDisplayColor = '',
    this.judgeUsername = '',
    this.judgePassword = '',
    required this.tabletLabel,
    required this.pollingIntervalSeconds,
    required this.forceReload,
    this.kioskModeEnabled = true,
    this.keepScreenOn = true,
    this.expectedWifiSSID,
    this.pendingAction,
    this.pendingActionPayload,
    this.adminTabletAlertsEnabled = true,
  });

  factory TabletConfig.fromJson(Map<String, dynamic> json) {
    return TabletConfig(
      targetWebviewUrl: (json['targetWebviewUrl'] as String?)?.trim() ?? '',
      judgeName: (json['judgeName'] as String?)?.trim() ?? '',
      judgeLetter: ((json['judgeLetter'] ?? json['judge_letter'] ?? json['judge'] ?? '') as String?)?.trim().toUpperCase() ?? '',
      judgeColor: (json['judgeColor'] as String?)?.trim() ?? '',
      tabletDisplayColor: ((json['tabletDisplayColor'] ?? json['tabletColor'] ?? json['tablet_color']) as String?)?.trim().toLowerCase() ?? '',
      judgeUsername: (json['judgeUsername'] as String?)?.trim() ?? '',
      judgePassword: (json['judgePassword'] as String?)?.trim() ?? '',
      tabletLabel: (json['tabletLabel'] as String?)?.trim() ?? '',
      pollingIntervalSeconds: _parseInt(json['pollingIntervalSeconds'], 25),
      forceReload: json['forceReload'] == true,
      kioskModeEnabled: json['kioskModeEnabled'] != false,
      keepScreenOn: json['keepScreenOn'] != false,
      expectedWifiSSID: (json['expectedWifiSSID'] as String?)?.trim().isNotEmpty == true
          ? (json['expectedWifiSSID'] as String).trim()
          : null,
      pendingAction: (json['pendingAction'] as String?)?.trim().isNotEmpty == true
          ? (json['pendingAction'] as String).trim()
          : null,
      pendingActionPayload: (json['pendingActionPayload'] as String?)?.trim().isNotEmpty == true
          ? (json['pendingActionPayload'] as String).trim()
          : null,
      adminTabletAlertsEnabled: json['adminTabletAlertsEnabled'] != false,
    );
  }

  static int _parseInt(dynamic v, int def) {
    if (v == null) return def;
    if (v is int) return v.clamp(10, 300);
    final n = int.tryParse(v.toString());
    return n != null ? n.clamp(10, 300) : def;
  }
}
