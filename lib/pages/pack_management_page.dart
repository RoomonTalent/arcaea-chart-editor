import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_state.dart';
import '../services/arc_storage.dart';
import '../services/file_service.dart';
import 'arc_image.dart';
import 'catalog_action.dart';
import '../models/pack.dart';
import 'pack_detail_page.dart';

class PackManagementPage extends StatefulWidget {
  const PackManagementPage({super.key});

  @override
  State<PackManagementPage> createState() => _PackManagementPageState();
}

class _PackManagementPageState extends State<PackManagementPage> {
  bool _selecting = false;
  final _selected = <String>{};
  ArcStorage? _library;

  Future<bool?> _includeSongs(
    AppState state,
    Set<String> ids, {
    required bool deleting,
  }) {
    final count = ids.fold(
      0,
      (sum, id) => sum + (state.songsByPack[id]?.length ?? 0),
    );
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${deleting ? '删除' : '导出'} ${ids.length} 个曲包'),
        content: Text(
          deleting
              ? '选中的曲包包含 $count 首歌曲。仅删除曲包时，包内歌曲会移到单曲，未选中的子曲包会成为独立曲包。'
              : '选中的曲包包含 $count 首歌曲。曲包信息、封面和相关图片会写入同一个分享包。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(deleting ? '仅删除曲包' : '仅导出曲包'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(deleting ? '同时删除歌曲' : '同时导出歌曲'),
          ),
        ],
      ),
    );
  }

  Future<void> _export(AppState state, Set<String> ids) async {
    final include = await _includeSongs(state, ids, deleting: false);
    if (include == null || !mounted) return;
    await catalogAction(context, () async {
      final folder = await ArcStorage.pickExportDirectory('选择曲包分享包保存位置');
      if (folder == null ||
          !mounted ||
          !identical(_library, state.fileService.storage)) {
        return;
      }
      final path = await state.exportCatalogBundle(
        folder,
        packIds: ids,
        includePackSongs: include,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已导出到 $path')));
    });
  }

  Future<void> _delete(AppState state, Set<String> ids) async {
    final include = await _includeSongs(state, ids, deleting: true);
    if (include == null ||
        !mounted ||
        !identical(_library, state.fileService.storage)) {
      return;
    }
    final ok = await catalogAction(
      context,
      () => state.removePacks(ids, includeSongs: include),
      success: '已删除 ${ids.length} 个曲包',
    );
    if (ok && mounted) setState(() => _selected.removeAll(ids));
  }

  Future<void> _import(AppState state) async {
    await catalogAction(context, () async {
      final folder = await ArcStorage.pick('选择曲包分享包', persist: false);
      if (folder == null || !mounted) return;
      final result = await state.importCatalogBundle(folder);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已处理 ${result.packs} 个曲包，导入 ${result.songs} 首歌曲'),
        ),
      );
    });
  }

  static const _sectionOrder = [
    'arcaea',
    'mainstory',
    'mainstory2',
    'sidestory',
    'collab',
  ];

  static const _sectionNames = {
    'arcaea': 'Arcaea',
    'mainstory': '主线故事',
    'mainstory2': '主线故事 II',
    'sidestory': '支线故事',
    'collab': '联动',
  };

  static const _sectionIcons = {
    'arcaea': Icons.public,
    'mainstory': Icons.auto_stories,
    'mainstory2': Icons.auto_stories,
    'sidestory': Icons.explore,
    'collab': Icons.handshake,
  };

  @override
  Widget build(BuildContext context) {
    final current = context.watch<AppState>();
    final storage = current.hasPath ? current.fileService.storage : null;
    if (!identical(storage, _library)) {
      _library = storage;
      _selected.clear();
      _selecting = false;
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(_selecting ? '已选 ${_selected.length} 个曲包' : '曲包管理'),
        actions: [
          Consumer<AppState>(
            builder: (context, state, _) {
              if (!state.hasPath) return const SizedBox.shrink();
              return Row(
                children: [
                  IconButton(
                    tooltip: _selecting ? '退出选择' : '批量选择曲包',
                    icon: Icon(_selecting ? Icons.close : Icons.checklist),
                    onPressed: state.isBusy
                        ? null
                        : () => setState(() {
                            _selecting = !_selecting;
                            _selected.clear();
                          }),
                  ),
                  if (_selecting) ...[
                    IconButton(
                      tooltip: '全选曲包',
                      icon: const Icon(Icons.select_all),
                      onPressed: state.packs.isEmpty
                          ? null
                          : () => setState(() {
                              if (_selected.length == state.packs.length) {
                                _selected.clear();
                              } else {
                                _selected.addAll(
                                  state.packs.map((pack) => pack.id),
                                );
                              }
                            }),
                    ),
                    IconButton(
                      tooltip: '导出选中曲包',
                      icon: const Icon(Icons.file_upload_outlined),
                      onPressed: state.isBusy || _selected.isEmpty
                          ? null
                          : () => _export(state, _selected.toSet()),
                    ),
                    IconButton(
                      tooltip: '删除选中曲包',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: state.isBusy || _selected.isEmpty
                          ? null
                          : () => _delete(state, _selected.toSet()),
                    ),
                  ] else ...[
                    IconButton(
                      tooltip: '导入曲包分享包',
                      icon: const Icon(Icons.drive_folder_upload_outlined),
                      onPressed: state.isBusy ? null : () => _import(state),
                    ),
                    IconButton(
                      icon: const Icon(Icons.add),
                      tooltip: '添加曲包',
                      onPressed: state.isBusy
                          ? null
                          : () => _showAddDialog(context, state),
                    ),
                  ],
                ],
              );
            },
          ),
        ],
      ),
      body: Consumer<AppState>(
        builder: (context, state, _) {
          if (state.packs.isEmpty) {
            return const Center(child: Text('暂无曲包数据'));
          }
          if (_selecting) {
            return ListView.builder(
              itemCount: state.packs.length,
              itemBuilder: (context, index) {
                final pack = state.packs[index];
                return CheckboxListTile(
                  value: _selected.contains(pack.id),
                  title: Text(pack.displayName),
                  subtitle: Text(
                    '${state.songsByPack[pack.id]?.length ?? 0} 首歌曲',
                  ),
                  secondary: SizedBox.square(
                    dimension: 46,
                    child: ArcImage(
                      candidates: FileService.packImages(
                        pack.id,
                        parent: pack.packParent,
                        image: pack.image,
                      ),
                      fallback: const Icon(Icons.album_outlined),
                      fit: BoxFit.contain,
                      cacheWidth: 128,
                    ),
                  ),
                  onChanged: state.isBusy
                      ? null
                      : (selected) => setState(() {
                          if (selected == true) {
                            _selected.add(pack.id);
                          } else {
                            _selected.remove(pack.id);
                          }
                        }),
                );
              },
            );
          }

          // 按 section 分组
          final grouped = <String, List<Pack>>{};
          for (final pack in state.packs) {
            grouped.putIfAbsent(pack.section, () => []);
            grouped[pack.section]!.add(pack);
          }

          final sections = [
            ..._sectionOrder,
            ...grouped.keys.where(
              (section) => !_sectionOrder.contains(section),
            ),
          ];
          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: sections.length,
            itemBuilder: (context, index) {
              final section = sections[index];
              final packs = grouped[section];
              if (packs == null || packs.isEmpty) {
                return const SizedBox.shrink();
              }
              return _SectionRow(
                section: section,
                sectionName:
                    _sectionNames[section] ??
                    (section.isEmpty ? '其他' : section),
                sectionIcon: _sectionIcons[section] ?? Icons.album,
                packs: packs,
                songCounts: state.songsByPack.map(
                  (id, songs) => MapEntry(id, songs.length),
                ),
                onTapPack: (pack) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => PackDetailPage(pack: pack),
                    ),
                  );
                },
                onAdd: () => _showAddDialog(context, state, section: section),
                onEdit: (pack) => _showEditDialog(context, state, pack),
                onDelete: (pack) => _delete(state, {pack.id}),
              );
            },
          );
        },
      ),
    );
  }

  void _showAddDialog(BuildContext context, AppState state, {String? section}) {
    final idCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final parentCtrl = TextEditingController();
    final plusCtrl = TextEditingController(text: '-1');
    String selSection = section ?? 'arcaea';
    bool isExtend = true;
    bool customBanner = false;
    bool cutout = false;
    bool small = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          title: const Text('添加曲包'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: idCtrl,
                  decoration: const InputDecoration(
                    labelText: '曲包 ID *',
                    hintText: '例: my_pack',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: '名称 (英文) *',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: selSection,
                  decoration: const InputDecoration(
                    labelText: '分类',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: _sectionOrder
                      .map(
                        (s) => DropdownMenuItem(
                          value: s,
                          child: Text(_sectionNames[s] ?? s),
                        ),
                      )
                      .toList(),
                  onChanged: (v) {
                    if (v != null) selSection = v;
                  },
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: parentCtrl,
                  decoration: const InputDecoration(
                    labelText: '父曲包 ID (可选)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: plusCtrl,
                  decoration: const InputDecoration(
                    labelText: 'plus_character',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  title: const Text('扩展包', style: TextStyle(fontSize: 14)),
                  value: isExtend,
                  dense: true,
                  onChanged: (v) => setDlgState(() => isExtend = v),
                ),
                SwitchListTile(
                  title: const Text(
                    '自定义 Banner',
                    style: TextStyle(fontSize: 14),
                  ),
                  value: customBanner,
                  dense: true,
                  onChanged: (v) => setDlgState(() => customBanner = v),
                ),
                SwitchListTile(
                  title: const Text('镂空图片', style: TextStyle(fontSize: 14)),
                  value: cutout,
                  dense: true,
                  onChanged: (v) => setDlgState(() => cutout = v),
                ),
                SwitchListTile(
                  title: const Text('小图片', style: TextStyle(fontSize: 14)),
                  value: small,
                  dense: true,
                  onChanged: (v) => setDlgState(() => small = v),
                ),
                const SizedBox(height: 8),
                Text(
                  '图片命名: 1080_select_${idCtrl.text.isEmpty ? "(id)" : idCtrl.text}.png\n放在 songs/pack/ 目录下',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                if (state.isBusy ||
                    idCtrl.text.trim().isEmpty ||
                    nameCtrl.text.trim().isEmpty) {
                  return;
                }
                final pack = Pack(
                  id: idCtrl.text.trim(),
                  section: selSection,
                  nameLocalized: {'en': nameCtrl.text.trim()},
                  descriptionLocalized: {'en': ''},
                  isExtendPack: isExtend,
                  customBanner: customBanner,
                  cutoutPackImage: cutout,
                  smallPackImage: small,
                  packParent: parentCtrl.text.trim().isEmpty
                      ? null
                      : parentCtrl.text.trim(),
                  plusCharacter: int.tryParse(plusCtrl.text) ?? -1,
                );
                final saved = await catalogAction(
                  ctx,
                  () => state.addPack(pack),
                );
                if (saved && ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditDialog(BuildContext context, AppState state, Pack pack) {
    final nameCtrl = TextEditingController(
      text: pack.nameLocalized['en'] ?? '',
    );
    final parentCtrl = TextEditingController(text: pack.packParent ?? '');
    final plusCtrl = TextEditingController(text: '${pack.plusCharacter}');
    String selSection = pack.section;
    final sections = {..._sectionOrder, pack.section};
    bool isExtend = pack.isExtendPack;
    bool customBanner = pack.customBanner;
    bool cutout = pack.cutoutPackImage;
    bool small = pack.smallPackImage;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          title: Text('编辑: ${pack.displayName}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'ID: ${pack.id}',
                  style: const TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: '名称 (英文)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: selSection,
                  decoration: const InputDecoration(
                    labelText: '分类',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: sections
                      .map(
                        (s) => DropdownMenuItem(
                          value: s,
                          child: Text(_sectionNames[s] ?? s),
                        ),
                      )
                      .toList(),
                  onChanged: (v) {
                    if (v != null) selSection = v;
                  },
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: parentCtrl,
                  decoration: const InputDecoration(
                    labelText: '父曲包 ID',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: plusCtrl,
                  decoration: const InputDecoration(
                    labelText: 'plus_character',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  title: const Text('扩展包', style: TextStyle(fontSize: 14)),
                  value: isExtend,
                  dense: true,
                  onChanged: (v) => setDlgState(() => isExtend = v),
                ),
                SwitchListTile(
                  title: const Text(
                    '自定义 Banner',
                    style: TextStyle(fontSize: 14),
                  ),
                  value: customBanner,
                  dense: true,
                  onChanged: (v) => setDlgState(() => customBanner = v),
                ),
                SwitchListTile(
                  title: const Text('镂空图片', style: TextStyle(fontSize: 14)),
                  value: cutout,
                  dense: true,
                  onChanged: (v) => setDlgState(() => cutout = v),
                ),
                SwitchListTile(
                  title: const Text('小图片', style: TextStyle(fontSize: 14)),
                  value: small,
                  dense: true,
                  onChanged: (v) => setDlgState(() => small = v),
                ),
                const SizedBox(height: 8),
                Text(
                  '图片: 1080_select_${pack.id}.png',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                if (state.isBusy) return;
                final name = nameCtrl.text.trim();
                final parent = parentCtrl.text.trim();
                final plusCharacter = int.tryParse(plusCtrl.text);
                if (plusCharacter == null) {
                  await catalogAction(ctx, () async {
                    throw const FormatException('plus_character 必须是整数');
                  });
                  return;
                }
                final changes = <String, dynamic>{
                  if (nameCtrl.text != (pack.nameLocalized['en'] ?? ''))
                    'name_localized': {'en': name},
                  if (selSection != pack.section) 'section': selSection,
                  if (parentCtrl.text != (pack.packParent ?? ''))
                    'pack_parent': parent.isEmpty ? null : parent,
                  if (plusCharacter != pack.plusCharacter)
                    'plus_character': plusCharacter,
                  if (isExtend != pack.isExtendPack) 'is_extend_pack': isExtend,
                  if (customBanner != pack.customBanner)
                    'custom_banner': customBanner,
                  if (cutout != pack.cutoutPackImage)
                    'cutout_pack_image': cutout,
                  if (small != pack.smallPackImage) 'small_pack_image': small,
                };
                final saved =
                    changes.isEmpty ||
                    await catalogAction(
                      ctx,
                      () => state.updatePack(pack.id, changes),
                    );
                if (saved && ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 按分类分组的横向滚动行
class _SectionRow extends StatelessWidget {
  final String section;
  final String sectionName;
  final IconData? sectionIcon;
  final List<Pack> packs;
  final Map<String, int> songCounts;
  final void Function(Pack) onTapPack;
  final VoidCallback onAdd;
  final void Function(Pack) onEdit;
  final void Function(Pack) onDelete;

  const _SectionRow({
    required this.section,
    required this.sectionName,
    this.sectionIcon,
    required this.packs,
    required this.songCounts,
    required this.onTapPack,
    required this.onAdd,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 分类标题
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              if (sectionIcon != null) ...[
                Icon(
                  sectionIcon,
                  size: 20,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 6),
              ],
              Text(
                sectionName,
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.add, size: 18),
                tooltip: '添加曲包到此分类',
                onPressed: onAdd,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),

        // 横向滚动曲包列表（带滚动条和左右箭头）
        _HorizontalPackRow(
          packs: packs,
          songCounts: songCounts,
          onTapPack: onTapPack,
          onEdit: onEdit,
          onDelete: onDelete,
        ),
        const Divider(height: 1),
      ],
    );
  }
}

/// 横向曲包卡片
class _PackCard extends StatelessWidget {
  final Pack pack;
  final int songCount;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _PackCard({
    required this.pack,
    required this.songCount,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 140,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 曲包图片
              Expanded(
                child: ArcImage(
                  candidates: FileService.packImages(
                    pack.id,
                    parent: pack.packParent,
                    image: pack.image,
                  ),
                  fallback: _placeholder(),
                  fit: BoxFit.contain,
                  cacheWidth: 280,
                ),
              ),
              // 信息栏
              Container(
                padding: const EdgeInsets.all(8),
                color: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.7),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      pack.displayName,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Text(
                          '$songCount首',
                          style: TextStyle(
                            fontSize: 10,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const Spacer(),
                        PopupMenuButton<String>(
                          padding: EdgeInsets.zero,
                          iconSize: 16,
                          onSelected: (action) {
                            if (action == 'edit') onEdit();
                            if (action == 'delete') onDelete();
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'edit', child: Text('编辑')),
                            PopupMenuItem(value: 'delete', child: Text('删除')),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _placeholder() {
    return Container(
      color: Colors.grey.withValues(alpha: 0.2),
      child: const Icon(Icons.album, size: 40, color: Colors.grey),
    );
  }
}

/// 带左右箭头按钮的横向滚动行
class _HorizontalPackRow extends StatefulWidget {
  final List<Pack> packs;
  final Map<String, int> songCounts;
  final void Function(Pack) onTapPack;
  final void Function(Pack) onEdit;
  final void Function(Pack) onDelete;

  const _HorizontalPackRow({
    required this.packs,
    required this.songCounts,
    required this.onTapPack,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  State<_HorizontalPackRow> createState() => _HorizontalPackRowState();
}

class _HorizontalPackRowState extends State<_HorizontalPackRow> {
  final ScrollController _scrollCtrl = ScrollController();

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _scrollLeft() {
    if (!_scrollCtrl.hasClients) return;
    _scrollCtrl.animateTo(
      (_scrollCtrl.offset - 200).clamp(
        0.0,
        _scrollCtrl.position.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  void _scrollRight() {
    if (!_scrollCtrl.hasClients) return;
    _scrollCtrl.animateTo(
      (_scrollCtrl.offset + 200).clamp(
        0.0,
        _scrollCtrl.position.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 180,
      child: Row(
        children: [
          // 左箭头
          InkWell(
            onTap: _scrollLeft,
            child: Container(
              width: 24,
              alignment: Alignment.center,
              child: const Icon(
                Icons.chevron_left,
                size: 20,
                color: Colors.grey,
              ),
            ),
          ),
          // 滚动列表
          Expanded(
            child: Scrollbar(
              controller: _scrollCtrl,
              thickness: 8,
              radius: const Radius.circular(4),
              thumbVisibility: true,
              interactive: true,
              child: ListView.builder(
                controller: _scrollCtrl,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                itemCount: widget.packs.length,
                itemBuilder: (context, index) {
                  final pack = widget.packs[index];
                  final count = widget.songCounts[pack.id] ?? 0;
                  return _PackCard(
                    pack: pack,
                    songCount: count,
                    onTap: () => widget.onTapPack(pack),
                    onEdit: () => widget.onEdit(pack),
                    onDelete: () => widget.onDelete(pack),
                  );
                },
              ),
            ),
          ),
          // 右箭头
          InkWell(
            onTap: _scrollRight,
            child: Container(
              width: 24,
              alignment: Alignment.center,
              child: const Icon(
                Icons.chevron_right,
                size: 20,
                color: Colors.grey,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
