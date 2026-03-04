import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _kSavedConnectionsPrefsKey = 'saved_connections';
const String _kSavedConnectionFoldersPrefsKey = 'saved_connection_folders';
const String _kUncategorizedFolderLabel = 'Uncategorized';

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
  final List<String> _folders = [];
  final Map<String, bool> _expandedFolders = {};
  String _selectedFolder = _kUncategorizedFolderLabel;

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
    final rawFolders = prefs.getStringList(_kSavedConnectionFoldersPrefsKey) ?? [];
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
      _folders
        ..clear()
        ..addAll(rawFolders.map((f) => f.trim()).where((f) => f.isNotEmpty));
      _selectedFolder = _kUncategorizedFolderLabel;
    });
  }

  Future<void> _persistEntries() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = _entries.map((e) => jsonEncode(e.toJson())).toList();
    await prefs.setStringList(_kSavedConnectionsPrefsKey, encoded);
  }

  Future<void> _persistFolders() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kSavedConnectionFoldersPrefsKey, _folders);
  }

  String? _normalizeFolder(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed == _kUncategorizedFolderLabel) {
      return null;
    }
    return trimmed;
  }

  Future<void> _saveEntry() async {
    final name = _nameController.text.trim();
    final id = _idController.text.trim().replaceAll(' ', '');
    final password = _passwordController.text;
    final folderName = _normalizeFolder(_selectedFolder);
    if (name.isEmpty || id.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Name and ID are required.')),
      );
      return;
    }
    final existingIndex = _entries.indexWhere((e) => e.id == id);
    final next = _SavedConnectionEntry(
      name: name,
      id: id,
      password: password,
      folderName: folderName,
    );
    setState(() {
      if (existingIndex >= 0) {
        _entries[existingIndex] = next;
      } else {
        _entries.add(next);
      }
      if (folderName != null && !_folders.contains(folderName)) {
        _folders.add(folderName);
      }
      _nameController.clear();
      _idController.clear();
      _passwordController.clear();
      _selectedFolder = _kUncategorizedFolderLabel;
    });
    await _persistEntries();
    await _persistFolders();
  }

  Future<void> _deleteEntry(String id) async {
    setState(() {
      _entries.removeWhere((e) => e.id == id);
    });
    await _persistEntries();
  }

  Future<void> _showAddFolderDialog() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Folder'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Folder name',
          ),
          onSubmitted: (_) => Navigator.of(context).pop(controller.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    final normalized = _normalizeFolder(name ?? '');
    if (normalized == null) return;
    if (_folders.contains(normalized)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Folder already exists.')),
      );
      return;
    }
    setState(() {
      _folders.add(normalized);
      _selectedFolder = normalized;
      _expandedFolders[normalized] = true;
    });
    await _persistFolders();
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
    final groupedEntries = <String, List<_SavedConnectionEntry>>{
      _kUncategorizedFolderLabel: [],
      ...{for (final folder in _folders) folder: []},
    };
    for (final entry in _entries) {
      final folder = entry.folderName?.trim();
      final key =
          (folder == null || folder.isEmpty) ? _kUncategorizedFolderLabel : folder;
      groupedEntries.putIfAbsent(key, () => []);
      groupedEntries[key]!.add(entry);
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Saved Connections',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: _showAddFolderDialog,
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('Add Folder'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              SizedBox(
                width: 220,
                child: TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
              ),
              SizedBox(
                width: 220,
                child: TextField(
                  controller: _idController,
                  decoration: const InputDecoration(labelText: 'ID'),
                ),
              ),
              SizedBox(
                width: 220,
                child: TextField(
                  controller: _passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Password'),
                ),
              ),
              SizedBox(
                width: 220,
                child: DropdownButtonFormField<String>(
                  value: _selectedFolder,
                  decoration: const InputDecoration(labelText: 'Folder'),
                  items: [
                    const DropdownMenuItem(
                      value: _kUncategorizedFolderLabel,
                      child: Text(_kUncategorizedFolderLabel),
                    ),
                    ..._folders.map(
                      (folder) => DropdownMenuItem(
                        value: folder,
                        child: Text(folder),
                      ),
                    ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() {
                      _selectedFolder = value;
                    });
                  },
                ),
              ),
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
                : ListView(
                    children: groupedEntries.entries.map((folderEntry) {
                      final folderName = folderEntry.key;
                      final connections = folderEntry.value;
                      final expanded = _expandedFolders[folderName] ?? true;
                      return Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        child: ExpansionTile(
                          key: PageStorageKey('saved-folder-$folderName'),
                          title: Text(folderName),
                          initiallyExpanded: expanded,
                          onExpansionChanged: (value) {
                            setState(() {
                              _expandedFolders[folderName] = value;
                            });
                          },
                          children: connections.isEmpty
                              ? const [
                                  ListTile(
                                    dense: true,
                                    title: Text('No connections in this folder.'),
                                  )
                                ]
                              : connections.map((entry) {
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
                                }).toList(),
                        ),
                      );
                    }).toList(),
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
  final String? folderName;

  const _SavedConnectionEntry({
    required this.name,
    required this.id,
    required this.password,
    this.folderName,
  });

  factory _SavedConnectionEntry.fromJson(Map<String, dynamic> json) {
    return _SavedConnectionEntry(
      name: json['name']?.toString() ?? '',
      id: json['id']?.toString() ?? '',
      password: json['password']?.toString() ?? '',
      folderName: json['folderName']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'id': id,
        'password': password,
        if (folderName != null && folderName!.isNotEmpty) 'folderName': folderName,
      };
}
