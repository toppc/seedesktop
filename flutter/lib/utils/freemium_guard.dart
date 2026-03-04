import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher_string.dart';

const String kFirstLaunchTimestampKey = 'first_launch_timestamp';
const int kFreemiumTrialDays = 14;
const int kFreemiumDelayEarlySeconds = 30;
const int kFreemiumDelayLateSeconds = 60;
const int kFreeSessionLimitSeconds = 1800;
const String kBuyNowUrl = 'https://seedesktop.com';

Future<bool> hasValidLicenseLocal() async {
  final prefs = await SharedPreferences.getInstance();
  final key = prefs.getString('saved_license');
  return key != null && key.trim().isNotEmpty;
}

Future<int> ensureFirstLaunchTimestamp() async {
  final prefs = await SharedPreferences.getInstance();
  final existing = prefs.getInt(kFirstLaunchTimestampKey);
  if (existing != null && existing > 0) {
    return existing;
  }
  final now = DateTime.now().millisecondsSinceEpoch;
  await prefs.setInt(kFirstLaunchTimestampKey, now);
  return now;
}

Future<bool> shouldAllowConnectionWithFreemiumGate(BuildContext context) async {
  if (await hasValidLicenseLocal()) {
    return true;
  }

  final firstLaunch = await ensureFirstLaunchTimestamp();
  final firstLaunchDate = DateTime.fromMillisecondsSinceEpoch(firstLaunch);
  final daysPassed = DateTime.now().difference(firstLaunchDate).inDays;
  final delaySeconds = daysPassed <= kFreemiumTrialDays
      ? kFreemiumDelayEarlySeconds
      : kFreemiumDelayLateSeconds;

  return showFreemiumNagDialog(context, delaySeconds: delaySeconds);
}

Future<bool> showFreemiumNagDialog(BuildContext context,
    {required int delaySeconds}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (dialogContext) => PopScope(
      canPop: false,
      child: _FreemiumNagDialog(
        delaySeconds: delaySeconds,
        onComplete: () {
          if (Navigator.of(dialogContext, rootNavigator: true).canPop()) {
            Navigator.of(dialogContext, rootNavigator: true).pop(true);
          }
        },
      ),
    ),
  );
  return result == true;
}

Future<void> showFreeSessionLimitReachedDialog(BuildContext context) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (dialogContext) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('Session limit reached'),
        content: const Text(
          'Free session limit reached (30 minutes). The connection has been closed. '
          'Please upgrade to SeeDesktop Pro for unlimited session time.',
        ),
        actions: [
          TextButton(
            onPressed: () {
              if (Navigator.of(dialogContext, rootNavigator: true).canPop()) {
                Navigator.of(dialogContext, rootNavigator: true).pop();
              }
            },
            child: const Text('OK'),
          ),
        ],
      ),
    ),
  );
}

class _FreemiumNagDialog extends StatefulWidget {
  final int delaySeconds;
  final VoidCallback onComplete;

  const _FreemiumNagDialog({
    required this.delaySeconds,
    required this.onComplete,
  });

  @override
  State<_FreemiumNagDialog> createState() => _FreemiumNagDialogState();
}

class _FreemiumNagDialogState extends State<_FreemiumNagDialog> {
  Timer? _countdownTimer;
  late int _remainingSeconds;
  bool _connecting = false;

  @override
  void initState() {
    super.initState();
    _remainingSeconds = widget.delaySeconds;
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      if (_remainingSeconds > 1) {
        setState(() {
          _remainingSeconds -= 1;
        });
      } else {
        timer.cancel();
        setState(() {
          _remainingSeconds = 0;
          _connecting = true;
        });
        Future.delayed(const Duration(milliseconds: 400), () {
          if (mounted) {
            widget.onComplete();
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.delaySeconds <= 0 ? 1 : widget.delaySeconds;
    final progress = 1 - (_remainingSeconds / total);

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 560),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Upgrade to SeeDesktop Pro',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            const Text(
              'Upgrade to the yearly SeeDesktop Pro subscription for uninterrupted remote access.',
              style: TextStyle(fontSize: 15, color: Colors.black87),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFF6F8FF),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: const [
                      Text(
                        r'$120 / Year',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 18,
                          color: Colors.grey,
                          decoration: TextDecoration.lineThrough,
                        ),
                      ),
                      SizedBox(width: 10),
                      Text(
                        r'$96 / Year',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 28,
                          color: Color(0xFF0E9F6E),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF7E6),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: const Color(0xFFFFB547),
                        width: 1.5,
                      ),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.local_offer_outlined,
                            size: 16, color: Color(0xFFCC7A00)),
                        SizedBox(width: 6),
                        Text(
                          'Coupon Code: NW_20%',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFFCC7A00),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Includes one annual Pro license with full managed-device and session benefits.',
                    style: TextStyle(fontSize: 14),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Feature List',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 14,
                    runSpacing: 8,
                    children: const [
                      _FeatureItem('1 Concurrent Connection'),
                      _FeatureItem('1 Master License Key'),
                      _FeatureItem('Unlimited Managed Devices'),
                      _FeatureItem('Unlimited Interactive Sessions'),
                      _FeatureItem('End-to-End Encryption'),
                      _FeatureItem('Premium Support'),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed: () {
                      launchUrlString(kBuyNowUrl);
                    },
                    child: const Text('Buy Now'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            LinearProgressIndicator(
              value: progress.clamp(0, 1),
              minHeight: 8,
              borderRadius: BorderRadius.circular(8),
            ),
            const SizedBox(height: 10),
            Text(
              _connecting
                  ? 'Connecting...'
                  : 'Continuing in $_remainingSeconds seconds...',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

class _FeatureItem extends StatelessWidget {
  final String text;

  const _FeatureItem(this.text);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.check, size: 16, color: Color(0xFF0A6BFF)),
        const SizedBox(width: 6),
        Text(
          text,
          style: const TextStyle(fontSize: 13),
        ),
      ],
    );
  }
}
