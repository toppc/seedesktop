import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _kFavoriteGroupsPrefsKey = 'favorite_groups';
const String _kFavoritePeerGroupMapPrefsKey = 'favorite_peer_group_map';
const String kDefaultFavoriteGroup = 'General';

class FavoriteGroupsStore {
  static Future<List<String>> loadGroups() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_kFavoriteGroupsPrefsKey) ?? [];
    final groups = <String>{kDefaultFavoriteGroup};
    for (final group in saved) {
      final normalized = _normalizeGroup(group);
      if (normalized != null) {
        groups.add(normalized);
      }
    }
    final result = groups.toList()..sort((a, b) => a.compareTo(b));
    await prefs.setStringList(_kFavoriteGroupsPrefsKey, result);
    return result;
  }

  static Future<void> addGroup(String group) async {
    final normalized = _normalizeGroup(group);
    if (normalized == null) return;
    final prefs = await SharedPreferences.getInstance();
    final groups = await loadGroups();
    if (!groups.contains(normalized)) {
      groups.add(normalized);
      groups.sort((a, b) => a.compareTo(b));
      await prefs.setStringList(_kFavoriteGroupsPrefsKey, groups);
    }
  }

  static Future<void> removeGroup(String group) async {
    final normalized = _normalizeGroup(group);
    if (normalized == null || normalized == kDefaultFavoriteGroup) return;

    final prefs = await SharedPreferences.getInstance();
    final groups = await loadGroups();
    if (groups.remove(normalized)) {
      await prefs.setStringList(_kFavoriteGroupsPrefsKey, groups);
    }

    final map = await loadPeerGroups();
    var changed = false;
    for (final entry in map.entries.toList()) {
      if (entry.value == normalized) {
        map[entry.key] = kDefaultFavoriteGroup;
        changed = true;
      }
    }
    if (changed) {
      await savePeerGroups(map);
    }
  }

  static Future<void> renameGroup(String oldGroup, String newGroup) async {
    final oldNormalized = _normalizeGroup(oldGroup);
    final newNormalized = _normalizeGroup(newGroup);
    if (oldNormalized == null ||
        newNormalized == null ||
        oldNormalized == kDefaultFavoriteGroup) {
      return;
    }
    if (oldNormalized == newNormalized) return;

    final prefs = await SharedPreferences.getInstance();
    final groups = await loadGroups();
    if (!groups.contains(oldNormalized)) return;
    if (groups.contains(newNormalized)) return;

    final updatedGroups = groups
        .map((g) => g == oldNormalized ? newNormalized : g)
        .toList()
      ..sort((a, b) => a.compareTo(b));
    await prefs.setStringList(_kFavoriteGroupsPrefsKey, updatedGroups);

    final map = await loadPeerGroups();
    var changed = false;
    for (final entry in map.entries.toList()) {
      if (entry.value == oldNormalized) {
        map[entry.key] = newNormalized;
        changed = true;
      }
    }
    if (changed) {
      await savePeerGroups(map);
    }
  }

  static Future<Map<String, String>> loadPeerGroups() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kFavoritePeerGroupMapPrefsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return decoded.map<String, String>((key, value) {
        final id = key.toString();
        final group = _normalizeGroup(value.toString()) ?? kDefaultFavoriteGroup;
        return MapEntry(id, group);
      });
    } catch (_) {
      return {};
    }
  }

  static Future<void> savePeerGroups(Map<String, String> value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kFavoritePeerGroupMapPrefsKey, jsonEncode(value));
  }

  static Future<void> assignPeerToGroup(String peerId, String group) async {
    final normalized = _normalizeGroup(group) ?? kDefaultFavoriteGroup;
    await addGroup(normalized);
    final map = await loadPeerGroups();
    map[peerId] = normalized;
    await savePeerGroups(map);
  }

  static Future<void> removePeer(String peerId) async {
    final map = await loadPeerGroups();
    map.remove(peerId);
    await savePeerGroups(map);
  }

  static Future<void> ensureDefaultsForFavorites(List<String> favoriteIds) async {
    final map = await loadPeerGroups();
    var changed = false;
    final favSet = favoriteIds.toSet();
    for (final id in favoriteIds) {
      if (!map.containsKey(id)) {
        map[id] = kDefaultFavoriteGroup;
        changed = true;
      }
    }
    final removed = map.keys.where((id) => !favSet.contains(id)).toList();
    if (removed.isNotEmpty) {
      for (final id in removed) {
        map.remove(id);
      }
      changed = true;
    }
    if (changed) {
      await savePeerGroups(map);
    }
    await addGroup(kDefaultFavoriteGroup);
  }

  static String? _normalizeGroup(String? value) {
    final group = (value ?? '').trim();
    if (group.isEmpty) return null;
    return group;
  }
}

Future<String?> showFavoriteGroupDialog(
  BuildContext context, {
  String title = 'Select Favorites Group',
  String? initialGroup,
  String confirmLabel = 'Save',
}) async {
  final loadedGroups = await FavoriteGroupsStore.loadGroups();
  var selectedGroup =
      loadedGroups.contains(initialGroup) ? initialGroup! : kDefaultFavoriteGroup;
  final newGroupController = TextEditingController();

  final result = await showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        return AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  value: selectedGroup,
                  decoration: const InputDecoration(labelText: 'Group'),
                  items: loadedGroups
                      .map(
                        (group) => DropdownMenuItem<String>(
                          value: group,
                          child: Text(group),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() {
                      selectedGroup = value;
                    });
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: newGroupController,
                  decoration: InputDecoration(
                    labelText: 'Create new group',
                    suffixIcon: IconButton(
                      tooltip: 'Add',
                      onPressed: () {
                        final newGroup = newGroupController.text.trim();
                        if (newGroup.isEmpty || loadedGroups.contains(newGroup)) {
                          return;
                        }
                        setState(() {
                          loadedGroups.add(newGroup);
                          loadedGroups.sort((a, b) => a.compareTo(b));
                          selectedGroup = newGroup;
                          newGroupController.clear();
                        });
                      },
                      icon: const Icon(Icons.add),
                    ),
                  ),
                  onSubmitted: (_) {
                    final newGroup = newGroupController.text.trim();
                    if (newGroup.isEmpty || loadedGroups.contains(newGroup)) {
                      return;
                    }
                    setState(() {
                      loadedGroups.add(newGroup);
                      loadedGroups.sort((a, b) => a.compareTo(b));
                      selectedGroup = newGroup;
                      newGroupController.clear();
                    });
                  },
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
              onPressed: () => Navigator.of(context).pop(selectedGroup),
              child: Text(confirmLabel),
            ),
          ],
        );
      },
    ),
  );

  newGroupController.dispose();
  if (result != null) {
    await FavoriteGroupsStore.addGroup(result);
  }
  return result;
}
