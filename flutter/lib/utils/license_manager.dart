import 'dart:async';
import 'dart:convert';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/utils/license_debug_log_stub.dart'
    if (dart.library.io) 'package:flutter_hbb/utils/license_debug_log_io.dart';

const String kLicenseServerBaseUrl = 'https://api.seedesktop.com/api';
const String kLicenseCheckEndpoint = '$kLicenseServerBaseUrl/check_license';
const String kLicenseStartSessionEndpoint =
    '$kLicenseServerBaseUrl/start_session';
const String kLicenseReleaseConnectionEndpoint =
    '$kLicenseServerBaseUrl/release_connection';
const String kLicenseReleaseAllMySessionsEndpoint =
    '$kLicenseServerBaseUrl/release_all_my_sessions';
const String kLicenseGetActiveSessionsEndpoint =
    '$kLicenseServerBaseUrl/get_active_sessions';
const String kLicenseGetLicenseInfoEndpoint =
    '$kLicenseServerBaseUrl/get_license_info';
const String kLicenseHeartbeatEndpoint = '$kLicenseServerBaseUrl/heartbeat';
const String kLicenseCommunicationErrorMessage =
    'Communication error: Unable to connect to the license server. Check your internet connection.';
const String kLicenseExpiryIsoPrefsKey = 'license_expiry_iso_utc';
const String kLicenseIsExpiredPrefsKey = 'license_is_expired';
const String kLicenseGraceStartMsPrefsKey = 'license_grace_start_ms';
const String kLicenseGraceReasonPrefsKey = 'license_grace_reason';
const int kLicenseGracePeriodMs = 36 * 60 * 60 * 1000;

const String _kLegacySavedLicenseKey = 'saved_license';
const String _kPeerSessionMapKey = 'license_peer_sessions';
const String _kHardwareIdPrefsKey = 'license_hardware_id';
const String _kLicenseDebugLogFileName = 'seedesktop_license_debug.log';
const List<int> _kReconnectBackoffSeconds = [2, 5, 10, 30];
const String _kForcedLicenseApiHost = 'api.seedesktop.com';
const String _kForcedRendezvousHost = 'api.seedesktop.com';
bool _startupSessionCleanupTriggered = false;
const Set<String> _kLicenseEndpointNames = <String>{
  'check_license',
  'start_session',
  'release_connection',
  'release_all_my_sessions',
  'get_active_sessions',
  'get_license_info',
  'heartbeat',
};

String _trimTrailingSlashes(String input) {
  var value = input.trim();
  while (value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

Future<Uri> _licenseUriFromDefault(String defaultEndpoint) async {
  final fallback = Uri.parse(defaultEndpoint);
  try {
    final configuredApiServer =
        _trimTrailingSlashes(await bind.mainGetApiServer());
    if (configuredApiServer.isEmpty) return fallback;
    final configuredUri = Uri.tryParse(configuredApiServer);
    if (configuredUri == null || configuredUri.host.trim().isEmpty) {
      return fallback;
    }
    final host = configuredUri.host.toLowerCase();
    if (host == 'localhost' ||
        host == '127.0.0.1' ||
        host == '0.0.0.0' ||
        host == '::1') {
      // Never use localhost for mobile license checks.
      return fallback;
    }

    // Production VPS requires HTTPS for the license API.
    final normalizedHost = (host == _kForcedRendezvousHost ||
            host == '77.42.68.134')
        ? _kForcedLicenseApiHost
        : configuredUri.host;
    final scheme = 'https';
    final port = configuredUri.hasPort ? configuredUri.port : 0;

    final baseSegments = configuredUri.pathSegments
        .where((segment) => segment.trim().isNotEmpty)
        .toList();
    if (baseSegments.isNotEmpty &&
        _kLicenseEndpointNames.contains(baseSegments.last.toLowerCase())) {
      baseSegments.removeLast();
    }
    if (!baseSegments.any((segment) => segment.toLowerCase() == 'api')) {
      baseSegments.add('api');
    }

    final endpointPath =
        fallback.pathSegments.isEmpty ? '' : fallback.pathSegments.last;
    if (endpointPath.isNotEmpty) {
      baseSegments.add(endpointPath);
    }

    return Uri(
      scheme: scheme,
      host: normalizedHost,
      port: port,
      pathSegments: baseSegments,
    );
  } catch (_) {
    return fallback;
  }
}

enum LicenseServerStatus {
  unknown,
  online,
  reconnecting,
}

class LicenseManager {
  LicenseManager._();
  static final LicenseManager instance = LicenseManager._();

  String get serverUrl => kLicenseServerBaseUrl;

  Future<String> _getCurrentLicenseKey() async {
    return (await getSavedLicenseKey())?.trim() ?? '';
  }

  Future<String> _getCurrentHardwareId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kHardwareIdPrefsKey)?.trim() ?? '';
  }

  Future<String> _getCurrentLocalComputerName() async {
    return 'Local Station';
  }

  Future<void> trackSessionLocallyByKey(String key, String sessionId) async {
    await _trackSessionLocally(key, sessionId);
  }

  // 1) Fetch exact counters for license status UI.
  Future<Map<String, dynamic>> getActiveSessionsInfo() async {
    try {
      final currentLicenseKey = await _getCurrentLicenseKey();
      final currentHardwareId = await _getCurrentHardwareId();
      if (currentHardwareId.isEmpty) {
        return {'success': false};
      }
      final endpointUri =
          await _licenseUriFromDefault(kLicenseGetActiveSessionsEndpoint);
      final response = await http.post(
        endpointUri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'license_key': currentLicenseKey}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        int totalSeats = data['allowed_connections'] ?? 0;
        int activeStations = data['active_stations'] ?? 0;
        List sessions = data['sessions'] ?? [];

        // Count sessions that belong to this local hardware ID.
        int myActiveConnections =
            sessions.where((s) => s['hardware_id'] == currentHardwareId).length;

        return {
          'success': true,
          'totalSeats': totalSeats,
          'activeStations': activeStations,
          'myConnections': myActiveConnections,
        };
      }
      return {'success': false};
    } catch (e) {
      return {'success': false};
    }
  }

  // 2) Start session with accurate target metadata.
  Future<String?> startSession(String targetPcName) async {
    try {
      final currentLicenseKey = await _getCurrentLicenseKey();
      final currentHardwareId = await _getCurrentHardwareId();
      final currentLocalComputerName = await _getCurrentLocalComputerName();
      if (currentHardwareId.isEmpty) {
        return null;
      }
      final endpointUri =
          await _licenseUriFromDefault(kLicenseStartSessionEndpoint);
      final response = await http.post(
        endpointUri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'license_key': currentLicenseKey,
          'hardware_id': currentHardwareId,
          'computer_name': currentLocalComputerName,
          'target_pc': targetPcName,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final sessionId = data['session_id']?.toString() ?? '';
        if (sessionId.isNotEmpty) {
          await _trackSessionLocally(targetPcName, sessionId);
          await LicenseHeartbeatManager.instance.start();
        }
        return sessionId.isEmpty ? null : sessionId;
      } else if (response.statusCode == 403) {
        throw Exception('Seat Limit Reached');
      }
      return null;
    } catch (e) {
      rethrow;
    }
  }

  // 3) Release one specific session (fire-and-forget).
  void releaseConnection(String sessionId) {
    unawaited(() async {
      try {
        final err = await releaseConnectionBySessionId(sessionId);
        final notFound = (err ?? '').toLowerCase().contains('not found');
        if (err == null || notFound) {
          await _untrackSessionLocally(sessionId);
        } else if (kDebugMode) {
          debugPrint('Release error: $err');
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Release error: $e');
        }
      }
    }());
  }

  // 4) Startup cleanup for orphan sessions.
  void releaseAllMyOrphanSessions() {
    unawaited(Future.wait([
      _getCurrentLicenseKey(),
      _getCurrentHardwareId(),
    ]).then((values) async {
      final currentLicenseKey = values[0];
      final currentHardwareId = values[1];
      if (currentHardwareId.isEmpty) return;
      try {
        final endpointUri =
            await _licenseUriFromDefault(kLicenseReleaseAllMySessionsEndpoint);
        final response = await http.post(
          endpointUri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'license_key': currentLicenseKey,
            'hardware_id': currentHardwareId,
          }),
        );
        if (response.statusCode >= 200 && response.statusCode < 300) {
          await _savePeerSessionMap(<String, List<String>>{});
          final prefs = await SharedPreferences.getInstance();
          await prefs.remove('session_id');
          await prefs.setInt('active_connections', 0);
        }
      } catch (e) {
        debugPrint('Cleanup error: $e');
      }
    }));
  }
}

class LicenseVerifyResult {
  final bool approved;
  final bool isExpired;
  final String message;
  final int allowedConnections;
  final int activeConnections;
  final String expiryDateIsoUtc;
  int get maxConnections => allowedConnections;

  const LicenseVerifyResult({
    required this.approved,
    this.isExpired = false,
    required this.message,
    this.allowedConnections = 0,
    this.activeConnections = 0,
    this.expiryDateIsoUtc = '',
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
  final String hardwareId;

  const ActiveLicenseSession({
    required this.computerName,
    required this.ip,
    this.hardwareId = '',
  });
}

class ActiveSessionsResult {
  final bool success;
  final String message;
  final List<ActiveLicenseSession> sessions;
  final int totalSeats;
  final int occupiedSeats;
  final int myActiveConnections;

  const ActiveSessionsResult({
    required this.success,
    required this.message,
    this.sessions = const [],
    this.totalSeats = 0,
    this.occupiedSeats = 0,
    this.myActiveConnections = 0,
  });
}

String _maskLicenseLastFour(String normalized) {
  final alnum = normalized.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
  if (alnum.isEmpty) return '????';
  final tail = alnum.length >= 4
      ? alnum.substring(alnum.length - 4)
      : alnum.padLeft(4, '0');
  return tail.toUpperCase();
}

/// SD-FREE-XXXX / SD-PRO-XXXX (last four alphanumeric chars of the key body).
String maskLicense(String license) {
  final normalized = license.trim();
  final upper = normalized.toUpperCase();
  if (upper.startsWith('SD-FREE-')) {
    final body = normalized.length > 'SD-FREE-'.length
        ? normalized.substring('SD-FREE-'.length)
        : '';
    return 'SD-FREE-${_maskLicenseLastFour(body)}';
  }
  if (upper.startsWith('SD-')) {
    return 'SD-PRO-${_maskLicenseLastFour(normalized)}';
  }
  if (normalized.length <= 4) return normalized;
  return 'SD-PRO-${_maskLicenseLastFour(normalized)}';
}

int _toInt(dynamic value) {
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

const Map<String, int> _kMonthNameToNumber = <String, int>{
  'jan': 1,
  'january': 1,
  'feb': 2,
  'february': 2,
  'mar': 3,
  'march': 3,
  'apr': 4,
  'april': 4,
  'may': 5,
  'jun': 6,
  'june': 6,
  'jul': 7,
  'july': 7,
  'aug': 8,
  'august': 8,
  'sep': 9,
  'sept': 9,
  'september': 9,
  'oct': 10,
  'october': 10,
  'nov': 11,
  'november': 11,
  'dec': 12,
  'december': 12,
};

DateTime? _parseHumanReadableExpiryAsLocal(String rawValue) {
  final value = rawValue.trim();
  final m = RegExp(
    r'^([A-Za-z]{3,9})\s+(\d{1,2}),?\s*(\d{4})(?:\s+(\d{1,2})(?::(\d{1,2})(?::(\d{1,2}))?)?)?$',
  ).firstMatch(value);
  if (m == null) return null;
  final monthName = (m.group(1) ?? '').toLowerCase();
  final month = _kMonthNameToNumber[monthName];
  final day = int.tryParse(m.group(2) ?? '');
  final year = int.tryParse(m.group(3) ?? '');
  if (month == null || day == null || year == null) return null;
  final hour = int.tryParse(m.group(4) ?? '') ?? 23;
  final minute = int.tryParse(m.group(5) ?? '') ?? 59;
  final second = int.tryParse(m.group(6) ?? '') ?? 59;
  try {
    return DateTime(year, month, day, hour, minute, second);
  } catch (_) {
    return null;
  }
}

DateTime? _parseFlexibleExpiryAsLocal(String rawValue, {bool logOnFailure = false}) {
  var value = rawValue.trim();
  if (value.isEmpty) return null;
  if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    value = '${value}T23:59:59';
  }
  if (value.contains(' ') && !value.contains('T')) {
    value = value.replaceFirst(' ', 'T');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed != null) {
    return parsed.isUtc ? parsed.toLocal() : parsed;
  }
  final human = _parseHumanReadableExpiryAsLocal(rawValue);
  if (human != null) {
    return human;
  }
  if (logOnFailure && kDebugMode) {
    debugPrint('[License] Failed to parse expiry_date: "$rawValue"');
  }
  return null;
}

String _normalizeExpiryIsoUtc(String rawValue) {
  final parsed = _parseFlexibleExpiryAsLocal(rawValue, logOnFailure: true);
  if (parsed == null) return '';
  return parsed.toUtc().toIso8601String();
}

DateTime? _parseExpiryAsLocal(String rawValue) {
  return _parseFlexibleExpiryAsLocal(rawValue);
}

bool _isExpiredByDate(String expiryIsoUtc) {
  final expiry = _parseExpiryAsLocal(expiryIsoUtc);
  if (expiry == null) return false;
  return DateTime.now().isAfter(expiry);
}

bool _isExpiredFromServerData({
  required String expiryIsoUtc,
  String? status,
  String? message,
}) {
  // Renewal date wins over textual status.
  // If server provides a valid expiry date and it is in the future, license is active.
  if (expiryIsoUtc.trim().isNotEmpty) {
    return _isExpiredByDate(expiryIsoUtc);
  }
  return _isExpiredMessage(status, message);
}

bool _isExpiredMessage(String? status, String? message) {
  final statusText = (status ?? '').trim().toLowerCase();
  final messageText = (message ?? '').trim().toLowerCase();
  return statusText == 'expired' ||
      messageText == 'license expired' ||
      messageText.contains('expired');
}

bool _isLicenseMissingMessage(String? status, String? message) {
  final statusText = (status ?? '').trim().toLowerCase();
  final messageText = (message ?? '').trim().toLowerCase();
  return statusText == 'not_found' ||
      statusText == 'license_not_found' ||
      statusText == 'missing' ||
      messageText == 'license not found' ||
      messageText.contains('license not found') ||
      messageText.contains('not found');
}

bool _shouldEnterGraceMode({
  required String status,
  required String message,
  required int totalSeats,
  required int occupiedSeats,
  required int myActiveConnections,
}) {
  final missing = _isLicenseMissingMessage(status, message);
  if (!missing) return false;
  return totalSeats == 0 && occupiedSeats == 0 && myActiveConnections == 0;
}

Future<void> clearLicenseGraceMode() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(kLicenseGraceStartMsPrefsKey);
  await prefs.remove(kLicenseGraceReasonPrefsKey);
}

Future<void> markLicenseGraceMode(String reason) async {
  final prefs = await SharedPreferences.getInstance();
  final existing = prefs.getInt(kLicenseGraceStartMsPrefsKey) ?? 0;
  if (existing <= 0) {
    await prefs.setInt(
      kLicenseGraceStartMsPrefsKey,
      DateTime.now().millisecondsSinceEpoch,
    );
  }
  await prefs.setString(kLicenseGraceReasonPrefsKey, reason);
  // Grace mode should behave like free mode, not expired mode.
  await prefs.setBool(kLicenseIsExpiredPrefsKey, false);
}

Future<bool> isLicenseInGraceMode() async {
  final prefs = await SharedPreferences.getInstance();
  final startMs = prefs.getInt(kLicenseGraceStartMsPrefsKey) ?? 0;
  if (startMs <= 0) return false;
  final elapsed = DateTime.now().millisecondsSinceEpoch - startMs;
  return elapsed < kLicenseGracePeriodMs;
}

Future<int?> getLicenseGraceRemainingMs() async {
  final prefs = await SharedPreferences.getInstance();
  final startMs = prefs.getInt(kLicenseGraceStartMsPrefsKey) ?? 0;
  if (startMs <= 0) return null;
  final elapsed = DateTime.now().millisecondsSinceEpoch - startMs;
  final remaining = kLicenseGracePeriodMs - elapsed;
  return remaining > 0 ? remaining : 0;
}

String _extractExpiryIsoUtc(Map<String, dynamic> payload) {
  const keys = <String>[
    'expiry_date',
    'expires_at',
    'valid_until',
    'expiry',
    'expiration_date',
  ];
  for (final key in keys) {
    final value = payload[key]?.toString() ?? '';
    final normalized = _normalizeExpiryIsoUtc(value);
    if (normalized.isNotEmpty) return normalized;
  }
  return '';
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

Future<String?> releaseAllMySessionsByHardwareId(String hardwareId) async {
  final hwid = hardwareId.trim();
  if (hwid.isEmpty) return null;
  try {
    final key = (await getSavedLicenseKey())?.trim() ?? '';
    final body = <String, dynamic>{
      'hardware_id': hwid,
      'license_key': key,
    };
    final endpointUri =
        await _licenseUriFromDefault(kLicenseReleaseAllMySessionsEndpoint);
    final response = await http
        .post(
          endpointUri,
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 8));
    if (response.statusCode >= 200 && response.statusCode < 300) {
      try {
        final payload = jsonDecode(response.body) as Map<String, dynamic>;
        final releasedCount = _toInt(payload['released_count']);
        if (payload.containsKey('released_count') && releasedCount <= 0) {
          return payload['message']?.toString() ?? 'Session not found.';
        }
      } catch (_) {
        // Backward compatible with older server responses that return 2xx without JSON.
      }
      return null;
    }
    if (response.statusCode == 404) {
      await _appendLicenseDebugLog(
        endpoint: endpointUri.toString(),
        licenseKey: 'hardware:$hwid',
        reason: 'HTTP 404 while calling release_all_my_sessions',
      );
    }
    try {
      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      return payload['message']?.toString() ??
          'Failed to release all sessions (${response.statusCode}).';
    } catch (_) {
      return 'Failed to release all sessions (${response.statusCode}).';
    }
  } on TimeoutException {
    return kLicenseCommunicationErrorMessage;
  } catch (_) {
    return kLicenseCommunicationErrorMessage;
  }
}

Future<void> performStartupSessionCleanup({
  required String hardwareId,
}) async {
  if (_startupSessionCleanupTriggered) return;
  _startupSessionCleanupTriggered = true;
  final hwid = hardwareId.trim();
  if (hwid.isEmpty) return;

  // Remove any stale local mapping from previous unclean shutdowns.
  await _savePeerSessionMap(<String, List<String>>{});
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove('session_id');
  await prefs.setInt('active_connections', 0);

  final error = await releaseAllMySessionsByHardwareId(hwid);
  if (error != null && kDebugMode) {
    debugPrint('[License] Startup cleanup failed: $error');
  }
}

Future<Map<String, List<String>>> _loadPeerSessionMap() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_kPeerSessionMapKey);
  if (raw == null || raw.trim().isEmpty) return <String, List<String>>{};
  try {
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final result = <String, List<String>>{};
    decoded.forEach((k, v) {
      if (v is List) {
        result[k] = v
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList();
      } else {
        // Backward compatibility with old storage shape: { peerId: sessionId }
        final sid = v.toString().trim();
        result[k] = sid.isEmpty ? <String>[] : <String>[sid];
      }
    });
    return result;
  } catch (_) {
    return <String, List<String>>{};
  }
}

Future<void> _savePeerSessionMap(Map<String, List<String>> value) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kPeerSessionMapKey, jsonEncode(value));
}

Future<void> _trackSessionLocally(String key, String sessionId) async {
  final normalizedKey = key.trim();
  final sid = sessionId.trim();
  if (normalizedKey.isEmpty || sid.isEmpty) return;
  final map = await _loadPeerSessionMap();
  final sessions = map[normalizedKey] ?? <String>[];
  if (!sessions.contains(sid)) {
    sessions.add(sid);
  }
  map[normalizedKey] = sessions;
  await _savePeerSessionMap(map);
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('session_id', sid);
}

Future<void> _untrackSessionLocally(String sessionId) async {
  final sid = sessionId.trim();
  if (sid.isEmpty) return;
  final map = await _loadPeerSessionMap();
  _removeSessionIdFromMap(map, sid);
  await _savePeerSessionMap(map);
  final prefs = await SharedPreferences.getInstance();
  if (map.isEmpty) {
    await prefs.remove('session_id');
    await prefs.setInt('active_connections', 0);
  }
}

Future<String?> getSessionIdForPeer(String peerId) async {
  final map = await _loadPeerSessionMap();
  final sessions = map[peerId];
  if (sessions == null || sessions.isEmpty) return null;
  return sessions.last;
}

Future<int> getActiveLicenseSessionCount() async {
  final map = await _loadPeerSessionMap();
  return map.values.fold<int>(0, (sum, sessions) => sum + sessions.length);
}

Future<List<String>> getLocalLicenseSessionIds() async {
  final map = await _loadPeerSessionMap();
  final ids = <String>[];
  for (final sessions in map.values) {
    ids.addAll(sessions.where((s) => s.trim().isNotEmpty));
  }
  return ids;
}

void _removeSessionIdFromMap(Map<String, List<String>> map, String sessionId) {
  final sid = sessionId.trim();
  if (sid.isEmpty) return;
  final keysToRemove = <String>[];
  for (final entry in map.entries) {
    final updated = entry.value.where((s) => s != sid).toList();
    if (updated.isEmpty) {
      keysToRemove.add(entry.key);
    } else {
      map[entry.key] = updated;
    }
  }
  for (final key in keysToRemove) {
    map.remove(key);
  }
}

List<ActiveLicenseSession> _parseSessions(dynamic raw) {
  final sessions = <ActiveLicenseSession>[];
  if (raw is! List) return sessions;
  for (final entry in raw) {
    if (entry is! Map) continue;
    // Prefer target_pc so the list shows the remote target name/ID.
    final rawComputerName = entry['target_pc']?.toString().trim() ??
        entry['computer_name']?.toString().trim() ??
        '';
    final ip = entry['ip']?.toString().trim() ??
        entry['remote_ip']?.toString().trim() ??
        '';
    final hardwareId = entry['hardware_id']?.toString().trim() ?? '';
    final computerName = _normalizeComputerName(rawComputerName, entry);
    sessions.add(
      ActiveLicenseSession(
        computerName: computerName,
        ip: ip.isEmpty ? 'Unknown IP' : ip,
        hardwareId: hardwareId,
      ),
    );
  }
  return sessions;
}

String _normalizeComputerName(String rawName, Map entry) {
  final raw = rawName.trim();
  if (raw.isEmpty) return 'Unknown computer';
  if (!raw.startsWith('{')) return raw;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      final peerId = decoded['id']?.toString().trim() ?? '';
      String hostname = '';
      final info = decoded['info'];
      if (info is Map<String, dynamic>) {
        hostname = info['hostname']?.toString().trim() ?? '';
      }
      if (hostname.isNotEmpty && peerId.isNotEmpty) {
        return '$hostname ($peerId)';
      }
      if (hostname.isNotEmpty) return hostname;
      if (peerId.isNotEmpty) return peerId;
    }
  } catch (_) {
    // Fall back to other known fields.
  }
  final fallbackId = entry['id']?.toString().trim() ?? '';
  if (fallbackId.isNotEmpty) return fallbackId;
  return 'Unknown computer';
}

int _extractTotalSeats(Map<String, dynamic> payload) {
  if (payload.containsKey('allowed_connections')) {
    return _toInt(payload['allowed_connections']);
  }
  return _toInt(payload['max_connections']);
}

int _extractOccupiedSeats(Map<String, dynamic> payload) {
  if (payload.containsKey('active_stations')) {
    return _toInt(payload['active_stations']);
  }
  return _toInt(payload['active_connections']);
}

int _countMyActiveConnections(
  List<ActiveLicenseSession> sessions,
  String localHardwareId,
) {
  final hwid = localHardwareId.trim();
  if (hwid.isEmpty) return 0;
  return sessions.where((s) => s.hardwareId == hwid).length;
}

Future<String> _getLocalHardwareId() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(_kHardwareIdPrefsKey)?.trim() ?? '';
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
    final endpointUri = await _licenseUriFromDefault(kLicenseCheckEndpoint);
    final response = await http
        .post(
          endpointUri,
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
    final expiryDateIsoUtc = _extractExpiryIsoUtc(payload);
    final allowedConnections = _toInt(payload['allowed_connections']) > 0
        ? _toInt(payload['allowed_connections'])
        : _toInt(payload['max_connections']);
    final activeConnections = _toInt(payload['active_connections']);

    final approvedStatus = status == 'success' || status == 'valid';
    final isExpired = _isExpiredFromServerData(
      expiryIsoUtc: expiryDateIsoUtc,
      status: status,
      message: serverMessage,
    );
    final hasExpiry = expiryDateIsoUtc.trim().isNotEmpty;
    final approved = hasExpiry ? !isExpired : (approvedStatus && !isExpired);
    if (response.statusCode == 200 && approved) {
      return LicenseVerifyResult(
        approved: true,
        isExpired: false,
        message: serverMessage ?? 'Approved',
        allowedConnections: allowedConnections,
        activeConnections: activeConnections,
        expiryDateIsoUtc: expiryDateIsoUtc,
      );
    }

    if (response.statusCode == 404) {
      await _appendLicenseDebugLog(
        endpoint: endpointUri.toString(),
        licenseKey: key,
        reason: 'HTTP 404 while calling check_license',
      );
    }

    return LicenseVerifyResult(
      approved: false,
      isExpired: isExpired,
      message: isExpired
          ? (serverMessage ?? 'License expired')
          : (serverMessage ?? 'License verification failed (${response.statusCode}).'),
      allowedConnections: allowedConnections,
      activeConnections: activeConnections,
      expiryDateIsoUtc: expiryDateIsoUtc,
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
    final endpointUri =
        await _licenseUriFromDefault(kLicenseStartSessionEndpoint);
    for (var i = 0; i <= _kReconnectBackoffSeconds.length; i++) {
      try {
        response = await http
            .post(
              endpointUri,
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode({
                'license_key': key,
                'hardware_id': hwid,
                // Keep compatibility with backends that render computer_name.
                'computer_name': 'Local Station',
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
    final allowedConnections = _toInt(payload['allowed_connections']) > 0
        ? _toInt(payload['allowed_connections'])
        : _toInt(payload['max_connections']);
    final activeConnections = _toInt(payload['active_connections']);

    final approved = response.statusCode == 200 &&
        (status == 'success' ||
            status == 'valid' ||
            sessionId.isNotEmpty);
    if (approved) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kHardwareIdPrefsKey, hwid);
      if (sessionId.isNotEmpty) {
        await prefs.setString('session_id', sessionId);
        if (peerId != null && peerId.trim().isNotEmpty) {
          final map = await _loadPeerSessionMap();
          final sessions = map[peerId] ?? <String>[];
          if (!sessions.contains(sessionId)) {
            sessions.add(sessionId);
          }
          map[peerId] = sessions;
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
        endpoint: endpointUri.toString(),
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
  final licenseStr = license?.trim() ?? '';
  return startSession(
    licenseStr,
    hardwareId: hardwareId,
    targetPc: targetPc,
    peerId: peerId,
  );
}

Future<ActiveSessionsResult> _fetchLicenseInfoAsActiveSessions(
    String key) async {
  final endpointUri =
      await _licenseUriFromDefault(kLicenseGetLicenseInfoEndpoint);
  final response = await http
      .post(
        endpointUri,
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
      endpoint: endpointUri.toString(),
      licenseKey: key,
      reason: 'HTTP 404 while calling get_license_info',
    );
  }

  final status = payload['status']?.toString().toLowerCase();
  final message = payload['message']?.toString() ?? '';
  final sessions =
      _parseSessions(payload['sessions'] ?? payload['active_sessions']);
  final totalSeats = _extractTotalSeats(payload);
  final occupiedSeats = _extractOccupiedSeats(payload);
  final expiryDateIsoUtc = _extractExpiryIsoUtc(payload);
  final localHardwareId = await _getLocalHardwareId();
  final myActiveConnections =
      _countMyActiveConnections(sessions, localHardwareId);
  final ok = response.statusCode == 200 &&
      (status == 'success' || status == 'valid' || payload.isNotEmpty);
  final isExpired = _isExpiredFromServerData(
    expiryIsoUtc: expiryDateIsoUtc,
    status: status,
    message: message,
  );
  final graceMode = _shouldEnterGraceMode(
    status: status ?? '',
    message: message,
    totalSeats: totalSeats,
    occupiedSeats: occupiedSeats,
    myActiveConnections: myActiveConnections,
  );
  if (graceMode) {
    await markLicenseGraceMode('license_not_found:get_license_info');
  } else if (ok) {
    await clearLicenseGraceMode();
  }

  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt('allowed_connections', totalSeats);
  await prefs.setInt('max_connections', totalSeats);
  await prefs.setInt('active_connections', occupiedSeats);
  await prefs.setBool(kLicenseIsExpiredPrefsKey, graceMode ? false : isExpired);
  if (expiryDateIsoUtc.isNotEmpty) {
    await prefs.setString(kLicenseExpiryIsoPrefsKey, expiryDateIsoUtc);
  }

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
    totalSeats: totalSeats,
    occupiedSeats: occupiedSeats,
    myActiveConnections: myActiveConnections,
  );
}

Future<ActiveSessionsResult> fetchActiveSessions(String licenseKey) async {
  final key = licenseKey.trim();

  try {
    final endpointUri =
        await _licenseUriFromDefault(kLicenseGetActiveSessionsEndpoint);
    final response = await http
        .post(
          endpointUri,
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
    final sessions =
        _parseSessions(payload['sessions'] ?? payload['active_sessions']);
    final totalSeats = _extractTotalSeats(payload);
    final occupiedSeats = _extractOccupiedSeats(payload);
    final expiryDateIsoUtc = _extractExpiryIsoUtc(payload);
    final localHardwareId = await _getLocalHardwareId();
    final myActiveConnections =
        _countMyActiveConnections(sessions, localHardwareId);
    final isOkStatus = status == 'success' || status == 'valid';
    final isExpired = _isExpiredFromServerData(
      expiryIsoUtc: expiryDateIsoUtc,
      status: status,
      message: message,
    );
    final graceMode = _shouldEnterGraceMode(
      status: status ?? '',
      message: message,
      totalSeats: totalSeats,
      occupiedSeats: occupiedSeats,
      myActiveConnections: myActiveConnections,
    );
    if (graceMode) {
      await markLicenseGraceMode('license_not_found:get_active_sessions');
    } else if (response.statusCode == 200 &&
        (isOkStatus || payload.containsKey('sessions'))) {
      await clearLicenseGraceMode();
    }
    if (response.statusCode == 200 &&
        (isOkStatus || payload.containsKey('sessions'))) {
      if (kDebugMode) {
        debugPrint(
            '[License] get_active_sessions OK: total=$totalSeats activeStations=$occupiedSeats my=$myActiveConnections sessions=${sessions.length}');
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('allowed_connections', totalSeats);
      await prefs.setInt('max_connections', totalSeats);
      await prefs.setInt('active_connections', occupiedSeats);
      await prefs.setBool(kLicenseIsExpiredPrefsKey, graceMode ? false : isExpired);
      if (expiryDateIsoUtc.isNotEmpty) {
        await prefs.setString(kLicenseExpiryIsoPrefsKey, expiryDateIsoUtc);
      }
      return ActiveSessionsResult(
        success: true,
        message: message.isEmpty ? 'Active sessions fetched.' : message,
        sessions: sessions,
        totalSeats: totalSeats,
        occupiedSeats: occupiedSeats,
        myActiveConnections: myActiveConnections,
      );
    }

    if (response.statusCode == 404) {
      await _appendLicenseDebugLog(
        endpoint: endpointUri.toString(),
        licenseKey: key,
        reason: 'HTTP 404 while calling get_active_sessions',
      );
      return _fetchLicenseInfoAsActiveSessions(key);
    }

    if (isExpired) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kLicenseIsExpiredPrefsKey, true);
      if (expiryDateIsoUtc.isNotEmpty) {
        await prefs.setString(kLicenseExpiryIsoPrefsKey, expiryDateIsoUtc);
      }
    }
    if (graceMode) {
      return ActiveSessionsResult(
        success: false,
        message:
            'License not found on server. Running in temporary Free mode (up to 36 hours).',
        sessions: const [],
        totalSeats: 0,
        occupiedSeats: 0,
        myActiveConnections: 0,
      );
    }

    if (kDebugMode) {
      debugPrint(
          '[License] get_active_sessions FAIL: http=${response.statusCode} status=$status message=$message');
    }
    return ActiveSessionsResult(
      success: false,
      message: message.isEmpty
          ? 'Failed to load active sessions (${response.statusCode}).'
          : message,
      sessions: sessions,
      totalSeats: totalSeats,
      occupiedSeats: occupiedSeats,
      myActiveConnections: myActiveConnections,
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
  return fetchActiveSessions(license?.trim() ?? '');
}

Future<void> refreshLicenseStatusFromServer() async {
  final license = (await getSavedLicenseKey())?.trim() ?? '';
  if (license.isEmpty) return;

  final isFreeTier = license.toUpperCase().startsWith('SD-FREE-');
  if (isFreeTier) {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kLicenseIsExpiredPrefsKey, false);
    return;
  }

  final verify = await verifyLicenseWithServer(license);
  if (verify.approved) {
    await clearLicenseGraceMode();
    await saveLicenseToPrefs(
      license,
      allowedConnections: verify.allowedConnections,
      activeConnections: verify.activeConnections,
      expiryDateIsoUtc: verify.expiryDateIsoUtc,
      isExpired: false,
    );
    return;
  }

  final hasFreshFutureExpiry = verify.expiryDateIsoUtc.isNotEmpty &&
      !_isExpiredByDate(verify.expiryDateIsoUtc);
  if (hasFreshFutureExpiry) {
    await clearLicenseGraceMode();
    await saveLicenseToPrefs(
      license,
      allowedConnections: verify.allowedConnections > 0
          ? verify.allowedConnections
          : null,
      activeConnections: verify.activeConnections,
      expiryDateIsoUtc: verify.expiryDateIsoUtc,
      isExpired: false,
    );
    return;
  }

  if (verify.isExpired) {
    await clearLicenseGraceMode();
    await saveLicenseToPrefs(
      license,
      allowedConnections: 1,
      activeConnections: verify.activeConnections,
      expiryDateIsoUtc: verify.expiryDateIsoUtc,
      isExpired: true,
    );
    return;
  }

  // Fallback for servers that report expiry only in active/license-info endpoints.
  await fetchActiveSessions(license);
}

Future<void> refreshLicenseStatus() async {
  await refreshLicenseStatusFromServer();
}

Future<void> saveLicenseToPrefs(
  String licenseKey, {
  int? allowedConnections,
  int? activeConnections,
  int? maxConnections,
  String? expiryDateIsoUtc,
  bool? isExpired,
}) async {
  final prefs = await SharedPreferences.getInstance();
  await _setSavedLicenseKey(licenseKey);
  await prefs.setString('masked_license', maskLicense(licenseKey));
  final normalizedExpiry = _normalizeExpiryIsoUtc(expiryDateIsoUtc ?? '');
  final effectiveExpired = isExpired ?? _isExpiredByDate(normalizedExpiry);
  await prefs.setBool(kLicenseIsExpiredPrefsKey, effectiveExpired);
  if (normalizedExpiry.isNotEmpty) {
    await prefs.setString(kLicenseExpiryIsoPrefsKey, normalizedExpiry);
  } else {
    await prefs.remove(kLicenseExpiryIsoPrefsKey);
  }
  final effectiveAllowed = allowedConnections ?? maxConnections;
  if (effectiveAllowed != null) {
    await prefs.setInt('allowed_connections', effectiveAllowed);
    await prefs.setInt('max_connections', effectiveAllowed);
  }
  if (activeConnections != null) {
    await prefs.setInt('active_connections', activeConnections);
  }
  await clearLicenseGraceMode();
}

Future<void> clearLicensePrefs() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_kLegacySavedLicenseKey);
  await prefs.remove('masked_license');
  await prefs.remove(kLicenseExpiryIsoPrefsKey);
  await prefs.remove(kLicenseIsExpiredPrefsKey);
  await prefs.remove('session_id');
  await prefs.remove(_kHardwareIdPrefsKey);
  await prefs.remove(_kPeerSessionMapKey);
  await prefs.remove('allowed_connections');
  await prefs.remove('active_connections');
  await prefs.remove('max_connections');
  await prefs.remove(kLicenseGraceStartMsPrefsKey);
  await prefs.remove(kLicenseGraceReasonPrefsKey);
}

Future<String?> sendLicenseHeartbeat({
  required String licenseKey,
  required String hardwareId,
}) async {
  final key = licenseKey.trim();
  final hwid = hardwareId.trim();
  if (hwid.isEmpty) return null;

  try {
    final localSessionIds = await getLocalLicenseSessionIds();
    final endpointUri = await _licenseUriFromDefault(kLicenseHeartbeatEndpoint);
    final response = await http
        .post(
          endpointUri,
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'license_key': key,
            'hardware_id': hwid,
            // Optional for newer license-server versions; ignored by older ones.
            'session_ids': localSessionIds,
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return null;
    }
    if (response.statusCode == 404) {
      await _appendLicenseDebugLog(
        endpoint: endpointUri.toString(),
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
    final licenseStr = license?.trim() ?? '';
    final localActiveSessions = await getActiveLicenseSessionCount();

    final prefs = await SharedPreferences.getInstance();
    final hardwareId = prefs.getString(_kHardwareIdPrefsKey)?.trim() ?? '';
    if (hardwareId.isEmpty) {
      status.value = LicenseServerStatus.reconnecting;
      return;
    }

    // Primary connectivity signal: active sessions endpoint health.
    final activeResult = await fetchActiveSessions(licenseStr);
    if (activeResult.success) {
      status.value = LicenseServerStatus.online;
      _failedHeartbeats = 0;
      _shownLostServerNotice = false;
    } else {
      status.value = LicenseServerStatus.reconnecting;
    }

    // Heartbeat must run for all tiers (empty license_key is pooled server-side).
    if (kDebugMode) {
      debugPrint(
          '[License] heartbeat running: localActiveSessions=$localActiveSessions licenseEmpty=${licenseStr.isEmpty}');
    }

    final err = await _sendHeartbeatWithBackoff(
      licenseKey: licenseStr,
      hardwareId: hardwareId,
    );
    if (err == null) {
      _failedHeartbeats = 0;
      _shownLostServerNotice = false;
      return;
    }

    // Do not downgrade UI state from ONLINE based only on heartbeat failures.
    // Active sessions endpoint is the primary server-health signal.
    _failedHeartbeats += 1;
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
    final key = (await getSavedLicenseKey())?.trim() ?? '';
    http.Response? response;
    Object? lastError;
    final endpointUri =
        await _licenseUriFromDefault(kLicenseReleaseConnectionEndpoint);
    for (var i = 0; i <= _kReconnectBackoffSeconds.length; i++) {
      try {
        response = await http
            .post(
              endpointUri,
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode({
                'license_key': key,
                'session_id': sid,
              }),
            )
            .timeout(const Duration(seconds: 8));
        lastError = null;
        break;
      } catch (e) {
        lastError = e;
        if (i >= _kReconnectBackoffSeconds.length) rethrow;
        await Future.delayed(Duration(seconds: _kReconnectBackoffSeconds[i]));
      }
    }
    if (lastError != null || response == null) {
      return kLicenseCommunicationErrorMessage;
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      try {
        final payload = jsonDecode(response.body) as Map<String, dynamic>;
        if (payload.containsKey('released_count')) {
          final releasedCount = _toInt(payload['released_count']);
          if (releasedCount <= 0) {
            return payload['message']?.toString() ?? 'Session not found.';
          }
        }
      } catch (_) {
        // Backward compatible with older server responses that return 2xx without JSON.
      }
      return null;
    }
    if (response.statusCode == 404) {
      await _appendLicenseDebugLog(
        endpoint: endpointUri.toString(),
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

Future<String?> releaseConnectionForPeer(
  String peerId, {
  String? sessionIdHint,
}) async {
  final map = await _loadPeerSessionMap();
  final candidates = <String>[];
  final hinted = sessionIdHint?.trim() ?? '';
  if (hinted.isNotEmpty) {
    candidates.add(hinted);
  }
  final sessions = List<String>.from(map[peerId] ?? const <String>[]);
  if (sessions.isNotEmpty) {
    final mapped = sessions.last;
    if (!candidates.contains(mapped)) {
      candidates.add(mapped);
    }
  }
  if (candidates.isEmpty) return null;

  String? firstError;
  for (final candidate in candidates) {
    final err = await releaseConnectionBySessionId(candidate);
    final notFound = (err ?? '').toLowerCase().contains('not found');
    if (err == null) {
      _removeSessionIdFromMap(map, candidate);
      await _savePeerSessionMap(map);
      if (map.isEmpty) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('session_id');
        await prefs.setInt('active_connections', 0);
        final hwid = await _getLocalHardwareId();
        if (hwid.isNotEmpty) {
          // Last local window closed: force-clean any stale sessions for this station.
          await releaseAllMySessionsByHardwareId(hwid);
        }
      }
      return null;
    }
    if (notFound) {
      // If this candidate is stale, try the next candidate (e.g. fallback from
      // FFI session id to license session id). If this is the last candidate,
      // treat it as already released and clean local mapping.
      final isLast = candidate == candidates.last;
      if (!isLast) continue;
      _removeSessionIdFromMap(map, candidate);
      await _savePeerSessionMap(map);
      if (map.isEmpty) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('session_id');
        await prefs.setInt('active_connections', 0);
      }
      return null;
    }
    firstError ??= err;
  }
  // Keep local session mapping so we can retry on next cleanup cycle.
  return firstError;
}

Future<String?> releaseConnection(String? licenseKey) async {
  final map = await _loadPeerSessionMap();
  if (map.isNotEmpty) {
    return releaseConnectionFromPrefs(force: true);
  }

  final key = licenseKey?.trim();
  if (key == null || key.isEmpty) return null;

  try {
    final endpointUri =
        await _licenseUriFromDefault(kLicenseReleaseConnectionEndpoint);
    final response = await http
        .post(
          endpointUri,
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'license_key': key}),
        )
        .timeout(const Duration(seconds: 8));
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return null;
    }
    if (response.statusCode == 404) {
      await _appendLicenseDebugLog(
        endpoint: endpointUri.toString(),
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
  final remained = <String, List<String>>{};
  for (final entry in map.entries) {
    final peerId = entry.key;
    final failedForPeer = <String>[];
    for (final sessionId in entry.value) {
      final err = await releaseConnectionBySessionId(sessionId);
      final notFound = (err ?? '').toLowerCase().contains('not found');
      if (err != null && !notFound) {
        firstError ??= err;
        failedForPeer.add(sessionId);
      }
    }
    if (failedForPeer.isNotEmpty) {
      remained[peerId] = failedForPeer;
    }
  }
  await _savePeerSessionMap(remained);
  final prefs = await SharedPreferences.getInstance();
  if (remained.isEmpty) {
    await prefs.remove('session_id');
    await prefs.setInt('active_connections', 0);
    final hwid = await _getLocalHardwareId();
    if (hwid.isNotEmpty) {
      // Ensure server-side station state is cleared when no local windows remain.
      await releaseAllMySessionsByHardwareId(hwid);
    }
  } else {
    final firstRemaining =
        remained.values.firstWhere((v) => v.isNotEmpty, orElse: () => const []);
    if (firstRemaining.isNotEmpty) {
      await prefs.setString('session_id', firstRemaining.last);
    }
  }
  return firstError;
}
