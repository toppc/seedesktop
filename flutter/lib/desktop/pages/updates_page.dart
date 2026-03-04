import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

const String _kCurrentVersion = '1.0.0';
const String _kVersionJsonUrl = 'http://187.124.13.191/version.json';

class UpdatesPage extends StatefulWidget {
  const UpdatesPage({super.key});

  @override
  State<UpdatesPage> createState() => _UpdatesPageState();
}

class _UpdatesPageState extends State<UpdatesPage> {
  bool _checking = false;
  String _statusMessage = 'Press "Check for Updates" to check for a newer version.';
  String _releaseNotes = '';
  String _downloadUrl = '';
  bool _hasUpdate = false;

  Future<void> _checkForUpdates() async {
    setState(() {
      _checking = true;
      _statusMessage = 'Checking for updates...';
      _releaseNotes = '';
      _downloadUrl = '';
      _hasUpdate = false;
    });

    try {
      final response = await http.get(Uri.parse(_kVersionJsonUrl));
      if (response.statusCode != 200) {
        setState(() {
          _statusMessage = 'Failed to check updates (HTTP ${response.statusCode}).';
          _checking = false;
        });
        return;
      }

      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final latestVersion = payload['latest_version']?.toString() ?? '';
      final downloadUrl = payload['download_url']?.toString() ?? '';
      final releaseNotes = payload['release_notes']?.toString() ?? '';

      if (latestVersion.isEmpty) {
        setState(() {
          _statusMessage = 'Invalid update response: missing latest_version.';
          _checking = false;
        });
        return;
      }

      final updateAvailable = _isVersionNewer(
        currentVersion: _kCurrentVersion,
        latestVersion: latestVersion,
      );

      setState(() {
        _checking = false;
        _hasUpdate = updateAvailable;
        _releaseNotes = releaseNotes;
        _downloadUrl = downloadUrl;
        _statusMessage = updateAvailable
            ? 'Update available: $latestVersion (current: $_kCurrentVersion)'
            : 'You are using the latest version.';
      });
    } catch (_) {
      setState(() {
        _checking = false;
        _statusMessage = 'Could not check updates. Please try again.';
      });
    }
  }

  bool _isVersionNewer({
    required String currentVersion,
    required String latestVersion,
  }) {
    final currentParts = _parseVersion(currentVersion);
    final latestParts = _parseVersion(latestVersion);
    final maxLen = currentParts.length > latestParts.length
        ? currentParts.length
        : latestParts.length;

    for (int i = 0; i < maxLen; i++) {
      final c = i < currentParts.length ? currentParts[i] : 0;
      final l = i < latestParts.length ? latestParts[i] : 0;
      if (l > c) return true;
      if (l < c) return false;
    }
    return false;
  }

  List<int> _parseVersion(String v) {
    return v
        .split('.')
        .map((part) => int.tryParse(part.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
        .toList();
  }

  Future<void> _downloadUpdate() async {
    if (_downloadUrl.isEmpty) return;
    final uri = Uri.tryParse(_downloadUrl);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Software Updates',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            'Current version: $_kCurrentVersion',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              ElevatedButton.icon(
                onPressed: _checking ? null : _checkForUpdates,
                icon: const Icon(Icons.sync),
                label: const Text('Check for Updates'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(_statusMessage),
          if (_hasUpdate && _releaseNotes.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              'Release Notes',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(_releaseNotes),
          ],
          if (_hasUpdate && _downloadUrl.isNotEmpty) ...[
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _downloadUpdate,
              icon: const Icon(Icons.download),
              label: const Text('Download Update'),
            ),
          ],
        ],
      ),
    );
  }
}
