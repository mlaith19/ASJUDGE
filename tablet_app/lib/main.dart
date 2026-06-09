import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'services/storage_service.dart';
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

class TabletMonitorApp extends StatelessWidget {
  const TabletMonitorApp({
    super.key,
    required this.storage,
    required this.deviceId,
  });

  final StorageService storage;
  final String deviceId;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tablet Monitor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue, brightness: Brightness.light),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: BackendResolverScreen(
        storage: storage,
        deviceId: deviceId,
      ),
    );
  }
}
