import 'dart:async';
import 'dart:convert';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_hbb/utils/license_debug_log_stub.dart'
    if (dart.library.io) 'package:flutter_hbb/utils/license_debug_log_io.dart';

const String kLicenseServerBaseUrl = 'http://187.124.13.191';
const String kLicenseCheckEndpoint = '$kLicenseServerBaseUrl/check_license';
const String kLicenseStartSessionEndpoint =
    '$kLicenseServerBaseUrl/start_session';
const String kLicenseReleaseConnectionEndpoint =
    '$kLicenseServerBaseUrl/release_connection';
const String kLicenseGetActiveSessionsEndpoint =
    '$kLicenseServerBaseUrl/get_active_sessions';
const String kLicenseGetLicenseInfoEndpoint =
    '$kLicenseServerBaseUrl/get_license_info';
const String kLicenseHeartbeatEndpoint = '$kLicenseServerBaseUrl/heartbeat';
const String kLicenseCommunicationErrorMessage =
    'שגיאת תקשורת: לא ניתן להתחבר לשרת הרישיונות. בדוק את חיבור האינטרנט שלך.\n'
    'Communication error: Unable to connect to the license server. Check your internet connection.';

const String _kLegacySavedLicenseKey = 'saved_license';
const String _kPeerSessionMapKey = 'license_peer_sessions';
const String _kHardwareIdPrefsKey = 'license_hardware_id';
const String _kLicenseDebugLogFileName = 'seedesktop_license_debug.log';
const List<int> _kReconnectBackoffSeconds = [2, 5, 10, 30];

enum LicenseServerStatus {
  unknown,
  online,
  reconnecting,
}

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

class LicenseSessionResult {
  final bool approved;
  final bool limitReached;
  final String message;
  final String sessionId;
  final int allowedConnections;
  final int activeConnections;

  const LicenseSessionResult({
    required this.approved,
    required this.limitReached,
    required this.message,
    this.sessionId = '',
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

String maskLicense(String license) {
  if (license.length <= 4) return license;
  return '****${license.substring(license.length - 4)}';
}

int _toInt(dynamic value) {
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

Future<void> _appendLicenseDebugLog({
  required String endpoint,
  required String licenseKey,
  required String reason,
}) async {
  try {
    final line =
        '[${DateTime.now().toIso8601String()}] endpoint=$endpoint license_key=$licenseKey reason=$reason\n';
    await appendLicenseDebugLogLine(_kLicenseDebugLogFileName, line);
  } catch (_) {
    // Hidden diagnostics only.
  }
}

Future<String?> getSavedLicenseKey() async {
  final prefs = await SharedPreferences.getInstance();
  final key = prefs.getString(_kLegacySavedLicenseKey)?.trim();
  return (key == null || key.isEmpty) ? null : key;
}

Future<void> _setSavedLicenseKey(String licenseKey) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kLegacySavedLicenseKey, licenseKey);
}

Future<void> cacheHardwareId(String hardwareId) async {
  final hwid = hardwareId.trim();
  if (hwid.isEmpty) return;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kHardwareIdPrefsKey, hwid);
}

Future<Map<String, String>> _loadPeerSessionMap() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_kPeerSessionMapKey);
  if (raw == null || raw.trim().isEmpty) return <String, String>{};
  try {
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    return decoded.map((k, v) => MapEntry(k, v.toString()));
  } catch (_) {
    return <String, String>{};
  }
}

Future<void> _savePeerSessionMap(Map<String, String> value) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kPeerSessionMapKey, jsonEncode(value));
}

Future<String?> getSessionIdForPeer(String peerId) async {
  final map = await _loadPeerSessionMap();
  return map[peerId];
}

Future<int> getActiveLicenseSessionCount() async {
  final map = await _loadPeerSessionMap();
  return map.length;
}

List<ActiveLicenseSession> _parseSessions(dynamic raw) {
  final sessions = <ActiveLicenseSession>[];
  if (raw is! List) return sessions;
  for (final entry in raw) {
    if (entry is! Map) continue;
    final computerName = entry['computer_name']?.toString().trim() ??
        entry['target_pc']?.toString().trim() ??
        '';
    final ip = entry['ip']?.toString().trim() ??
        entry['remote_ip']?.toString().trim() ??
        '';
    sessions.add(
      ActiveLicenseSession(
        computerName: computerName.isEmpty ? 'Unknown computer' : computerName,
        ip: ip.isEmpty ? 'Unknown IP' : ip,
      ),
    );
  }
  return sessions;
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
    } catch (_) {}

    final serverMessage = payload['message']?.toString();
    final status = payload['status']?.toString().toLowerCase();
    final allowedConnections =
        _toInt(payload['allowed_connections']) > 0
            ? _toInt(payload['allowed_connections'])
            : _toInt(payload['max_connections']);
    final activeConnections = _toInt(payload['active_connections']);

    final approved = status == 'success' || status == 'valid';
    if (response.statusCode == 200 && approved) {
      return LicenseVerifyResult(
        approved: true,
        message: serverMessage ?? 'Approved',
        allowedConnections: allowedConnections,
        activeConnections: activeConnections,
      );
    }

    if (response.statusCode == 404) {
      await _appendLicenseDebugLog(
        endpoint: kLicenseCheckEndpoint,
        licenseKey: key,
        reason: 'HTTP 404 while calling check_license',
      );
    }

    return LicenseVerifyResult(
      approved: false,
      message:
          serverMessage ?? 'License verification failed (${response.statusCode}).',
      allowedConnections: allowedConnections,
      activeConnections: activeConnections,
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

Future<LicenseSessionResult> startSession(
  String licenseKey, {
  required String hardwareId,
  required String targetPc,
  String? peerId,
}) async {
  final key = licenseKey.trim();
  if (key.isEmpty) {
    return const LicenseSessionResult(
      approved: false,
      limitReached: false,
      message: 'License key is required.',
    );
  }
  final hwid = hardwareId.trim();
  if (hwid.isEmpty) {
    return const LicenseSessionResult(
      approved: false,
      limitReached: false,
      message: 'Hardware ID is required.',
    );
  }

  try {
    http.Response? response;
    Object? lastError;
    for (var i = 0; i <= _kReconnectBackoffSeconds.length; i++) {
      try {
        response = await http
            .post(
              Uri.parse(kLicenseStartSessionEndpoint),
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode({
                'license_key': key,
                'hardware_id': hwid,
                'target_pc': targetPc,
              }),
            )
            .timeout(const Duration(seconds: 10));
        lastError = null;
        break;
      } catch (e) {
        lastError = e;
        if (i >= _kReconnectBackoffSeconds.length) rethrow;
        await Future.delayed(Duration(seconds: _kReconnectBackoffSeconds[i]));
      }
    }
    if (lastError != null || response == null) {
      return const LicenseSessionResult(
        approved: false,
        limitReached: false,
        message: kLicenseCommunicationErrorMessage,
      );
    }

    Map<String, dynamic> payload = {};
    try {
      payload = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {}

    final status = payload['status']?.toString().toLowerCase();
    final message = payload['message']?.toString() ?? '';
    final sessionId = payload['session_id']?.toString().trim() ?? '';
    final allowedConnections =
        _toInt(payload['allowed_connections']) > 0
            ? _toInt(payload['allowed_connections'])
            : _toInt(payload['max_connections']);
    final activeConnections = _toInt(payload['active_connections']);

    final approved =
        response.statusCode == 200 && (status == 'success' || status == 'valid');
    if (approved) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kHardwareIdPrefsKey, hwid);
      if (sessionId.isNotEmpty) {
        await prefs.setString('session_id', sessionId);
        if (peerId != null && peerId.trim().isNotEmpty) {
          final map = await _loadPeerSessionMap();
          map[peerId] = sessionId;
          await _savePeerSessionMap(map);
        }
      }
      await LicenseHeartbeatManager.instance.start();
      return LicenseSessionResult(
        approved: true,
        limitReached: false,
        message: message.isEmpty ? 'Session started.' : message,
        sessionId: sessionId,
        allowedConnections: allowedConnections,
        activeConnections: activeConnections,
      );
    }

    if (response.statusCode == 403) {
      return LicenseSessionResult(
        approved: false,
        limitReached: true,
        message: message.isEmpty ? 'Connection limit reached.' : message,
        sessionId: sessionId,
        allowedConnections: allowedConnections,
        activeConnections: activeConnections,
      );
    }

    if (response.statusCode == 404) {
      await _appendLicenseDebugLog(
        endpoint: kLicenseStartSessionEndpoint,
        licenseKey: key,
        reason: 'HTTP 404 while calling start_session',
      );
    }

    return LicenseSessionResult(
      approved: false,
      limitReached: false,
      message: message.isEmpty
          ? 'Failed to start session (${response.statusCode}).'
          : message,
      sessionId: sessionId,
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

Future<LicenseSessionResult> startSessionFromPrefs({
  required String hardwareId,
  required String targetPc,
  String? peerId,
}) async {
  final license = await getSavedLicenseKey();
  if (license == null || license.trim().isEmpty) {
    return const LicenseSessionResult(
      approved: true,
      limitReached: false,
      message: 'No saved license.',
    );
  }
  return startSession(
    license,
    hardwareId: hardwareId,
    targetPc: targetPc,
    peerId: peerId,
  );
}

Future<ActiveSessionsResult> _fetchLicenseInfoAsActiveSessions(
    String key) async {
  final response = await http
      .post(
        Uri.parse(kLicenseGetLicenseInfoEndpoint),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({'license_key': key}),
      )
      .timeout(const Duration(seconds: 10));

  Map<String, dynamic> payload = {};
  try {
    payload = jsonDecode(response.body) as Map<String, dynamic>;
  } catch (_) {}

  if (response.statusCode == 404) {
    await _appendLicenseDebugLog(
      endpoint: kLicenseGetLicenseInfoEndpoint,
      licenseKey: key,
      reason: 'HTTP 404 while calling get_license_info',
    );
  }

  final status = payload['status']?.toString().toLowerCase();
  final message = payload['message']?.toString() ?? '';
  final sessions =
      _parseSessions(payload['sessions'] ?? payload['active_sessions']);
  final ok = response.statusCode == 200 &&
      (status == 'success' || status == 'valid' || payload.isNotEmpty);

  return ActiveSessionsResult(
    success: ok,
    message: ok
        ? (message.isEmpty
            ? 'Active sessions fetched from license info.'
            : message)
        : (message.isEmpty
            ? 'Failed to load license info (${response.statusCode}).'
            : message),
    sessions: sessions,
  );
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
    } catch (_) {}

    final status = payload['status']?.toString().toLowerCase();
    final message = payload['message']?.toString() ?? '';
    final sessions = _parseSessions(payload['sessions']);
    final isOkStatus = status == 'success' || status == 'valid';
    if (response.statusCode == 200 && (isOkStatus || payload.containsKey('sessions'))) {
      return ActiveSessionsResult(
        success: true,
        message: message.isEmpty ? 'Active sessions fetched.' : message,
        sessions: sessions,
      );
    }

    if (response.statusCode == 404) {
      await _appendLicenseDebugLog(
        endpoint: kLicenseGetActiveSessionsEndpoint,
        licenseKey: key,
        reason: 'HTTP 404 while calling get_active_sessions',
      );
      return _fetchLicenseInfoAsActiveSessions(key);
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
  final license = await getSavedLicenseKey();
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
  await _setSavedLicenseKey(licenseKey);
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
  await prefs.remove(_kLegacySavedLicenseKey);
  await prefs.remove('masked_license');
  await prefs.remove('session_id');
  await prefs.remove(_kHardwareIdPrefsKey);
  await prefs.remove(_kPeerSessionMapKey);
  await prefs.remove('allowed_connections');
  await prefs.remove('active_connections');
  await prefs.remove('max_connections');
}

Future<String?> sendLicenseHeartbeat({
  required String licenseKey,
  required String hardwareId,
}) async {
  final key = licenseKey.trim();
  final hwid = hardwareId.trim();
  if (key.isEmpty || hwid.isEmpty) return null;

  try {
    final response = await http
        .post(
          Uri.parse(kLicenseHeartbeatEndpoint),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'license_key': key,
            'hardware_id': hwid,
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return null;
    }
    if (response.statusCode == 404) {
      await _appendLicenseDebugLog(
        endpoint: kLicenseHeartbeatEndpoint,
        licenseKey: key,
        reason: 'HTTP 404 while calling heartbeat',
      );
    }
    return 'Heartbeat failed (${response.statusCode}).';
  } on TimeoutException {
    return kLicenseCommunicationErrorMessage;
  } catch (_) {
    return kLicenseCommunicationErrorMessage;
  }
}

class LicenseHeartbeatManager {
  LicenseHeartbeatManager._();
  static final LicenseHeartbeatManager instance = LicenseHeartbeatManager._();

  Timer? _timer;
  int _failedHeartbeats = 0;
  bool _shownLostServerNotice = false;
  final ValueNotifier<LicenseServerStatus> status =
      ValueNotifier<LicenseServerStatus>(LicenseServerStatus.unknown);

  Future<void> start() async {
    _timer ??= Timer.periodic(const Duration(seconds: 120), (_) {
      tick();
    });
    await tick();
  }

  Future<String?> _sendHeartbeatWithBackoff({
    required String licenseKey,
    required String hardwareId,
  }) async {
    String? lastErr;
    for (var i = 0; i <= _kReconnectBackoffSeconds.length; i++) {
      lastErr = await sendLicenseHeartbeat(
        licenseKey: licenseKey,
        hardwareId: hardwareId,
      );
      if (lastErr == null) return null;
      if (i >= _kReconnectBackoffSeconds.length) break;
      await Future.delayed(Duration(seconds: _kReconnectBackoffSeconds[i]));
    }
    return lastErr;
  }

  Future<void> tick() async {
    final license = await getSavedLicenseKey();
    final activeSessions = await getActiveLicenseSessionCount();
    final isLicensed = license != null && license.trim().isNotEmpty;
    if (!isLicensed && activeSessions <= 0) return;

    final prefs = await SharedPreferences.getInstance();
    final hardwareId = prefs.getString(_kHardwareIdPrefsKey)?.trim() ?? '';
    if (hardwareId.isEmpty || !isLicensed) {
      status.value = LicenseServerStatus.reconnecting;
      return;
    }

    final err = await _sendHeartbeatWithBackoff(
      licenseKey: license,
      hardwareId: hardwareId,
    );
    if (err == null) {
      _failedHeartbeats = 0;
      _shownLostServerNotice = false;
      status.value = LicenseServerStatus.online;
      return;
    }
    _failedHeartbeats += 1;
    status.value = LicenseServerStatus.reconnecting;
    if (_failedHeartbeats >= 3 && !_shownLostServerNotice) {
      _shownLostServerNotice = true;
      BotToast.showText(
        text:
            'Lost connection to the license server. Active seats may not be synchronized until connectivity is restored.',
      );
    }
  }
}

Future<String?> releaseConnectionBySessionId(String? sessionId) async {
  final sid = sessionId?.trim();
  if (sid == null || sid.isEmpty) return null;

  try {
    final response = await http
        .post(
          Uri.parse(kLicenseReleaseConnectionEndpoint),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'session_id': sid}),
        )
        .timeout(const Duration(seconds: 8));
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return null;
    }
    if (response.statusCode == 404) {
      await _appendLicenseDebugLog(
        endpoint: kLicenseReleaseConnectionEndpoint,
        licenseKey: 'session:$sid',
        reason: 'HTTP 404 while calling release_connection (session mode)',
      );
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

Future<String?> releaseConnectionForPeer(String peerId) async {
  final map = await _loadPeerSessionMap();
  final sessionId = map.remove(peerId);
  await _savePeerSessionMap(map);
  if (map.isEmpty) {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('session_id');
  }
  return releaseConnectionBySessionId(sessionId);
}

Future<String?> releaseConnection(String? licenseKey) async {
  final map = await _loadPeerSessionMap();
  if (map.isNotEmpty) {
    return releaseConnectionFromPrefs(force: true);
  }

  final key = licenseKey?.trim();
  if (key == null || key.isEmpty) return null;

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
    if (response.statusCode == 404) {
      await _appendLicenseDebugLog(
        endpoint: kLicenseReleaseConnectionEndpoint,
        licenseKey: key,
        reason: 'HTTP 404 while calling release_connection (license mode)',
      );
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
  final map = await _loadPeerSessionMap();
  if (map.isEmpty && !force) return null;

  String? firstError;
  for (final sessionId in map.values) {
    final err = await releaseConnectionBySessionId(sessionId);
    firstError ??= err;
  }
  await _savePeerSessionMap(<String, String>{});
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove('session_id');
  return firstError;
}
