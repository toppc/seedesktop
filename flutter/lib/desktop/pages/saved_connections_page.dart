import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _kSavedConnectionsPrefsKey = 'saved_connections';

class SavedConnectionsPage extends StatefulWidget {
  const SavedConnectionsPage({super.key});

  @override
  State<SavedConnectionsPage> createState() => _SavedConnectionsPageState();
}

class _SavedConnectionsPageState extends State<SavedConnectionsPage> {
  final _nameController = TextEditingController();
  final _idController = TextEditingController();
  final _passwordController = TextEditingController();

  final List<_SavedConnectionEntry> _entries = [];

  @override
  void initState() {
    super.initState();
    _loadEntries();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _idController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _loadEntries() async {
    final prefs = await SharedPreferences.getInstance();
    final rawList = prefs.getStringList(_kSavedConnectionsPrefsKey) ?? [];
    final loaded = <_SavedConnectionEntry>[];
    for (final raw in rawList) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        loaded.add(_SavedConnectionEntry.fromJson(decoded));
      } catch (_) {
        // Ignore malformed local entries.
      }
    }
    if (!mounted) return;
    setState(() {
      _entries
        ..clear()
        ..addAll(loaded);
    });
  }

  Future<void> _persistEntries() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = _entries.map((e) => jsonEncode(e.toJson())).toList();
    await prefs.setStringList(_kSavedConnectionsPrefsKey, encoded);
  }

  Future<void> _saveEntry() async {
    final name = _nameController.text.trim();
    final id = _idController.text.trim().replaceAll(' ', '');
    final password = _passwordController.text;
    if (name.isEmpty || id.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Name and ID are required.')),
      );
      return;
    }
    final existingIndex = _entries.indexWhere((e) => e.id == id);
    final next = _SavedConnectionEntry(name: name, id: id, password: password);
    setState(() {
      if (existingIndex >= 0) {
        _entries[existingIndex] = next;
      } else {
        _entries.add(next);
      }
      _nameController.clear();
      _idController.clear();
      _passwordController.clear();
    });
    await _persistEntries();
  }

  Future<void> _deleteEntry(String id) async {
    setState(() {
      _entries.removeWhere((e) => e.id == id);
    });
    await _persistEntries();
  }

  void _connectEntry(_SavedConnectionEntry entry) {
    connect(
      context,
      entry.id,
      password: entry.password.isEmpty ? null : entry.password,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Saved Connections',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _idController,
                  decoration: const InputDecoration(labelText: 'ID'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Password'),
                ),
              ),
              const SizedBox(width: 12),
              ElevatedButton(
                onPressed: _saveEntry,
                child: const Text('Save'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _entries.isEmpty
                ? const Center(child: Text('No saved connections yet.'))
                : ListView.separated(
                    itemCount: _entries.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final entry = _entries[index];
                      return ListTile(
                        tileColor: Theme.of(context).cardColor,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        title: Text(entry.name),
                        subtitle: Text('ID: ${entry.id}'),
                        trailing: Wrap(
                          spacing: 8,
                          children: [
                            ElevatedButton(
                              onPressed: () => _connectEntry(entry),
                              child: const Text('Connect'),
                            ),
                            IconButton(
                              tooltip: 'Delete',
                              onPressed: () => _deleteEntry(entry.id),
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _SavedConnectionEntry {
  final String name;
  final String id;
  final String password;

  const _SavedConnectionEntry({
    required this.name,
    required this.id,
    required this.password,
  });

  factory _SavedConnectionEntry.fromJson(Map<String, dynamic> json) {
    return _SavedConnectionEntry(
      name: json['name']?.toString() ?? '',
      id: json['id']?.toString() ?? '',
      password: json['password']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'id': id,
        'password': password,
      };
}
