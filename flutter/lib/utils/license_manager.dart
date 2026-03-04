import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const String kLicenseServerBaseUrl = 'http://187.124.13.191';
const String kLicenseCheckEndpoint = '$kLicenseServerBaseUrl/check_license';
const String kLicenseStartSessionEndpoint =
    '$kLicenseServerBaseUrl/start_session';
const String kLicenseReleaseConnectionEndpoint =
    '$kLicenseServerBaseUrl/release_connection';
const String kLicenseGetActiveSessionsEndpoint =
    '$kLicenseServerBaseUrl/get_active_sessions';
const String kLicenseCommunicationErrorMessage =
    'שגיאת תקשורת: לא ניתן להתחבר לשרת הרישיונות. בדוק את חיבור האינטרנט שלך.\n'
    'Communication error: Unable to connect to the license server. Check your internet connection.';
const String _kStartedSessionsCounterKey = 'started_license_sessions';

class LicenseVerifyResult {
  final bool approved;
  final String message;
  final int allowedConnections;
  final int activeConnections;
  int get maxConnections => allowedConnections;

  const LicenseVerifyResult({
    required this.approved,
    required this.message,
    this.allowedConnections = 0,
    this.activeConnections = 0,
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
          Uri.parse(kLicenseCheckEndpoint),
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
    final status = payload['status']?.toString().toLowerCase();
    final allowedConnections =
        int.tryParse(payload['allowed_connections']?.toString() ?? '') ??
            int.tryParse(payload['max_connections']?.toString() ?? '') ??
            0;
    final activeConnections =
        int.tryParse(payload['active_connections']?.toString() ?? '') ?? 0;

    final approved = status == 'success' || status == 'valid';
    if (response.statusCode == 200 && approved) {
      return LicenseVerifyResult(
        approved: true,
        message: serverMessage ?? 'Approved',
        allowedConnections: allowedConnections,
        activeConnections: activeConnections,
      );
    }

    if (response.statusCode == 200 && status == 'invalid') {
      return LicenseVerifyResult(
        approved: false,
        message: serverMessage ?? 'License is invalid.',
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

class LicenseSessionResult {
  final bool approved;
  final bool limitReached;
  final String message;
  final int allowedConnections;
  final int activeConnections;

  const LicenseSessionResult({
    required this.approved,
    required this.limitReached,
    required this.message,
    this.allowedConnections = 0,
    this.activeConnections = 0,
  });
}

class ActiveLicenseSession {
  final String computerName;
  final String ip;

  const ActiveLicenseSession({
    required this.computerName,
    required this.ip,
  });
}

class ActiveSessionsResult {
  final bool success;
  final String message;
  final List<ActiveLicenseSession> sessions;

  const ActiveSessionsResult({
    required this.success,
    required this.message,
    this.sessions = const [],
  });
}

Future<void> _incStartedSessionsCounter() async {
  final prefs = await SharedPreferences.getInstance();
  final current = prefs.getInt(_kStartedSessionsCounterKey) ?? 0;
  await prefs.setInt(_kStartedSessionsCounterKey, current + 1);
}

Future<bool> _tryDecStartedSessionsCounter() async {
  final prefs = await SharedPreferences.getInstance();
  final current = prefs.getInt(_kStartedSessionsCounterKey) ?? 0;
  if (current <= 0) {
    return false;
  }
  await prefs.setInt(_kStartedSessionsCounterKey, current - 1);
  return true;
}

Future<LicenseSessionResult> startSession(String licenseKey) async {
  final key = licenseKey.trim();
  if (key.isEmpty) {
    return const LicenseSessionResult(
      approved: false,
      limitReached: false,
      message: 'License key is required.',
    );
  }

  try {
    final response = await http
        .post(
          Uri.parse(kLicenseStartSessionEndpoint),
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

    final status = payload['status']?.toString().toLowerCase();
    final message = payload['message']?.toString() ?? '';
    final allowedConnections =
        int.tryParse(payload['allowed_connections']?.toString() ?? '') ??
            int.tryParse(payload['max_connections']?.toString() ?? '') ??
            0;
    final activeConnections =
        int.tryParse(payload['active_connections']?.toString() ?? '') ?? 0;

    final approved = response.statusCode == 200 &&
        (status == 'success' || status == 'valid');
    if (approved) {
      await _incStartedSessionsCounter();
      return LicenseSessionResult(
        approved: true,
        limitReached: false,
        message: message.isEmpty ? 'Session started.' : message,
        allowedConnections: allowedConnections,
        activeConnections: activeConnections,
      );
    }

    if (response.statusCode == 403) {
      return LicenseSessionResult(
        approved: false,
        limitReached: true,
        message: message.isEmpty ? 'Connection limit reached.' : message,
        allowedConnections: allowedConnections,
        activeConnections: activeConnections,
      );
    }

    return LicenseSessionResult(
      approved: false,
      limitReached: false,
      message: message.isEmpty
          ? 'Failed to start session (${response.statusCode}).'
          : message,
      allowedConnections: allowedConnections,
      activeConnections: activeConnections,
    );
  } on TimeoutException {
    return const LicenseSessionResult(
      approved: false,
      limitReached: false,
      message: kLicenseCommunicationErrorMessage,
    );
  } catch (_) {
    return const LicenseSessionResult(
      approved: false,
      limitReached: false,
      message: kLicenseCommunicationErrorMessage,
    );
  }
}

Future<LicenseSessionResult> startSessionFromPrefs() async {
  final prefs = await SharedPreferences.getInstance();
  final license = prefs.getString('saved_license');
  if (license == null || license.trim().isEmpty) {
    return const LicenseSessionResult(
      approved: true,
      limitReached: false,
      message: 'No saved license.',
    );
  }
  return startSession(license);
}

Future<ActiveSessionsResult> fetchActiveSessions(String licenseKey) async {
  final key = licenseKey.trim();
  if (key.isEmpty) {
    return const ActiveSessionsResult(
      success: false,
      message: 'License key is required.',
    );
  }

  try {
    final response = await http
        .post(
          Uri.parse(kLicenseGetActiveSessionsEndpoint),
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

    final status = payload['status']?.toString().toLowerCase();
    final message = payload['message']?.toString() ?? '';
    final sessionsRaw = payload['sessions'];

    final sessions = <ActiveLicenseSession>[];
    if (sessionsRaw is List) {
      for (final entry in sessionsRaw) {
        if (entry is Map) {
          final computerName = entry['computer_name']?.toString().trim() ?? '';
          final ip = entry['ip']?.toString().trim() ?? '';
          sessions.add(
            ActiveLicenseSession(
              computerName:
                  computerName.isEmpty ? 'Unknown computer' : computerName,
              ip: ip.isEmpty ? 'Unknown IP' : ip,
            ),
          );
        }
      }
    }

    final isOkStatus = status == 'success' || status == 'valid';
    if (response.statusCode == 200 && (isOkStatus || payload.containsKey('sessions'))) {
      return ActiveSessionsResult(
        success: true,
        message: message.isEmpty ? 'Active sessions fetched.' : message,
        sessions: sessions,
      );
    }

    return ActiveSessionsResult(
      success: false,
      message: message.isEmpty
          ? 'Failed to load active sessions (${response.statusCode}).'
          : message,
      sessions: sessions,
    );
  } on TimeoutException {
    return const ActiveSessionsResult(
      success: false,
      message: kLicenseCommunicationErrorMessage,
    );
  } catch (_) {
    return const ActiveSessionsResult(
      success: false,
      message: kLicenseCommunicationErrorMessage,
    );
  }
}

Future<ActiveSessionsResult> fetchActiveSessionsFromPrefs() async {
  final prefs = await SharedPreferences.getInstance();
  final license = prefs.getString('saved_license');
  if (license == null || license.trim().isEmpty) {
    return const ActiveSessionsResult(
      success: false,
      message: 'No saved license.',
    );
  }
  return fetchActiveSessions(license);
}

Future<void> saveLicenseToPrefs(
  String licenseKey, {
  int? allowedConnections,
  int? activeConnections,
  int? maxConnections,
}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('saved_license', licenseKey);
  await prefs.setString('masked_license', maskLicense(licenseKey));
  final effectiveAllowed = allowedConnections ?? maxConnections;
  if (effectiveAllowed != null) {
    await prefs.setInt('allowed_connections', effectiveAllowed);
    await prefs.setInt('max_connections', effectiveAllowed);
  }
  if (activeConnections != null) {
    await prefs.setInt('active_connections', activeConnections);
  }
}

Future<void> clearLicensePrefs() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove('saved_license');
  await prefs.remove('masked_license');
  await prefs.remove('session_id');
  await prefs.remove('allowed_connections');
  await prefs.remove('active_connections');
  await prefs.remove('max_connections');
  await prefs.remove(_kStartedSessionsCounterKey);
}

Future<String?> releaseConnection(String? licenseKey) async {
  final key = licenseKey?.trim();
  if (key == null || key.isEmpty) {
    return null;
  }

  try {
    final response = await http
        .post(
          Uri.parse(kLicenseReleaseConnectionEndpoint),
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

Future<String?> releaseConnectionByLicense(String? licenseKey) async {
  return releaseConnection(licenseKey);
}

Future<String?> releaseConnectionFromPrefs({bool force = false}) async {
  final shouldRelease = force || await _tryDecStartedSessionsCounter();
  if (!shouldRelease) {
    return null;
  }
  final prefs = await SharedPreferences.getInstance();
  final license = prefs.getString('saved_license');
  return releaseConnection(license);
}
