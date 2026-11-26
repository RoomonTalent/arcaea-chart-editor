import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_state.dart';
import '../services/arc_storage.dart';
import '../services/file_service.dart';
import '../services/song_import.dart';
import '../services/song_order.dart';
import '../models/difficulty.dart';
import '../models/pack.dart';
import 'arc_image.dart';
import 'catalog_action.dart';
import 'difficulty_badge.dart';
import '../models/song.dart';
import 'song_detail_page.dart';

class SongManagementPage extends StatefulWidget {
  const SongManagementPage({super.key});

  @override
  State<SongManagementPage> createState() => _SongManagementPageState();
}

class _SongManagementPageState extends State<SongManagementPage> {
  final TextEditingController _searchCtrl = TextEditingController();
  final ScrollController _gridController = ScrollController(
    keepScrollOffset: false,
  );

  // 批量选择模式
  bool _selectMode = false;
  final Set<Object> _selectedIds = {};
  String? _selectionSonglist;

  @override
  void initState() {
    super.initState();
    _searchCtrl.text = context.read<AppState>().searchQuery;
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _gridController.dispose();
    super.dispose();
  }

  void _scrollToFirstSong() {
    if (_gridController.hasClients) _gridController.jumpTo(0);
  }

  void _toggleSelectMode() {
    setState(() {
      _selectMode = !_selectMode;
      _selectionSonglist = _selectMode
          ? context.read<AppState>().scanResult?.manifests['songlist']
          : null;
      if (!_selectMode) _selectedIds.clear();
    });
  }

  void _toggleSelectAll(List<Song> songs) {
    setState(() {
      final ids = songs.map((song) => song.recordKey);
      if (ids.every(_selectedIds.contains)) {
        _selectedIds.removeAll(ids);
      } else {
        _selectedIds.addAll(ids);
      }
    });
  }

  Future<void> _deleteSelected(AppState state) async {
    if (_selectedIds.isEmpty) return;
    final library = state.fileService.storage;
    final expected = _selectionSonglist;
    final records = state.songs
        .where((song) => _selectedIds.contains(song.recordKey))
        .toList();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text(
          '确定要删除选中的 ${_selectedIds.length} 首歌曲吗？\n\n'
          '将移除所选歌曲记录。仍被其他记录引用的音频和谱面会保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final success = await catalogAction(
      context,
      () => state.deleteSongRecords(
        records,
        expectedSonglist: expected,
        expectedStorage: library,
      ),
      success: '已删除 ${records.length} 首歌曲',
    );
    if (success && mounted) {
      setState(() {
        _selectMode = false;
        _selectedIds.clear();
      });
    }
  }

  Future<void> _startImport() async {
    final state = context.read<AppState>();
    final packIds = <String, int>{};
    for (final pack in state.packs) {
      final key = FileService.idKey(pack.id);
      packIds.update(key, (count) => count + 1, ifAbsent: () => 1);
    }
    final selectablePacks = state.packs
        .where(
          (pack) =>
              pack.id.isNotEmpty && packIds[FileService.idKey(pack.id)] == 1,
        )
        .toList();
    if (selectablePacks.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先添加有效且 ID 唯一的曲包')));
      return;
    }
    final destination = state.fileService.storage;
    await catalogAction(context, () async {
      final location = await ArcStorage.pick('选择要导入的歌曲文件夹', persist: false);
      if (location == null || !mounted) return;
      final source = await SongImport.scan(location);
      if (!mounted) return;

      final result = await showDialog<Map<String, dynamic>>(
        context: context,
        barrierDismissible: false,
        builder: (_) =>
            _ImportDialog(source: source, existingPacks: selectablePacks),
      );
      if (result == null || !mounted) return;
      if (!state.hasPath ||
          !identical(destination, state.fileService.storage)) {
        throw StateError('目标目录已切换，请重新导入');
      }

      final id = result['id'] as String;
      await catalogAction(
        context,
        () => state.importSong(source, id, result),
        success: '歌曲 $id 已导入',
      );
    });
  }

  Future<void> _importBundle() async {
    final state = context.read<AppState>();
    await catalogAction(context, () async {
      final location = await ArcStorage.pick('选择导出的歌曲包文件夹', persist: false);
      if (location == null || !mounted) return;
      final imported = await state.importCatalogBundle(location);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '已导入 ${imported.songs} 首歌曲，包内含 ${imported.packs} 个曲包',
            ),
          ),
        );
      }
    });
  }

  Future<void> _exportSelected(AppState state) async {
    final library = state.fileService.storage;
    final expected = _selectionSonglist;
    final records = state.songs
        .where((song) => _selectedIds.contains(song.recordKey))
        .toList();
    await catalogAction(context, () async {
      final location = await ArcStorage.pickExportDirectory('选择批量歌曲包保存位置');
      if (location == null || !mounted) return;
      final path = await state.exportCatalogBundle(
        location,
        songRecords: records,
        expectedSonglist: expected,
        expectedStorage: library,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导出 ${records.length} 首歌曲到 $path')),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final songlist = context.select(
      (AppState state) => state.scanResult?.manifests['songlist'],
    );
    if (_selectMode && _selectionSonglist != songlist) {
      _selectMode = false;
      _selectedIds.clear();
      _selectionSonglist = null;
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _selectMode ? '已选 ${_selectedIds.length} 项' : '歌曲管理',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          Consumer<AppState>(
            builder: (context, state, _) {
              if (!state.hasPath) return const SizedBox.shrink();
              return Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.add),
                    tooltip: '导入歌曲',
                    onPressed: state.isBusy ? null : _startImport,
                  ),
                  IconButton(
                    icon: const Icon(Icons.drive_folder_upload_outlined),
                    tooltip: '导入歌曲包',
                    onPressed: state.isBusy ? null : _importBundle,
                  ),
                  IconButton(
                    icon: Icon(_selectMode ? Icons.close : Icons.checklist),
                    tooltip: _selectMode ? '退出选择' : '批量选择',
                    onPressed: _toggleSelectMode,
                  ),
                  if (_selectMode)
                    IconButton(
                      icon: const Icon(Icons.delete, color: Colors.red),
                      tooltip: '删除选中',
                      onPressed: _selectedIds.isEmpty
                          ? null
                          : () => _deleteSelected(state),
                    ),
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: '重新扫描',
                    onPressed: state.isBusy ? null : () => state.rescan(),
                  ),
                ],
              );
            },
          ),
        ],
      ),
      body: Consumer<AppState>(
        builder: (context, state, _) {
          if (state.error != null && state.scanResult == null) {
            return _buildError(context, state);
          }

          final songs = state.filteredSongs;
          final badgeScale = MediaQuery.textScalerOf(context).scale(10) / 10;
          final gridScale = badgeScale < 1 ? 1.0 : badgeScale;
          final packFilter = state.filterPackId;
          final packNames = {
            for (final pack in state.packs) pack.id: pack.displayName,
          };

          return Column(
            children: [
              _buildDifficultyFilters(state),

              // 批量选择工具栏
              if (_selectMode) _buildSelectToolbar(context, state, songs),

              // 搜索栏（非选择模式）
              if (!_selectMode) _buildSearchBar(context, state),

              if (packFilter != null && !_selectMode)
                Chip(
                  label: Text(packNames[packFilter] ?? packFilter),
                  deleteIcon: const Icon(Icons.close, size: 16),
                  onDeleted: () {
                    state.setFilterPack(null);
                    _scrollToFirstSong();
                  },
                ),

              // 歌曲网格
              Expanded(
                child: songs.isEmpty
                    ? const Center(child: Text('没有符合条件的歌曲'))
                    : GridView.builder(
                        controller: _gridController,
                        padding: const EdgeInsets.all(8),
                        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 190 * gridScale,
                          childAspectRatio: 0.76 / (1 + 0.5 * (gridScale - 1)),
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                        ),
                        itemCount: songs.length,
                        itemBuilder: (context, index) {
                          final song = songs[index];
                          final isSelected = _selectedIds.contains(
                            song.recordKey,
                          );
                          return _SongGridItem(
                            song: song,
                            packName: packNames[song.set_],
                            highlightedRatingClass: state.selectedRatingClass,
                            selectMode: _selectMode,
                            isSelected: isSelected,
                            onTap: () {
                              if (_selectMode) {
                                setState(() {
                                  isSelected
                                      ? _selectedIds.remove(song.recordKey)
                                      : _selectedIds.add(song.recordKey);
                                });
                              } else {
                                _showSongDetail(context, state, song);
                              }
                            },
                          );
                        },
                      ),
              ),

              // 缓存提示
              if (state.fromCache && !_selectMode)
                Container(
                  padding: const EdgeInsets.all(8),
                  color: Colors.green.withValues(alpha: 0.2),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.cached, size: 16, color: Colors.green),
                      SizedBox(width: 8),
                      Text('已从缓存加载', style: TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildError(BuildContext context, AppState state) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.error_outline,
            size: 64,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(height: 16),
          Text('扫描出错', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              state.error!,
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () => state.rescan(),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }

  Widget _buildDifficultyFilters(AppState state) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 6,
        children: [
          for (final ratingClass in [null, ...RatingClass.values])
            ChoiceChip(
              label: Text(
                ratingClass == null
                    ? '全部'
                    : RatingClass.toFullName(ratingClass),
              ),
              selected: state.selectedRatingClass == ratingClass,
              showCheckmark: false,
              onSelected: (_) {
                state.setDifficultyFilter(ratingClass);
                _scrollToFirstSong();
              },
            ),
          FilterChip(
            label: const Text('缺文件'),
            selected: state.missingFilesOnly,
            showCheckmark: false,
            onSelected: (selected) {
              state.setMissingFilesOnly(selected);
              _scrollToFirstSong();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSelectToolbar(
    BuildContext context,
    AppState state,
    List<Song> songs,
  ) {
    final allSelected =
        songs.isNotEmpty &&
        songs.every((song) => _selectedIds.contains(song.recordKey));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: Theme.of(
        context,
      ).colorScheme.secondaryContainer.withValues(alpha: 0.4),
      child: Row(
        children: [
          TextButton.icon(
            icon: Icon(allSelected ? Icons.deselect : Icons.select_all),
            label: Text(allSelected ? '取消全选' : '全选'),
            onPressed: () => _toggleSelectAll(songs),
          ),
          const Spacer(),
          if (_selectedIds.isNotEmpty)
            IconButton(
              tooltip: '导出选中歌曲包',
              icon: const Icon(Icons.drive_folder_upload_outlined),
              onPressed: state.isBusy ? null : () => _exportSelected(state),
            ),
          if (_selectedIds.isNotEmpty)
            FilledButton.tonalIcon(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.red.withValues(alpha: 0.2),
                foregroundColor: Colors.red,
              ),
              icon: const Icon(Icons.delete, size: 18),
              label: Text('删除 (${_selectedIds.length})'),
              onPressed: state.isBusy ? null : () => _deleteSelected(state),
            ),
        ],
      ),
    );
  }

  Widget _buildSearchBar(BuildContext context, AppState state) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: '搜索歌曲名 / 艺术家 / ID...',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                suffixIcon: _searchCtrl.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchCtrl.clear();
                          state.setSearchQuery('');
                        },
                      )
                    : null,
              ),
              onChanged: (v) => state.setSearchQuery(v),
            ),
          ),
          const SizedBox(width: 8),
          PopupMenuButton<SongSortMode>(
            icon: const Icon(Icons.sort),
            tooltip: '排序方式',
            initialValue: state.songSortMode,
            onSelected: (mode) {
              state.setSongSortMode(mode);
              _scrollToFirstSong();
            },
            itemBuilder: (_) => [
              for (final (mode, label) in const [
                (SongSortMode.defaultOrder, '默认'),
                (SongSortMode.title, '歌曲名称'),
                (SongSortMode.difficulty, '难度'),
              ])
                CheckedPopupMenuItem(
                  value: mode,
                  checked: mode == state.songSortMode,
                  child: Text(label),
                ),
            ],
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.filter_list),
            tooltip: '按曲包筛选',
            onSelected: (packId) {
              state.setFilterPack(packId == 'all' ? null : packId);
              _scrollToFirstSong();
            },
            itemBuilder: (context) {
              final items = <PopupMenuEntry<String>>[
                const PopupMenuItem(value: 'all', child: Text('全部曲包')),
              ];
              for (final pack in state.packs) {
                items.add(
                  PopupMenuItem(value: pack.id, child: Text(pack.displayName)),
                );
              }
              return items;
            },
          ),
        ],
      ),
    );
  }

  void _showSongDetail(BuildContext context, AppState state, Song song) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SongDetailPage(
          song: song,
          highlightedRatingClass: state.selectedRatingClass,
        ),
      ),
    );
  }
}

// ======== 网格歌曲项 ========
class _SongGridItem extends StatelessWidget {
  final Song song;
  final String? packName;
  final int? highlightedRatingClass;
  final bool selectMode;
  final bool isSelected;
  final VoidCallback onTap;

  const _SongGridItem({
    required this.song,
    this.packName,
    this.highlightedRatingClass,
    this.selectMode = false,
    this.isSelected = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: isSelected
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: Theme.of(context).colorScheme.primary,
                width: 2.5,
              ),
            )
          : null,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ArcImage(
                    candidates: FileService.songImages(song, smallFirst: true),
                    fallback: _placeholder(context),
                    cacheWidth: 256,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.all(6),
                  color: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.7),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        song.displayTitle,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        packName ?? song.set_,
                        style: TextStyle(
                          fontSize: 10,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (song.availableDifficulties.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 3,
                          runSpacing: 3,
                          children: [
                            for (final difficulty in song.availableDifficulties)
                              DifficultyBadge(
                                difficulty: difficulty,
                                highlighted:
                                    difficulty.ratingClass ==
                                    highlightedRatingClass,
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            // 选择模式复选框
            if (selectMode)
              Positioned(
                top: 4,
                right: 4,
                child: Container(
                  decoration: BoxDecoration(
                    color: isSelected
                        ? Theme.of(context).colorScheme.primary
                        : Colors.black54,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    isSelected
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Icon(Icons.music_note, size: 32, color: Colors.grey),
    );
  }
}

// ======== 导入对话框 ========
class _ImportDialog extends StatefulWidget {
  final SongImport source;
  final List<Pack> existingPacks;

  const _ImportDialog({required this.source, required this.existingPacks});

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _idCtrl;
  late TextEditingController _titleCtrl;
  late TextEditingController _artistCtrl;
  late TextEditingController _bpmCtrl;
  late String _packId;
  int _side = 0;
  final _versionCtrl = TextEditingController(text: '1.0');

  // 难度字段
  final List<TextEditingController> _ratingCtrls = [];
  final List<TextEditingController> _designerCtrls = [];

  @override
  void initState() {
    super.initState();
    _idCtrl = TextEditingController(text: widget.source.suggestedId);
    _titleCtrl = TextEditingController();
    _artistCtrl = TextEditingController();
    _bpmCtrl = TextEditingController(text: '100');

    _packId = widget.existingPacks.first.id;
    for (final _ in widget.source.ratingClasses) {
      _ratingCtrls.add(TextEditingController(text: '1'));
      _designerCtrls.add(TextEditingController());
    }
  }

  @override
  void dispose() {
    _idCtrl.dispose();
    _titleCtrl.dispose();
    _artistCtrl.dispose();
    _bpmCtrl.dispose();
    _versionCtrl.dispose();
    for (final c in _ratingCtrls) {
      c.dispose();
    }
    for (final c in _designerCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? '请填写此项' : null;

  double? _bpm(String value) {
    final bpm = double.tryParse(value.trim());
    return bpm != null && bpm.isFinite && bpm > 0 ? bpm : null;
  }

  static final _rating = RegExp(r'^\d+\+?$');

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final diffs = <Map<String, dynamic>>[];
    for (final (index, ratingClass) in widget.source.ratingClasses.indexed) {
      final text = _ratingCtrls[index].text.trim();
      final plus = text.endsWith('+');
      diffs.add({
        'ratingClass': ratingClass,
        'chartDesigner': _designerCtrls[index].text.trim(),
        'jacketDesigner': '',
        'rating': int.parse(plus ? text.substring(0, text.length - 1) : text),
        if (widget.source.hasFile('$ratingClass.ogg')) 'audioOverride': true,
        if (RatingClass.jacketNames(ratingClass).any(widget.source.hasFile))
          'jacketOverride': true,
        if (plus) 'ratingPlus': true,
      });
    }
    Navigator.pop(context, <String, dynamic>{
      'id': _idCtrl.text.trim(),
      'title_localized': {'en': _titleCtrl.text.trim()},
      'artist': _artistCtrl.text.trim(),
      'bpm': _bpmCtrl.text.trim(),
      'bpm_base': _bpm(_bpmCtrl.text)!,
      'set': _packId,
      'purchase': '',
      'audioPreview': 0,
      'audioPreviewEnd': 0,
      'side': _side,
      'bg': 'base_light',
      'bg_inverse': 'base_conflict',
      'date': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'version': _versionCtrl.text.trim(),
      'difficulties': diffs,
    });
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    final classes = source.ratingClasses;
    final missingWarnings = <String>[
      if (!source.hasFile('base.ogg')) 'base.ogg（音频）',
      if (!source.hasFile('1080_base.jpg') &&
          !source.hasFile('base.jpg') &&
          !source.hasFile('1080_base_256.jpg'))
        '封面',
    ];

    return AlertDialog(
      title: const Text('导入歌曲'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 扫描结果
              Text(
                '检测到的文件:',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                '${source.entries.where((entry) => entry.kind == EntryKind.file).length} 个文件，'
                '${classes.length} 个谱面（.aff）',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              if (missingWarnings.isNotEmpty) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(
                      Icons.warning_amber,
                      size: 14,
                      color: Colors.orange,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '缺少: ${missingWarnings.join(", ")}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.orange,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const Divider(),

              // 基本信息
              TextFormField(
                controller: _idCtrl,
                validator: (value) {
                  try {
                    FileService.validateId(value?.trim() ?? '');
                    return null;
                  } on FormatException catch (error) {
                    return error.message;
                  }
                },
                decoration: const InputDecoration(
                  labelText: '歌曲 ID *',
                  hintText: '将作为文件夹名',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _titleCtrl,
                validator: _required,
                decoration: const InputDecoration(
                  labelText: '歌曲名称 *',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _artistCtrl,
                decoration: const InputDecoration(
                  labelText: '艺术家',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _bpmCtrl,
                validator: (value) =>
                    _bpm(value ?? '') == null ? '请输入正数 BPM' : null,
                decoration: const InputDecoration(
                  labelText: 'BPM',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),

              // 曲包
              DropdownButtonFormField<String>(
                initialValue: _packId,
                decoration: const InputDecoration(
                  labelText: '所属曲包',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  for (final pack in widget.existingPacks)
                    DropdownMenuItem(
                      value: pack.id,
                      child: Text(pack.displayName),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) _packId = value;
                },
              ),
              const SizedBox(height: 10),

              // Side
              DropdownButtonFormField<int>(
                initialValue: 0,
                decoration: const InputDecoration(
                  labelText: 'Side',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: const [
                  DropdownMenuItem(value: 0, child: Text('Light (光)')),
                  DropdownMenuItem(value: 1, child: Text('Conflict (纷争)')),
                ],
                onChanged: (v) => _side = v ?? 0,
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _versionCtrl,
                decoration: const InputDecoration(
                  labelText: '版本',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),

              const Divider(),
              // 难度信息
              Text(
                '难度信息 (${classes.length} 个铺面):',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              for (final (i, ratingClass) in classes.indexed) ...[
                Text(
                  '${RatingClass.toName(ratingClass)}  ${RatingClass.chartName(ratingClass)}',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      flex: 1,
                      child: TextFormField(
                        controller: _ratingCtrls[i],
                        validator: (value) {
                          final text = value?.trim() ?? '';
                          if (!_rating.hasMatch(text) ||
                              int.tryParse(text.replaceFirst('+', '')) ==
                                  null) {
                            return '请输入等级';
                          }
                          return null;
                        },
                        decoration: const InputDecoration(
                          labelText: '等级（如 9+）',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        keyboardType: TextInputType.text,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _designerCtrls[i],
                        decoration: const InputDecoration(
                          labelText: '谱师',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('导入')),
      ],
    );
  }
}
