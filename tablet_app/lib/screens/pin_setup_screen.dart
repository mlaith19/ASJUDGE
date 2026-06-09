import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/storage_service.dart';
import '../services/kiosk_service.dart';
import 'backend_resolver_screen.dart';

class PinSetupScreen extends StatefulWidget {
  const PinSetupScreen({
    super.key,
    required this.storage,
    required this.deviceId,
  });

  final StorageService storage;
  final String deviceId;

  @override
  State<PinSetupScreen> createState() => _PinSetupScreenState();
}

class _PinSetupScreenState extends State<PinSetupScreen> {
  final _kioskService = KioskService();
  String _first = '';
  String _second = '';
  bool _confirming = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  void _tap(String digit) {
    setState(() {
      _error = null;
      if (!_confirming) {
        if (_first.length < 4) {
          _first += digit;
          if (_first.length == 4) {
            Future.delayed(const Duration(milliseconds: 250), () {
              if (mounted) setState(() => _confirming = true);
            });
          }
        }
      } else {
        if (_second.length < 4) {
          _second += digit;
          if (_second.length == 4) _confirm();
        }
      }
    });
  }

  void _delete() {
    setState(() {
      _error = null;
      if (!_confirming) {
        if (_first.isNotEmpty) _first = _first.substring(0, _first.length - 1);
      } else {
        if (_second.isNotEmpty) _second = _second.substring(0, _second.length - 1);
      }
    });
  }

  Future<void> _confirm() async {
    if (_first == _second) {
      await widget.storage.setAdminPin(_first);
      await _kioskService.startLockTask();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => BackendResolverScreen(
          storage: widget.storage,
          deviceId: widget.deviceId,
        ),
      ));
    } else {
      setState(() {
        _error = 'PINs do not match. Try again.';
        _second = '';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = _confirming ? _second : _first;
    return Scaffold(
      backgroundColor: const Color(0xFF0f172a),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.lock_outline, color: Colors.white54, size: 48),
                const SizedBox(height: 20),
                Text(
                  _confirming ? 'Confirm PIN' : 'Set Admin PIN',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _confirming
                      ? 'Enter the PIN again to confirm'
                      : 'Choose a 4-digit PIN to protect admin access',
                  style: const TextStyle(color: Colors.white54, fontSize: 14),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 36),
                // Dots
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(4, (i) {
                    final filled = i < current.length;
                    return Container(
                      margin: const EdgeInsets.symmetric(horizontal: 12),
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: filled ? Colors.white : Colors.transparent,
                        border: Border.all(
                          color: filled ? Colors.white : Colors.white38,
                          width: 2,
                        ),
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 16),
                AnimatedOpacity(
                  opacity: _error != null ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Text(
                    _error ?? ' ',
                    style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                  ),
                ),
                const SizedBox(height: 28),
                // Number pad
                _PinPad(onDigit: _tap, onDelete: _delete),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PinPad extends StatelessWidget {
  const _PinPad({required this.onDigit, required this.onDelete});
  final void Function(String) onDigit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final rows = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      ['', '0', 'del'],
    ];
    return Column(
      children: rows.map((row) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: row.map((key) {
            if (key.isEmpty) return const SizedBox(width: 88);
            final isDel = key == 'del';
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Material(
                color: isDel
                    ? Colors.red.shade900.withValues(alpha: 0.6)
                    : Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: isDel ? onDelete : () => onDigit(key),
                  child: SizedBox(
                    width: 80,
                    height: 68,
                    child: Center(
                      child: isDel
                          ? const Icon(Icons.backspace_outlined,
                              color: Colors.white70, size: 22)
                          : Text(
                              key,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 30,
                                fontWeight: FontWeight.w300,
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      )).toList(),
    );
  }
}
