/// Internal model for tablet/judge identity.
/// Used locally and prepared for later backend sync (Judge Letter, Name, Battery, etc.).
class TabletIdentity {
  final String deviceId;
  final String judgeName;
  final String judgeLetter;
  final String judgeColor;
  final String tabletLabel;

  const TabletIdentity({
    required this.deviceId,
    required this.judgeName,
    required this.judgeLetter,
    this.judgeColor = '',
    this.tabletLabel = '',
  });

  /// Judge letter options; easy to extend.
  static const List<String> judgeLetterOptions = ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H'];

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'judgeName': judgeName,
        'judgeLetter': judgeLetter,
        'judgeColor': judgeColor,
        'tabletLabel': tabletLabel,
      };
}
