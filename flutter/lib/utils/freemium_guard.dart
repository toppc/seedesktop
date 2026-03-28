import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:flutter_hbb/utils/admin_settings_service.dart';
import 'package:flutter_hbb/utils/license_manager.dart';

const String kFirstLaunchTimestampKey = 'first_launch_timestamp';
const int kFreemiumTrialDays = 14;
const int kFreemiumDelayEarlySeconds = 30;
const int kFreemiumDelayLateSeconds = 60;
const int kFreeSessionLimitSeconds = 1800;
const String kBuyNowUrl = 'https://seedesktop.com';

/// Shown after license-related status text (settings + status strip).
const String kLicenseStatusWebsiteSuffix = ' • https://seedesktop.com';

/// Text without the trailing website suffix (for pairing with a tappable link).
String licenseStatusWithoutWebsiteSuffix(String full) {
  if (full.endsWith(kLicenseStatusWebsiteSuffix)) {
    return full.substring(0, full.length - kLicenseStatusWebsiteSuffix.length);
  }
  return full;
}

/// Only active PRO may select/copy the masked license display; FREE / unlicensed / grace / expired cannot.
Future<bool> shouldAllowLicenseDisplayCopyLocal() async {
  return await getLocalLicenseTier() == LocalLicenseTier.proActive;
}

enum LocalLicenseTier {
  unlicensed,
  free,
  proActive,
  proExpired,
}

DateTime? _parseSavedExpiryUtc(String rawValue) {
  var value = rawValue.trim();
  if (value.isEmpty) return null;
  if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    value = '${value}T23:59:59';
  }
  if (value.contains(' ') && !value.contains('T')) {
    value = value.replaceFirst(' ', 'T');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return null;
  return parsed.isUtc ? parsed.toLocal() : parsed;
}

Future<LocalLicenseTier> getLocalLicenseTier() async {
  final prefs = await SharedPreferences.getInstance();
  final key = prefs.getString('saved_license')?.trim() ?? '';
  if (key.isEmpty) {
    return LocalLicenseTier.unlicensed;
  }
  final upperKey = key.toUpperCase();
  if (upperKey.startsWith('SD-FREE-')) {
    return LocalLicenseTier.free;
  }
  if (!upperKey.startsWith('SD-')) {
    return LocalLicenseTier.unlicensed;
  }
  final graceStartMs = prefs.getInt(kLicenseGraceStartMsPrefsKey) ?? 0;
  if (graceStartMs > 0) {
    final elapsed = DateTime.now().millisecondsSinceEpoch - graceStartMs;
    if (elapsed >= kLicenseGracePeriodMs) {
      await clearLicensePrefs();
      return LocalLicenseTier.unlicensed;
    }
    // During grace mode, behave like FREE (no 30-min forced disconnect).
    return LocalLicenseTier.free;
  }
  final isForcedExpired = prefs.getBool(kLicenseIsExpiredPrefsKey) ?? false;
  if (isForcedExpired) {
    return LocalLicenseTier.proExpired;
  }
  final expiryRaw = prefs.getString(kLicenseExpiryIsoPrefsKey)?.trim() ?? '';
  final expiry = _parseSavedExpiryUtc(expiryRaw);
  if (expiry == null) {
    // Keep active when backend marked the key valid but did not provide a parseable date.
    return LocalLicenseTier.proActive;
  }
  if (DateTime.now().isAfter(expiry)) {
    return LocalLicenseTier.proExpired;
  }
  return LocalLicenseTier.proActive;
}

Future<bool> hasValidLicenseLocal() async {
  final prefs = await SharedPreferences.getInstance();
  final key = prefs.getString('saved_license');
  return key != null && key.trim().isNotEmpty;
}

Future<bool> isUnlicensedLocal() async {
  return (await getLocalLicenseTier()) == LocalLicenseTier.unlicensed;
}

Future<bool> isFreeTierLicenseLocal() async {
  return (await getLocalLicenseTier()) == LocalLicenseTier.free;
}

Future<bool> isExpiredProLicenseLocal() async {
  return (await getLocalLicenseTier()) == LocalLicenseTier.proExpired;
}

Future<bool> hasProLicenseLocal() async {
  return (await getLocalLicenseTier()) == LocalLicenseTier.proActive;
}

Future<bool> shouldEnforceThirtyMinuteTimeoutLocal() async {
  final tier = await getLocalLicenseTier();
  return tier == LocalLicenseTier.unlicensed ||
      tier == LocalLicenseTier.proExpired;
}

Future<int?> getProDaysUntilExpiryLocal() async {
  final prefs = await SharedPreferences.getInstance();
  final key = prefs.getString('saved_license')?.trim() ?? '';
  if (key.isEmpty || key.toUpperCase().startsWith('SD-FREE-')) {
    return null;
  }
  final expiryRaw = prefs.getString(kLicenseExpiryIsoPrefsKey)?.trim() ?? '';
  final expiry = _parseSavedExpiryUtc(expiryRaw);
  if (expiry == null) return null;
  final now = DateTime.now();
  return expiry.difference(now).inDays;
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');

Future<String?> getProRenewalDateDisplayLocal() async {
  final prefs = await SharedPreferences.getInstance();
  final key = prefs.getString('saved_license')?.trim() ?? '';
  if (key.isEmpty || key.toUpperCase().startsWith('SD-FREE-')) {
    return null;
  }
  final expiryRaw = prefs.getString(kLicenseExpiryIsoPrefsKey)?.trim() ?? '';
  final expiry = _parseSavedExpiryUtc(expiryRaw);
  if (expiry == null) return null;
  return '${expiry.year}-${_twoDigits(expiry.month)}-${_twoDigits(expiry.day)} '
      '${_twoDigits(expiry.hour)}:${_twoDigits(expiry.minute)}';
}

Future<String> getLicenseStatusDisplayTextLocal({int renewalWindowDays = 30}) async {
  final prefs = await SharedPreferences.getInstance();
  final savedLicense = prefs.getString('saved_license')?.trim() ?? '';
  if (savedLicense.isEmpty) {
    return 'Unlicensed · אנונימי$kLicenseStatusWebsiteSuffix';
  }
  final graceStartMs = prefs.getInt(kLicenseGraceStartMsPrefsKey) ?? 0;
  if (graceStartMs > 0) {
    final elapsed = DateTime.now().millisecondsSinceEpoch - graceStartMs;
    final remainingMs = kLicenseGracePeriodMs - elapsed;
    if (remainingMs <= 0) {
      return 'Unlicensed · אנונימי$kLicenseStatusWebsiteSuffix';
    }
    final remainingHours = (remainingMs / (60 * 60 * 1000)).ceil();
    return 'Licensed: ${maskLicense(savedLicense)}  •  '
        'Status: Temporary Free Mode (${remainingHours}h left)$kLicenseStatusWebsiteSuffix';
  }
  final tier = await getLocalLicenseTier();
  if (tier == LocalLicenseTier.free) {
    return 'Free License · ${maskLicense(savedLicense)}$kLicenseStatusWebsiteSuffix';
  }
  final base = 'Licensed: ${maskLicense(savedLicense)}';
  if (tier == LocalLicenseTier.proExpired) {
    return '$base  •  Status: PRO Expired - Running in Free Mode$kLicenseStatusWebsiteSuffix';
  }
  if (tier == LocalLicenseTier.proActive) {
    final days = await getProDaysUntilExpiryLocal();
    if (days != null && days <= renewalWindowDays) {
      final normalizedDays = days < 0 ? 0 : days;
      return '$base  •  Renew in $normalizedDays day${normalizedDays == 1 ? '' : 's'}$kLicenseStatusWebsiteSuffix';
    }
    return '$base$kLicenseStatusWebsiteSuffix';
  }
  return '$base$kLicenseStatusWebsiteSuffix';
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
  if (await hasProLicenseLocal()) {
    return true;
  }

  await AdminSettingsService.startSync();
  final adminDelaySeconds = AdminSettingsService.promoDelaySeconds;
  if (adminDelaySeconds <= 0) {
    return true;
  }

  final firstLaunch = await ensureFirstLaunchTimestamp();
  final firstLaunchDate = DateTime.fromMillisecondsSinceEpoch(firstLaunch);
  final daysPassed = DateTime.now().difference(firstLaunchDate).inDays;
  final fallbackDelaySeconds = daysPassed <= kFreemiumTrialDays
      ? kFreemiumDelayEarlySeconds
      : kFreemiumDelayLateSeconds;
  final delaySeconds =
      adminDelaySeconds > 0 ? adminDelaySeconds : fallbackDelaySeconds;

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

Future<void> showConcurrentConnectionLicenseDialog(BuildContext context) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    useRootNavigator: true,
    builder: (dialogContext) => AlertDialog(
      title: const Text('SeeDesktop Pro required'),
      content: const Text(
        'Free users can run only one active connection at a time.\n'
        'To connect to multiple computers simultaneously, please upgrade to SeeDesktop Pro.',
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.of(dialogContext, rootNavigator: true).pop(),
          child: const Text('Close'),
        ),
        ElevatedButton(
          onPressed: () {
            launchUrlString(kBuyNowUrl);
            Navigator.of(dialogContext, rootNavigator: true).pop();
          },
          child: const Text('Upgrade to Pro'),
        ),
      ],
    ),
  );
}

Future<void> showFreeTierSessionLimitDialog(BuildContext context) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    useRootNavigator: true,
    builder: (dialogContext) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: Row(
        children: const [
          Icon(Icons.info_outline_rounded, color: Color(0xFF0A6BFF)),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Session Limit Reached',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
      content: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFF6F8FF),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Text(
          'Session Limit Reached. The Free license allows only 1 active connection at a time. '
          'Please upgrade to PRO to support multiple simultaneous sessions.',
          style: TextStyle(fontSize: 14.5, height: 1.35),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.of(dialogContext, rootNavigator: true).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            launchUrlString(kBuyNowUrl);
            Navigator.of(dialogContext, rootNavigator: true).pop();
          },
          child: const Text('Upgrade to PRO'),
        ),
      ],
    ),
  );
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
          'Your session was disconnected because unlicensed mode is limited to 30 minutes.\n\n'
          'To avoid disconnecting every 30 minutes, open the SeeDesktop website, activate a FREE '
          'lifetime license, then enter your FREE code here.\n\n'
          'Website: https://seedesktop.com',
        ),
        actions: [
          ElevatedButton(
            onPressed: () {
              launchUrlString(kBuyNowUrl);
            },
            child: const Text('Open seedesktop.com — Get FREE license'),
          ),
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
  bool _canConnect = false;

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
          _canConnect = true;
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
              'Upgrade to SeeDesktop Pro for uninterrupted remote access. Plans start at \$36/year.',
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
                        r'Starting at $36 / Year',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 24,
                          color: Color(0xFF0E9F6E),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Multi-year plans:\n'
                    ' - 5 years: 50% off\n'
                    ' - 10 years: 70% off',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFFB45309),
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Includes full managed-device and interactive-session benefits.',
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
                      _FeatureItem('Unlimited Concurrent Connections'),
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
              _canConnect
                  ? 'Countdown completed. Press Connect to continue.'
                  : 'Continuing in $_remainingSeconds seconds...',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _canConnect
                        ? () {
                            widget.onComplete();
                          }
                        : null,
                    child: const Text('Connect'),
                  ),
                ),
              ],
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
