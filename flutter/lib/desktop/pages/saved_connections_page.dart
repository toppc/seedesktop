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
  final List<_SavedConnectionEntry> _entries = [];

  @override
  void initState() {
    super.initState();
    _loadEntries();
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

  Future<void> _upsertEntry(_SavedConnectionEntry next, {String? originalId}) async {
    final existingIndex = _entries.indexWhere((e) => e.id == next.id);
    final isEditing = originalId != null;
    final isConflict = existingIndex >= 0 && _entries[existingIndex].id != originalId;
    if (isConflict) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('A computer with this ID already exists.')),
      );
      return;
    }
    setState(() {
      if (isEditing) {
        final oldIndex = _entries.indexWhere((e) => e.id == originalId);
        if (oldIndex >= 0) {
          _entries[oldIndex] = next;
        } else if (existingIndex >= 0) {
          _entries[existingIndex] = next;
        } else {
          _entries.add(next);
        }
      } else if (existingIndex >= 0) {
        _entries[existingIndex] = next;
      } else {
        _entries.add(next);
      }
    });
    await _persistEntries();
  }

  Future<void> _deleteEntry(String id) async {
    setState(() {
      _entries.removeWhere((e) => e.id == id);
    });
    await _persistEntries();
  }

  Future<void> _showComputerDialog({_SavedConnectionEntry? initial}) async {
    final nameController = TextEditingController(text: initial?.name ?? '');
    final idController = TextEditingController(text: initial?.id ?? '');
    final passwordController = TextEditingController(text: initial?.password ?? '');
    final isEdit = initial != null;

    final result = await showDialog<_SavedConnectionEntry>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(isEdit ? 'Edit Computer' : 'Add Computer'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: idController,
                  decoration: const InputDecoration(labelText: 'ID'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Password'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                final name = nameController.text.trim();
                final id = idController.text.trim().replaceAll(' ', '');
                if (name.isEmpty || id.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Name and ID are required.')),
                  );
                  return;
                }
                Navigator.of(context).pop(
                  _SavedConnectionEntry(
                    name: name,
                    id: id,
                    password: passwordController.text,
                  ),
                );
              },
              child: Text(isEdit ? 'Save Changes' : 'Add Computer'),
            ),
          ],
        );
      },
    );

    nameController.dispose();
    idController.dispose();
    passwordController.dispose();

    if (result == null) return;
    await _upsertEntry(result, originalId: initial?.id);
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
    final sortedEntries = _entries.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Saved Connections',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              ElevatedButton.icon(
                onPressed: () => _showComputerDialog(),
                icon: const Icon(Icons.add),
                label: const Text('Add Computer'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: sortedEntries.isEmpty
                ? const Center(child: Text('No saved connections yet.'))
                : ListView.separated(
                    itemCount: sortedEntries.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final entry = sortedEntries[index];
                      return Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Theme.of(context).cardColor,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Theme.of(context).dividerColor),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    entry.name,
                                    style: Theme.of(context).textTheme.titleSmall,
                                  ),
                                  const SizedBox(height: 4),
                                  Text('ID: ${entry.id}'),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: 'Edit',
                              onPressed: () => _showComputerDialog(initial: entry),
                              icon: const Icon(Icons.edit_outlined),
                            ),
                            const SizedBox(width: 6),
                            OutlinedButton(
                              onPressed: () => _connectEntry(entry),
                              child: const Text('Connect'),
                            ),
                            const SizedBox(width: 6),
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
