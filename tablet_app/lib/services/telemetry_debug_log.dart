import 'dart:convert';
import 'dart:developer' as developer;

/// Runtime telemetry debug — enable: flutter run --dart-define=TELEM_DEBUG=true
const bool kTelemetryDebug =
    bool.fromEnvironment('TELEM_DEBUG', defaultValue: false);

void telemLog(String tag, String message, [Map<String, dynamic>? extra]) {
  if (!kTelemetryDebug) return;
  final buf = StringBuffer(message);
  if (extra != null && extra.isNotEmpty) {
    buf.write(' ');
    buf.write(jsonEncode(extra));
  }
  developer.log(buf.toString(), name: tag);
}
