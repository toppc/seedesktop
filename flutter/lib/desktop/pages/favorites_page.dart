import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/widgets/peer_card.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:get/get.dart';

import '../../common.dart';
import '../../utils/favorite_groups.dart';

class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {
  static const String _recentCategoryId = '__recent__';
  static const String _generalCategoryId = '__general__';
  static const String _customCategoryPrefix = '__group__::';

  String _selectedCategory = _recentCategoryId;
  List<String> _groups = [kDefaultFavoriteGroup];
  Map<String, String> _peerGroups = {};
  bool _syncInProgress = false;

  @override
  void initState() {
    super.initState();
    bind.mainLoadFavPeers();
    bind.mainLoadRecentPeers();
    _reloadGroupsForFavorites();
  }

  Future<void> _reloadGroupsForFavorites() async {
    final favoriteIds = (await bind.mainGetFav()).map((e) => e.toString()).toList();
    await FavoriteGroupsStore.ensureDefaultsForFavorites(favoriteIds);
    final groups = await FavoriteGroupsStore.loadGroups();
    final peerGroups = await FavoriteGroupsStore.loadPeerGroups();
    if (!mounted) return;
    if (listEquals(_groups, groups) && mapEquals(_peerGroups, peerGroups)) return;
    setState(() {
      _groups = groups;
      _peerGroups = peerGroups;
    });
  }

  void _scheduleGroupsSync() {
    if (_syncInProgress) return;
    _syncInProgress = true;
    Future.microtask(() async {
      try {
        await _reloadGroupsForFavorites();
      } finally {
        _syncInProgress = false;
      }
    });
  }

  String _categoryIdForGroup(String group) => '$_customCategoryPrefix$group';

  String? _groupFromCategory(String categoryId) {
    if (!categoryId.startsWith(_customCategoryPrefix)) return null;
    return categoryId.substring(_customCategoryPrefix.length);
  }

  List<Peer> _peersForGroup(List<Peer> favoritePeers, String group) {
    return favoritePeers
        .where((peer) => (_peerGroups[peer.id] ?? kDefaultFavoriteGroup) == group)
        .toList();
  }

  Future<void> _showAddGroupDialog(List<Peer> favoritePeers) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Folder'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Folder name',
          ),
          onSubmitted: (_) => Navigator.of(ctx).pop(controller.text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null || result.trim().isEmpty) return;
    await FavoriteGroupsStore.addGroup(result.trim());
    await _reloadGroupsForFavorites();
    if (!mounted) return;
    setState(() {
      _selectedCategory = _categoryIdForGroup(result.trim());
    });
  }

  Future<void> _renameGroupDialog(String oldGroup, List<Peer> favoritePeers) async {
    final controller = TextEditingController(text: oldGroup);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename Folder'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Folder name',
          ),
          onSubmitted: (_) => Navigator.of(ctx).pop(controller.text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null || result.trim().isEmpty) return;
    await FavoriteGroupsStore.renameGroup(oldGroup, result.trim());
    await _reloadGroupsForFavorites();
    if (!mounted) return;
    setState(() {
      _selectedCategory = _categoryIdForGroup(result.trim());
    });
  }

  Future<void> _deleteGroupIfEmpty(String group, List<Peer> favoritePeers) async {
    final peersInGroup = _peersForGroup(favoritePeers, group);
    if (peersInGroup.isNotEmpty) {
      showToast('Folder is not empty');
      return;
    }
    await FavoriteGroupsStore.removeGroup(group);
    await _reloadGroupsForFavorites();
    if (!mounted) return;
    setState(() {
      if (_selectedCategory == _categoryIdForGroup(group)) {
        _selectedCategory = _generalCategoryId;
      }
    });
  }

  Widget _buildFavoritesWithSidebar(
      List<Peer> favoritePeers, List<Peer> recentPeers) {
    _scheduleGroupsSync();

    final sortedRecentPeers = recentPeers.toList()
      ..sort((a, b) {
        final nameA = (a.alias.isNotEmpty ? a.alias : a.id).toLowerCase();
        final nameB = (b.alias.isNotEmpty ? b.alias : b.id).toLowerCase();
        return nameA.compareTo(nameB);
      });
    final sortedFavoritePeers = favoritePeers.toList()
      ..sort((a, b) {
        final nameA = (a.alias.isNotEmpty ? a.alias : a.id).toLowerCase();
        final nameB = (b.alias.isNotEmpty ? b.alias : b.id).toLowerCase();
        return nameA.compareTo(nameB);
      });

    final customGroups = _groups
        .where((g) => g != kDefaultFavoriteGroup)
        .toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    final categories = <({String id, String label, IconData icon, bool custom})>[
      (
        id: _recentCategoryId,
        label: 'Recent',
        icon: Icons.history,
        custom: false
      ),
      (
        id: _generalCategoryId,
        label: 'GENERAL',
        icon: Icons.folder_open_outlined,
        custom: false
      ),
      ...customGroups.map((g) => (
            id: _categoryIdForGroup(g),
            label: g,
            icon: Icons.folder_outlined,
            custom: true
          )),
    ];

    final currentCategory = categories.any((e) => e.id == _selectedCategory)
        ? _selectedCategory
        : _recentCategoryId;

    List<Peer> selectedPeers;
    String panelTitle;
    if (currentCategory == _recentCategoryId) {
      selectedPeers = sortedRecentPeers;
      panelTitle = 'Recent';
    } else if (currentCategory == _generalCategoryId) {
      selectedPeers = _peersForGroup(sortedFavoritePeers, kDefaultFavoriteGroup);
      panelTitle = 'GENERAL';
    } else {
      final group = _groupFromCategory(currentCategory) ?? kDefaultFavoriteGroup;
      selectedPeers = _peersForGroup(sortedFavoritePeers, group);
      panelTitle = group;
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 250,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Theme.of(context).dividerColor),
          ),
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OutlinedButton.icon(
                onPressed: () => _showAddGroupDialog(sortedFavoritePeers),
                icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                label: const Text('Add Folder'),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.separated(
                  itemCount: categories.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 2),
                  itemBuilder: (context, index) {
                    final category = categories[index];
                    final selected = category.id == currentCategory;
                    final count = category.id == _recentCategoryId
                        ? sortedRecentPeers.length
                        : (category.id == _generalCategoryId
                            ? _peersForGroup(sortedFavoritePeers, kDefaultFavoriteGroup)
                                .length
                            : _peersForGroup(
                                    sortedFavoritePeers,
                                    _groupFromCategory(category.id) ??
                                        kDefaultFavoriteGroup)
                                .length);
                    return InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () {
                        setState(() {
                          _selectedCategory = category.id;
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        decoration: BoxDecoration(
                          color: selected
                              ? Theme.of(context).colorScheme.primary.withOpacity(0.12)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              category.icon,
                              size: 18,
                              color: selected
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context).iconTheme.color,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                category.label,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                                ),
                              ),
                            ),
                            Text(
                              '$count',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            if (category.custom) ...[
                              const SizedBox(width: 4),
                              PopupMenuButton<String>(
                                padding: EdgeInsets.zero,
                                icon: const Icon(Icons.more_horiz, size: 18),
                                onSelected: (value) {
                                  final group = _groupFromCategory(category.id);
                                  if (group == null) return;
                                  if (value == 'rename') {
                                    _renameGroupDialog(group, sortedFavoritePeers);
                                  } else if (value == 'delete') {
                                    _deleteGroupIfEmpty(group, sortedFavoritePeers);
                                  }
                                },
                                itemBuilder: (context) => const [
                                  PopupMenuItem<String>(
                                    value: 'rename',
                                    child: Text('Rename'),
                                  ),
                                  PopupMenuItem<String>(
                                    value: 'delete',
                                    child: Text('Delete'),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Theme.of(context).dividerColor),
            ),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  panelTitle,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: selectedPeers.isEmpty
                      ? const Center(child: Text('No peers in this category.'))
                      : Obx(() {
                          if (peerCardUiType.value == PeerUiType.grid) {
                            return LayoutBuilder(
                              builder: (context, constraints) {
                                const minTileWidth = 280.0;
                                final crossAxisCount =
                                    (constraints.maxWidth / minTileWidth)
                                        .floor()
                                        .clamp(1, 6);
                                return GridView.builder(
                                  itemCount: selectedPeers.length,
                                  gridDelegate:
                                      SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: crossAxisCount,
                                    crossAxisSpacing: 10,
                                    mainAxisSpacing: 10,
                                    childAspectRatio: 2.8,
                                  ),
                                  itemBuilder: (context, index) {
                                    final peer = selectedPeers[index];
                                    return ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        minWidth: 260,
                                        minHeight: 76,
                                      ),
                                      child: FavoritePeerCard(
                                        peer: peer,
                                        menuPadding: kDesktopMenuPadding,
                                      ),
                                    );
                                  },
                                );
                              },
                            );
                          }
                          return ListView.separated(
                            itemCount: selectedPeers.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final peer = selectedPeers[index];
                              return ConstrainedBox(
                                constraints: const BoxConstraints(
                                  minHeight: 76,
                                ),
                                child: FavoritePeerCard(
                                  peer: peer,
                                  menuPadding: kDesktopMenuPadding,
                                ),
                              );
                            },
                          );
                        }),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Favorites',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: AnimatedBuilder(
              animation: Listenable.merge([
                gFFI.favoritePeersModel,
                gFFI.recentPeersModel,
              ]),
              builder: (context, _) {
                final favoritePeers = gFFI.favoritePeersModel.peers;
                final recentPeers = gFFI.recentPeersModel.peers;
                return _buildFavoritesWithSidebar(favoritePeers, recentPeers);
              },
            ),
          ),
        ],
      ),
    );
  }
}
