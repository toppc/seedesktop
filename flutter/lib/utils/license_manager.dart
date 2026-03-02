import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const String kLicenseServerBaseUrl = 'http://187.124.13.191';
const String kLicenseCommunicationErrorMessage =
    'שגיאת תקשורת: לא ניתן להתחבר לשרת הרישיונות. בדוק את חיבור האינטרנט שלך.\n'
    'Communication error: Unable to connect to the license server. Check your internet connection.';

class LicenseVerifyResult {
  final bool approved;
  final String message;
  final int? maxConnections;

  const LicenseVerifyResult({
    required this.approved,
    required this.message,
    this.maxConnections,
  });
}

String maskLicense(String license) {
  if (license.length <= 4) {
    return license;
  }
  return '****${license.substring(license.length - 4)}';
}

Future<LicenseVerifyResult> verifyLicenseWithServer(String licenseKey) async {
  final key = licenseKey.trim();
  if (key.isEmpty) {
    return const LicenseVerifyResult(
      approved: false,
      message: 'License key is required.',
    );
  }

  try {
    final response = await http
        .post(
          Uri.parse('$kLicenseServerBaseUrl/verify_license'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'license_key': key}),
        )
        .timeout(const Duration(seconds: 10));

    Map<String, dynamic> payload = {};
    try {
      payload = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      payload = {};
    }

    final serverMessage = payload['message']?.toString();
    final maxConnections =
        int.tryParse(payload['max_connections']?.toString() ?? '');

    if (response.statusCode == 200 && payload['status']?.toString() == 'success') {
      return LicenseVerifyResult(
        approved: true,
        message: serverMessage ?? 'Approved',
        maxConnections: maxConnections,
      );
    }

    if (response.statusCode == 403 || response.statusCode == 404) {
      return LicenseVerifyResult(
        approved: false,
        message: serverMessage ?? 'License verification failed.',
      );
    }

    return LicenseVerifyResult(
      approved: false,
      message:
          serverMessage ?? 'License verification failed (${response.statusCode}).',
    );
  } on TimeoutException {
    return const LicenseVerifyResult(
      approved: false,
      message: kLicenseCommunicationErrorMessage,
    );
  } catch (_) {
    return const LicenseVerifyResult(
      approved: false,
      message: kLicenseCommunicationErrorMessage,
    );
  }
}

Future<void> saveLicenseToPrefs(
  String licenseKey, {
  int? maxConnections,
}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('saved_license', licenseKey);
  await prefs.setString('masked_license', maskLicense(licenseKey));
  if (maxConnections != null) {
    await prefs.setInt('max_connections', maxConnections);
  }
}

Future<void> clearLicensePrefs() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove('saved_license');
  await prefs.remove('masked_license');
  await prefs.remove('session_id');
  await prefs.remove('max_connections');
}

Future<String?> releaseConnectionByLicense(String? licenseKey) async {
  final key = licenseKey?.trim();
  if (key == null || key.isEmpty) {
    return null;
  }

  try {
    final response = await http
        .post(
          Uri.parse('$kLicenseServerBaseUrl/release_connection'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'license_key': key}),
        )
        .timeout(const Duration(seconds: 8));

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return null;
    }

    try {
      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      return payload['message']?.toString() ??
          'Failed to release connection (${response.statusCode}).';
    } catch (_) {
      return 'Failed to release connection (${response.statusCode}).';
    }
  } on TimeoutException {
    return kLicenseCommunicationErrorMessage;
  } catch (_) {
    return kLicenseCommunicationErrorMessage;
  }
}

Future<String?> releaseConnectionFromPrefs() async {
  final prefs = await SharedPreferences.getInstance();
  final license = prefs.getString('saved_license');
  return releaseConnectionByLicense(license);
}
