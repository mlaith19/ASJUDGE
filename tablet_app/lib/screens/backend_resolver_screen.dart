import 'package:flutter/material.dart';

import '../services/storage_service.dart';
import '../services/api_service.dart';
import '../services/backend_discovery_service.dart';
import '../services/device_info_service.dart';
import '../utils/url_validator.dart';
import 'setup_screen.dart';

/// Resolves backend URL: use saved → verify; else discover on LAN; else show manual entry.
class BackendResolverScreen extends StatefulWidget {
  const BackendResolverScreen({
    super.key,
    required this.storage,
    required this.deviceId,
  });

  final StorageService storage;
  final String deviceId;

  @override
  State<BackendResolverScreen> createState() => _BackendResolverScreenState();
}

class _BackendResolverScreenState extends State<BackendResolverScreen> {
  final _discovery = BackendDiscoveryService();
  final _deviceInfo = DeviceInfoService();

  bool _loading = true;
  bool _showManual = false;
  String? _error;
  String? _tabletIp;

  @override
  void initState() {
    super.initState();
    _clearJudgeAndResolve();
  }

  /// On every app start: clear saved judge so we always show Judge Selection (no auto-memory).
  Future<void> _clearJudgeAndResolve() async {
    await widget.storage.clearJudgeSelection();
    if (!mounted) return;
    _resolve();
  }

  static const int _maxDiscoveryAttempts = 2;

  Future<void> _resolve() async {
    setState(() {
      _loading = true;
      _showManual = false;
      _error = null;
    });

    try {
      final saved = widget.storage.backendApiBaseUrl;
      if (saved != null && saved.trim().isNotEmpty) {
        final ok = await _discovery.verify(saved.trim());
        if (ok && mounted) {
          await _navigateToApp();
          return;
        }
      }

      final localIp = await _deviceInfo.getLocalIp();
      if (mounted) setState(() => _tabletIp = localIp);

      String? found;
      for (var attempt = 1; attempt <= _maxDiscoveryAttempts; attempt++) {
        found = await _discovery.discover(localIp);
        if (found != null) break;
        if (attempt < _maxDiscoveryAttempts && mounted) {
          await Future<void>.delayed(const Duration(seconds: 2));
        }
      }

      if (mounted && found != null) {
        await widget.storage.setBackendApiBaseUrl(found);
        await _navigateToApp();
        return;
      }
    } catch (_) {}

    if (mounted) {
      setState(() {
        _loading = false;
        _showManual = true;
        _error = 'Backend not found on network. Enter server URL manually or tap Retry.';
      });
    }
  }

  void _showManualEntry() {
    setState(() {
      _loading = false;
      _showManual = true;
      _error = null;
    });
  }

  Future<void> _navigateToApp() async {
    final url = widget.storage.backendApiBaseUrl;
    if (url == null || url.isEmpty) return;
    final api = ApiService(baseUrl: url);
    if (!mounted) return;
    // Always open Judge Selection on startup; only admin force-assignment can skip it.
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => SetupScreen(
          storage: widget.storage,
          api: api,
          deviceId: widget.deviceId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_showManual) {
      return _ManualBackendScreen(
        storage: widget.storage,
        deviceId: widget.deviceId,
        tabletIp: _tabletIp,
        initialError: _error,
        onResolved: _navigateToApp,
        onRetryDiscovery: () async {
          setState(() => _showManual = false);
          await _resolve();
        },
      );
    }

    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_loading) ...[
              const CircularProgressIndicator(),
              const SizedBox(height: 24),
              Text(
                'Finding backend server…',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 32),
              Text(
                'לא נמצא? הזן כתובת ידנית',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: _showManualEntry,
                icon: const Icon(Icons.edit),
                label: const Text('הזן כתובת שרת ידנית'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ManualBackendScreen extends StatefulWidget {
  const _ManualBackendScreen({
    required this.storage,
    required this.deviceId,
    this.tabletIp,
    this.initialError,
    required this.onResolved,
    required this.onRetryDiscovery,
  });

  final StorageService storage;
  final String deviceId;
  final String? tabletIp;
  final String? initialError;
  final VoidCallback onResolved;
  final VoidCallback onRetryDiscovery;

  @override
  State<_ManualBackendScreen> createState() => _ManualBackendScreenState();
}

class _ManualBackendScreenState extends State<_ManualBackendScreen> {
  final _formKey = GlobalKey<FormState>();
  final _urlController = TextEditingController();
  final _discovery = BackendDiscoveryService();
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _error = widget.initialError;
    _urlController.text = widget.storage.backendApiBaseUrl ?? '';
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _saveAndContinue() async {
    _error = null;
    if (!_formKey.currentState!.validate()) return;
    final url = _urlController.text.trim();
    if (!isValidHttpUrl(url)) {
      setState(() => _error = 'Enter a valid http or https URL.');
      return;
    }
    setState(() => _loading = true);
    final ok = await _discovery.verify(url);
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _loading = false;
        _error = 'Server did not respond correctly. Check URL and try again.';
      });
      return;
    }
    await widget.storage.setBackendApiBaseUrl(url);
    if (!mounted) return;
    widget.onResolved();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Backend server',
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Enter the backend server URL (e.g. http://192.168.1.52:5000)',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                      textAlign: TextAlign.center,
                    ),
                    if (widget.tabletIp != null && widget.tabletIp!.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Tablet IP: ${widget.tabletIp} (backend is usually same subnet, e.g. http://192.168.1.XX:5000)',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      'Ensure backend is running on your PC (npm start) and both are on the same WiFi.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    TextFormField(
                      controller: _urlController,
                      decoration: const InputDecoration(
                        labelText: 'Backend URL',
                        hintText: 'http://192.168.1.52:5000',
                        border: OutlineInputBorder(),
                        filled: true,
                      ),
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) return 'Required';
                        if (!isValidHttpUrl(v.trim())) return 'Invalid URL';
                        return null;
                      },
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onErrorContainer,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _loading ? null : _saveAndContinue,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        minimumSize: const Size.fromHeight(52),
                      ),
                      child: _loading
                          ? const SizedBox(
                              height: 24,
                              width: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Save and continue'),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: _loading ? null : widget.onRetryDiscovery,
                      child: const Text('Try discovery again'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
