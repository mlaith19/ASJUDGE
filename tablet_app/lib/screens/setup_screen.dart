import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../config/judge_colors.dart';
import '../services/storage_service.dart';
import '../services/api_service.dart';
import '../services/device_info_service.dart';
import '../services/heartbeat_telemetry.dart';
import '../services/evidence_capture.dart';
import '../services/socket_service.dart';
import 'webview_screen.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({
    super.key,
    required this.storage,
    required this.api,
    required this.deviceId,
    this.returnToWebView = false,
  });

  final StorageService storage;
  final ApiService api;
  final String deviceId;
  /// When true, opened from WebView for editing; on save pop back to WebView instead of replacing.
  final bool returnToWebView;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

/// Sentinel judge letter that activates admin dashboard view mode.
const _kAdminJudgeLetter = '__ADMIN__';

const _adminItem = JudgeListItem(
  letter: _kAdminJudgeLetter,
  name: 'Admin View',
  color: '',
);

class _SetupScreenState extends State<SetupScreen> {
  final _formKey = GlobalKey<FormState>();
  List<JudgeListItem> _judges = [];
  JudgeListItem? _selectedJudge;
  bool _loading = false;
  bool _loadingJudges = true;
  String? _error;
  bool _showJudgeInvalidatedBanner = false;
  SocketService? _socketService;

  /*
   * THE CAMERA CHECK, AND WHY IT LIVES HERE.
   *
   * Two things about the front camera can only be settled at installation, and
   * both of them are impossible in a hall:
   *
   *   - Android asks for the camera permission once, with a dialog. Inside a
   *     class the tablet is pinned in kiosk mode and there is nobody to answer
   *     it, so the answer has to be given here, by whoever sets the tablet up.
   *   - These tablets sit on angled stands and nobody has ever seen what the
   *     front camera gets from there. It could be a judge, half a face, or a
   *     ceiling. A single test frame on this screen answers it.
   */
  Uint8List? _camTestShot;
  bool _camBusy = false;
  String? _camNote;

  Future<void> _runCameraCheck() async {
    setState(() { _camBusy = true; _camNote = null; });
    try {
      final status = await Permission.camera.request();
      if (!status.isGranted) {
        setState(() {
          _camNote = status.isPermanentlyDenied
              ? 'Camera permission is blocked. Open Android settings for this app and allow it.'
              : 'Camera permission was not granted.';
        });
        return;
      }
      final bytes = await EvidenceCapture.testShot();
      if (!mounted) return;
      setState(() {
        _camTestShot = bytes;
        _camNote = bytes == null ? 'No camera answered on this tablet.' : null;
      });
    } catch (e) {
      if (mounted) setState(() => _camNote = 'Camera check failed: $e');
    } finally {
      if (mounted) setState(() => _camBusy = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _showJudgeInvalidatedBanner = widget.storage.judgeSelectionInvalidated;
    if (_showJudgeInvalidatedBanner) {
      widget.storage.setJudgeSelectionInvalidated(false);
    }
    _loadJudges();
    if (!widget.returnToWebView) _connectSocketForForceAssign();
  }

  /// Connect with no judge so we can receive force_judge_assignment from admin.
  void _connectSocketForForceAssign() {
    final baseUrl = widget.api.baseUrl.trim();
    if (baseUrl.isEmpty) return;
    final s = SocketService(
      baseUrl: baseUrl,
      deviceId: widget.deviceId,
      judgeLetter: '',
      judgeName: '',
      judgeColor: '',
    );
    final di = DeviceInfoService();
    s.gatherTelemetryForEmit = () async {
      final conn = await di.getConnectivityState();
      return HeartbeatTelemetry.build(
        deviceInfo: di,
        currentWebviewUrl: null,
        loginStatus: 'SETUP_NO_JUDGE',
        foregroundState: 'setup_screen',
        kioskModeActive: false,
        screenOn: false,
        connectivityState: conn,
      );
    };
    // Tablet badge color source is tabletDisplayColor only (tablet-owned color, not judge-owned).
    s.onConfigReceived = (cfg) {
      if (cfg == null) return;
      final tabletDisplayColor = (cfg.tabletDisplayColor ?? '').trim().toLowerCase();
      debugPrint('[TABLET_RECEIVED_TABLET_COLOR]=$tabletDisplayColor');
      final colorToStore = tabletDisplayColor;
      if (colorToStore.isEmpty) return;
      widget.storage.setTabletColor(colorToStore).then((_) {
        debugPrint('[STORAGE_TABLET_COLOR_SAVED]=$colorToStore');
        if (!mounted) return;
        setState(() {});
      });
    };
    s.onCommand = _onSocketCommand;
    s.connect();
    _socketService = s;
  }

  void _onSocketCommand(String action, dynamic payload) {
    if (action != 'force_judge_assignment' || !mounted) return;
    String? letter;
    String name = '';
    if (payload is Map<String, dynamic>) {
      letter = (payload['judgeLetter'] ?? payload['judge_letter'])?.toString().trim().toUpperCase();
      name = (payload['judgeName'] ?? payload['judge_name'])?.toString().trim() ?? '';
    }
    if (letter == null || letter.isEmpty) return;
    _socketService?.dispose();
    _socketService = null;
    widget.storage.saveSetup(
      judgeLetter: letter,
      judgeName: name,
      // Keep tablet-owned color; force assignment must only change the letter/name.
      judgeColor: '',
      tabletLabel: widget.storage.tabletLabel ?? '',
    ).then((_) {
      if (!mounted) return;
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
  }

  Future<void> _loadJudges() async {
    setState(() => _loadingJudges = true);
    final list = await widget.api.getJudges();
    debugPrint('[COLOR_DBG] SERVER_JUDGES_COUNT=${list.length}');
    for (final j in list) {
      debugPrint('[COLOR_DBG] SERVER_JUDGE letter=${j.letter} color=${j.color.isEmpty ? "(empty)" : j.color}');
    }
    if (!mounted) return;
    setState(() {
      _judges = [...list, _adminItem];
      _loadingJudges = false;
      final storedLetter = (widget.storage.judgeLetter ?? '').trim().toUpperCase();
      if (_judges.isNotEmpty) {
        _selectedJudge = storedLetter.isEmpty
            ? _judges.first
            : _judges.firstWhere(
                (j) => j.letter == storedLetter,
                orElse: () => _judges.first,
              );
      }
      debugPrint('[COLOR_DBG] SELECTED_JUDGE letter=${_selectedJudge?.letter ?? "(null)"} color=${_selectedJudge?.color ?? "(null)"}');
    });
  }

  @override
  void dispose() {
    _socketService?.dispose();
    super.dispose();
  }

  /// Circle with assigned tablet color and judge letter (from admin or selected judge).
  Widget _buildAssignedJudgeBadge(BuildContext context) {
    final storedLetter = (widget.storage.judgeLetter ?? '').trim().toUpperCase();
    if (storedLetter == _kAdminJudgeLetter) {
      return Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xFF6B21A8),
          border: Border.all(color: const Color(0xFF6B21A8).withOpacity(0.6), width: 1.5),
          boxShadow: [BoxShadow(color: const Color(0xFF6B21A8).withOpacity(0.4), blurRadius: 6, offset: const Offset(0, 2))],
        ),
        alignment: Alignment.center,
        child: const Icon(Icons.admin_panel_settings, color: Colors.white, size: 22),
      );
    }
    final hasJudge = storedLetter.isNotEmpty;
    final displayText = hasJudge ? storedLetter.substring(0, 1) : '?';

    // Color source rule for HOME:
    // - Always use tablet color from storage.
    // - Judge letter affects text only.
    final tabletColorKey = (widget.storage.tabletColor ?? '').trim().toLowerCase();
    final mappedTabletColor = JudgeColors.colorForKey(tabletColorKey);
    final color = mappedTabletColor ?? Theme.of(context).colorScheme.outline.withOpacity(0.4);
    final colorSource = mappedTabletColor != null ? 'tabletColor' : 'default';
    final fallbackUsed = mappedTabletColor == null;

    debugPrint('[HOME_BADGE] HOME_BADGE_SCREEN_RUNNING');
    debugPrint('[HOME_TABLET_COLOR]=$tabletColorKey');
    debugPrint('[SETUP_TABLET_COLOR]=$tabletColorKey');
    debugPrint('[DISPLAY_COLOR_SOURCE]=$colorSource');
    debugPrint('[HOME_DISPLAY_TEXT]=$displayText');
    debugPrint('[HOME_BADGE] HOME_BADGE_FALLBACK_USED=$fallbackUsed');

    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withOpacity(0.6),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.4),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        displayText,
        style: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: _contrastColor(color),
        ),
      ),
    );
  }

  Color _contrastColor(Color background) {
    final luminance = background.computeLuminance();
    return luminance > 0.4 ? Colors.black87 : Colors.white;
  }

  Future<void> _saveAndContinue() async {
    _error = null;
    if (_selectedJudge == null) {
      setState(() => _error = 'Select a judge from the list. Add judges in Admin → Judges first.');
      return;
    }
    // Admin View bypasses normal judge validation.
    if (_selectedJudge!.letter != _kAdminJudgeLetter) {
      if (!_formKey.currentState!.validate()) return;
    }
    setState(() => _loading = true);

    final judgeLetter = _selectedJudge!.letter;
    final judgeName = _selectedJudge!.name;
    debugPrint('[SETUP_SAVING_JUDGE]=letter=$judgeLetter name=$judgeName');

    await widget.storage.saveSetup(
      judgeName: judgeName,
      judgeLetter: judgeLetter,
      judgeColor: '',
      tabletLabel: widget.storage.tabletLabel ?? '',
    );

    setState(() => _loading = false);
    if (!mounted) return;
    if (widget.returnToWebView) {
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => WebViewScreen(
            storage: widget.storage,
            api: widget.api,
            deviceId: widget.deviceId,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.returnToWebView
          ? AppBar(
              title: const Text('Edit judge setup'),
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.of(context).pop(),
              ),
            )
          : null,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned(
              left: 16,
              top: 16,
              child: _buildAssignedJudgeBadge(context),
            ),
            Center(
              child: SingleChildScrollView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (!widget.returnToWebView) ...[
                          const SizedBox(height: 40),
                          Image.asset(
                            'assets/app_logo.png',
                            height: 140,
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) =>
                                const SizedBox(height: 100),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'ARABIAN SHOW JUDGES',
                            style: Theme.of(context)
                                .textTheme
                                .headlineSmall
                                ?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.2,
                                ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 24),
                        ] else ...[
                          Text(
                            'Edit judge setup',
                            style: Theme.of(context)
                                .textTheme
                                .headlineMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Choose the judge for this tablet. Name and color come from the server.',
                            style: Theme.of(context)
                                .textTheme
                                .bodyLarge
                                ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                        if (_showJudgeInvalidatedBanner) ...[
                          const SizedBox(height: 20),
                          Material(
                            color: Theme.of(context)
                                .colorScheme
                                .errorContainer
                                .withOpacity(0.6),
                            borderRadius: BorderRadius.circular(12),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 12),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.info_outline,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onErrorContainer,
                                    size: 22,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      'The previously selected judge is no longer available. Please choose another judge.',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onErrorContainer,
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 32),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest
                            .withOpacity(0.5),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Device ID',
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                          const SizedBox(height: 6),
                          SelectableText(
                            widget.deviceId,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  fontFamily: 'monospace',
                                ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    if (_loadingJudges)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (_judges.isEmpty)
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.errorContainer.withOpacity(0.5),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          'No judges found. Add judges in Admin → Judges, then try again.',
                          style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
                          textAlign: TextAlign.center,
                        ),
                      )
                    else
                      DropdownButtonFormField<JudgeListItem>(
                        initialValue: _selectedJudge,
                        decoration: const InputDecoration(
                          labelText: 'Judge',
                          hintText: 'Select judge (letter — name)',
                          border: OutlineInputBorder(),
                          filled: true,
                        ),
                        isExpanded: true,
                        items: _judges
                            .map((j) => DropdownMenuItem(
                                  value: j,
                                  child: j.letter == _kAdminJudgeLetter
                                      ? const Row(
                                          children: [
                                            Icon(Icons.admin_panel_settings, size: 20, color: Color(0xFF6B21A8)),
                                            SizedBox(width: 8),
                                            Text('Admin View', style: TextStyle(fontSize: 18, color: Color(0xFF6B21A8), fontWeight: FontWeight.w600)),
                                          ],
                                        )
                                      : Row(
                                          children: [
                                            if (j.color.isNotEmpty) ...[
                                              Container(
                                                width: 20,
                                                height: 20,
                                                decoration: BoxDecoration(
                                                  shape: BoxShape.circle,
                                                  color: JudgeColors.colorForKey(j.color) ?? Colors.grey,
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                            ],
                                            Text(
                                              '${j.letter} — ${j.name.isEmpty ? "(no name)" : j.name}',
                                              style: const TextStyle(fontSize: 18),
                                            ),
                                          ],
                                        ),
                                ))
                            .toList(),
                        onChanged: (v) {
                          if (v != null) setState(() => _selectedJudge = v);
                        },
                        validator: (v) {
                          if (v == null) return 'Select a judge';
                          return null;
                        },
                      ),
                    const SizedBox(height: 20),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
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
                    const Divider(),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Icon(Icons.photo_camera_outlined, size: 20),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'Camera check',
                            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                          ),
                        ),
                        OutlinedButton(
                          onPressed: _camBusy ? null : _runCameraCheck,
                          child: _camBusy
                              ? const SizedBox(
                                  height: 18, width: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : Text(_camTestShot == null ? 'Test shot' : 'Again'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Grants the camera permission and shows what the front camera sees from this stand. Do it here - a class cannot answer a permission dialog.',
                      style: TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                    if (_camNote != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _camNote!,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.red),
                      ),
                    ],
                    if (_camTestShot != null) ...[
                      const SizedBox(height: 10),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.memory(
                          _camTestShot!,
                          fit: BoxFit.contain,
                          // Rebuilt on every retake, so the decoded frame is not
                          // kept alive by the image cache behind the new one.
                          gaplessPlayback: false,
                        ),
                      ),
                    ],
                    const SizedBox(height: 32),
                    if (widget.returnToWebView)
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _loading ? null : () => Navigator.of(context).pop(),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 16),
                              ),
                              child: const Text('Cancel'),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            flex: 2,
                            child: FilledButton(
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
                                  : const Text('Save'),
                            ),
                          ),
                        ],
                      )
                    else
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
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  ),
    );
  }
}
