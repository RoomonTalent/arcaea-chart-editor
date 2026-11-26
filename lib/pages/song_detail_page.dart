import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../chart/chart_editor_page.dart';
import '../chart/chart_files.dart';
import '../services/app_state.dart';
import '../services/arc_storage.dart';
import '../services/file_service.dart';
import 'arc_image.dart';
import 'catalog_action.dart';
import 'difficulty_badge.dart';
import '../models/song.dart';
import '../models/difficulty.dart';
import '../models/pack.dart';
import '../models/unlock.dart';

class SongDetailPage extends StatefulWidget {
  final Song song;
  final int? highlightedRatingClass;

  const SongDetailPage({
    super.key,
    required this.song,
    this.highlightedRatingClass,
  });

  @override
  State<SongDetailPage> createState() => _SongDetailPageState();
}

class _SongDetailPageState extends State<SongDetailPage> {
  late TextEditingController _titleEnCtrl;
  late TextEditingController _artistCtrl;
  late TextEditingController _bpmCtrl;
  String? _selectedPackId;
  bool _hasChanges = false;
  bool _saving = false;
  late final ArcStorage _library;
  String? _expectedSonglist;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    _library = state.fileService.storage;
    _expectedSonglist = state.scanResult?.manifests['songlist'];
    _titleEnCtrl = TextEditingController(
      text: widget.song.titleLocalized['en'] ?? '',
    );
    _artistCtrl = TextEditingController(text: widget.song.artist);
    _bpmCtrl = TextEditingController(text: widget.song.bpm);
    _selectedPackId = widget.song.set_;
  }

  @override
  void dispose() {
    _titleEnCtrl.dispose();
    _artistCtrl.dispose();
    _bpmCtrl.dispose();
    super.dispose();
  }

  void _markChanged() {
    if (!_hasChanges) {
      setState(() => _hasChanges = true);
    }
  }

  Future<void> _saveChanges(AppState state) async {
    final current = state.songs
        .where(
          (song) =>
              song.id == widget.song.id &&
              song.recordKey == widget.song.recordKey,
        )
        .firstOrNull;
    if (current == null) return;
    final fields = <String, dynamic>{};

    final newTitle = _titleEnCtrl.text.trim();
    if (_titleEnCtrl.text != (current.titleLocalized['en'] ?? '')) {
      fields['title_localized'] = {'en': newTitle};
    }
    final newArtist = _artistCtrl.text.trim();
    if (_artistCtrl.text != current.artist) {
      fields['artist'] = newArtist;
    }
    final newBpm = _bpmCtrl.text.trim();
    if (_bpmCtrl.text != current.bpm) {
      fields['bpm'] = newBpm;
    }
    if (_selectedPackId != null && _selectedPackId != current.set_) {
      fields['set'] = _selectedPackId;
    }

    if (fields.isEmpty) {
      setState(() => _hasChanges = false);
      return;
    }
    setState(() => _saving = true);
    final saved = await catalogAction(
      context,
      () => state.updateSong(
        current.id,
        fields,
        recordIndex: current.recordIndex,
        expectedSonglist: _expectedSonglist,
        expectedStorage: _library,
      ),
      success: '歌曲信息已保存',
    );
    if (mounted) {
      setState(() {
        _saving = false;
        if (saved) {
          _hasChanges = false;
          _expectedSonglist = state.scanResult?.manifests['songlist'];
        }
      });
    }
  }

  Future<void> _export(AppState state, Song song) async {
    await catalogAction(context, () async {
      final location = await ArcStorage.pickExportDirectory('选择歌曲包的保存位置');
      if (location == null || !mounted) return;
      final path = await state.exportSong(
        song.id,
        location,
        record: song,
        expectedSonglist: _expectedSonglist,
        expectedStorage: _library,
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('歌曲包已保存到 $path')));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
        // 从最新数据中获取歌曲（因为可能已被修改）
        final song =
            state.songs
                .where(
                  (s) =>
                      s.id == widget.song.id &&
                      s.recordKey == widget.song.recordKey,
                )
                .firstOrNull ??
            widget.song;
        final unlocks = state.unlocksBySongId[song.id] ?? [];
        final charts = RatingClass.values.where((ratingClass) {
          final name = RatingClass.chartName(ratingClass);
          return song.folderFiles?.any(
                (file) =>
                    file.toLowerCase() == name ||
                    file.toLowerCase() == '.arcaea-aff-pending-$name',
              ) ??
              false;
        });

        return Scaffold(
          appBar: AppBar(
            title: Text(song.displayTitle),
            actions: [
              IconButton(
                icon: const Icon(Icons.ios_share),
                tooltip: '导出歌曲包',
                onPressed: state.isBusy ? null : () => _export(state, song),
              ),
              if (song.lineNumber != null)
                IconButton(
                  icon: const Icon(Icons.code),
                  tooltip: 'songlist 第 ${song.lineNumber} 行',
                  onPressed: () => _showLocationDialog(context, state, song),
                ),
              if (_hasChanges)
                IconButton(
                  icon: const Icon(Icons.save),
                  tooltip: '保存修改',
                  onPressed: _saving || state.isBusy
                      ? null
                      : () => _saveChanges(state),
                ),
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 封面
                Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      width: 200,
                      height: 200,
                      child: ArcImage(
                        candidates: FileService.songImages(song),
                        fallback: Container(
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
                          child: const Icon(
                            Icons.music_note,
                            size: 64,
                            color: Colors.grey,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (song.availableDifficulties.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Center(
                      child: Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (final difficulty in song.availableDifficulties)
                            DifficultyBadge(
                              difficulty: difficulty,
                              highlighted:
                                  difficulty.ratingClass ==
                                  widget.highlightedRatingClass,
                            ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                if (charts.isNotEmpty) ...[
                  Text('谱面编辑器', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (final ratingClass in charts)
                        OutlinedButton.icon(
                          onPressed: state.isBusy
                              ? null
                              : () {
                                  if (!state.hasPath ||
                                      !identical(
                                        state.fileService.storage,
                                        _library,
                                      ) ||
                                      state.scanResult?.manifests['songlist'] !=
                                          _expectedSonglist) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('歌曲清单已变化，请重新打开此歌曲'),
                                      ),
                                    );
                                    return;
                                  }
                                  Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                      builder: (_) => ChartEditorPage(
                                        onSetBpmBase:
                                            song.difficultyFor(ratingClass) ==
                                                null
                                            ? null
                                            : (bpm) async {
                                                await state.updateChartBpmBase(
                                                  song.id,
                                                  ratingClass,
                                                  bpm,
                                                  recordIndex: song.recordIndex,
                                                  expectedSonglist:
                                                      _expectedSonglist,
                                                  expectedStorage: _library,
                                                );
                                                _expectedSonglist = state
                                                    .scanResult
                                                    ?.manifests['songlist'];
                                              },
                                        title:
                                            '${song.displayTitle} · ${RatingClass.toName(ratingClass)}',
                                        files: ChartFiles(
                                          _library,
                                          song.id,
                                          ratingClass,
                                          root: FileService.arcExtRootFor(
                                            _library,
                                          ),
                                          song: song,
                                        ),
                                      ),
                                    ),
                                  );
                                },
                          icon: const Icon(Icons.edit_note),
                          label: Text(RatingClass.toFullName(ratingClass)),
                        ),
                    ],
                  ),
                  const Divider(height: 24),
                ],

                // === 可编辑字段 ===
                Text(
                  '编辑信息',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        TextField(
                          controller: _titleEnCtrl,
                          enabled: !_saving,
                          decoration: const InputDecoration(
                            labelText: '歌曲名称 (英文)',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          onChanged: (_) => _markChanged(),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _artistCtrl,
                          enabled: !_saving,
                          decoration: const InputDecoration(
                            labelText: '艺术家',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          onChanged: (_) => _markChanged(),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _bpmCtrl,
                          enabled: !_saving,
                          decoration: const InputDecoration(
                            labelText: 'BPM',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          onChanged: (_) => _markChanged(),
                        ),
                        const SizedBox(height: 12),
                        // 曲包选择器
                        _PackSelector(
                          packs: state.packs,
                          selectedPackId: _selectedPackId,
                          onChanged: (packId) {
                            if (_saving) return;
                            setState(() => _selectedPackId = packId);
                            _markChanged();
                          },
                        ),
                      ],
                    ),
                  ),
                ),

                const Divider(height: 32),

                // 难度信息（只读）
                Text(
                  '难度信息',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                ...song.availableDifficulties.map(
                  (difficulty) => _DiffCard(
                    difficulty: difficulty,
                    unlocks: unlocks,
                    highlighted:
                        difficulty.ratingClass == widget.highlightedRatingClass,
                  ),
                ),

                const Divider(height: 32),

                // 解锁状态汇总
                _UnlockSummary(song: song, unlocks: unlocks),

                const Divider(height: 32),

                // 元数据（只读）
                Text(
                  '其他信息',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        _RORow('ID', song.id),
                        _RORow('曲包ID', song.set_),
                        _RORow(
                          'Side',
                          song.side == 0 ? 'Light (光)' : 'Conflict (纷争)',
                        ),
                        _RORow('背景', '${song.bg} / ${song.bgInverse}'),
                        _RORow('版本', song.version),
                        if (song.purchase.isNotEmpty)
                          _RORow('购买', song.purchase),
                      ],
                    ),
                  ),
                ),

                const Divider(height: 32),

                // 文件完整性
                Text(
                  '文件完整性',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                _FileCheckCard(song: song),

                const SizedBox(height: 32),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showLocationDialog(BuildContext context, AppState state, Song song) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('文件位置'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('歌曲: ${song.displayTitle}'),
            const SizedBox(height: 8),
            Text('songlist 第 ${song.lineNumber} 行'),
            const SizedBox(height: 4),
            Text(
              '路径: ${state.fileService.storage.displayPath('songlist')}',
              style: const TextStyle(fontSize: 11),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}

// ---- 曲包选择器（点击弹出带图片的列表） ----
class _PackSelector extends StatelessWidget {
  final List<Pack> packs;
  final String? selectedPackId;
  final ValueChanged<String> onChanged;

  const _PackSelector({
    required this.packs,
    required this.selectedPackId,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final selected = packs.where((p) => p.id == selectedPackId).firstOrNull;

    return InkWell(
      onTap: () => _showPicker(context),
      borderRadius: BorderRadius.circular(8),
      child: InputDecorator(
        decoration: const InputDecoration(
          labelText: '所属曲包',
          border: OutlineInputBorder(),
          isDense: true,
        ),
        child: Row(
          children: [
            if (selected != null) ...[
              _packThumb(selected.id, 28),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                selected?.displayName ?? '未选择',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }

  void _showPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SizedBox(
        height: 400,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text('选择曲包', style: Theme.of(ctx).textTheme.titleMedium),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: packs.length,
                itemBuilder: (_, i) {
                  final pack = packs[i];
                  final isSelected = pack.id == selectedPackId;
                  return ListTile(
                    leading: _packThumb(pack.id, 36),
                    title: Text(pack.displayName),
                    subtitle: Text(
                      pack.id,
                      style: const TextStyle(fontSize: 11),
                    ),
                    trailing: isSelected
                        ? const Icon(Icons.check, color: Colors.green)
                        : null,
                    onTap: () {
                      onChanged(pack.id);
                      Navigator.pop(ctx);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _packThumb(String packId, double size) {
    final parent = packs
        .where((pack) => pack.id == packId)
        .firstOrNull
        ?.packParent;
    return SizedBox(
      width: size,
      height: size,
      child: ArcImage(
        candidates: FileService.packImages(packId, parent: parent),
        fallback: _placeholder(size),
        cacheWidth: 128,
      ),
    );
  }

  Widget _placeholder(double size) {
    return Container(
      width: size,
      height: size,
      color: Colors.grey.withValues(alpha: 0.3),
      child: const Icon(Icons.album, size: 16),
    );
  }
}

// ---- 难度卡片 ----
class _DiffCard extends StatelessWidget {
  final Difficulty difficulty;
  final List<Unlock> unlocks;
  final bool highlighted;

  const _DiffCard({
    required this.difficulty,
    required this.unlocks,
    required this.highlighted,
  });

  @override
  Widget build(BuildContext context) {
    final u = unlocks
        .where((u) => u.ratingClass == difficulty.ratingClass)
        .toList();
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DifficultyBadge(difficulty: difficulty, highlighted: highlighted),
            const SizedBox(height: 8),
            Text('谱师: ${difficulty.chartDesigner}'),
            if (difficulty.jacketDesigner.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('曲绘: ${difficulty.jacketDesigner}'),
            ],
            if (difficulty.version != null) ...[
              const SizedBox(height: 4),
              Text('版本: ${difficulty.version}'),
            ],
            if (u.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Divider(),
              const Text(
                '解锁条件:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              ...u.map(
                (unlock) => Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.lock_open, size: 14),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          unlock.conditionsSummary,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---- 只读信息行 ----
class _RORow extends StatelessWidget {
  final String label, value;
  const _RORow(this.label, this.value);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

// ---- 文件完整性 ----
class _FileCheckCard extends StatelessWidget {
  final Song song;
  const _FileCheckCard({required this.song});
  @override
  Widget build(BuildContext context) {
    final ok = song.isFolderComplete;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(
              ok ? Icons.check_circle : Icons.warning,
              color: ok ? Colors.green : Colors.orange,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                ok ? '文件齐全' : '缺少: ${song.missingFiles.join(", ")}',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: ok ? null : Colors.orange,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---- 解锁状态汇总 ----
class _UnlockSummary extends StatelessWidget {
  final Song song;
  final List<Unlock> unlocks;
  const _UnlockSummary({required this.song, required this.unlocks});

  @override
  Widget build(BuildContext context) {
    final difficultyNames = ['PST', 'PRS', 'FTR', 'BYD', 'ETR'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '解锁状态',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                for (final d in song.availableDifficulties)
                  _UnlockRow(
                    difficulty: d,
                    unlock: unlocks
                        .where((u) => u.ratingClass == d.ratingClass)
                        .firstOrNull,
                    difficultyName: difficultyNames[d.ratingClass.clamp(0, 4)],
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _UnlockRow extends StatelessWidget {
  final Difficulty difficulty;
  final Unlock? unlock;
  final String difficultyName;

  const _UnlockRow({
    required this.difficulty,
    required this.unlock,
    required this.difficultyName,
  });

  @override
  Widget build(BuildContext context) {
    final hasUnlock = unlock != null && unlock!.conditions.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          // 难度标签
          SizedBox(
            width: 40,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              decoration: BoxDecoration(
                color: _diffColor(
                  difficulty.ratingClass,
                ).withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                difficultyName,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: _diffColor(difficulty.ratingClass),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // 解锁状态
          Icon(
            hasUnlock ? Icons.lock : Icons.lock_open,
            size: 16,
            color: hasUnlock ? Colors.orange : Colors.green,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              hasUnlock ? unlock!.conditionsSummary : '无需解锁 (World模式默认可用)',
              style: TextStyle(
                fontSize: 13,
                color: hasUnlock ? null : Colors.grey,
              ),
            ),
          ),
          if (unlock?.lineNumber != null)
            Text(
              'L:${unlock!.lineNumber}',
              style: const TextStyle(fontSize: 10, color: Colors.grey),
            ),
        ],
      ),
    );
  }

  Color _diffColor(int rc) {
    const cs = [
      Color(0xFF95E1D3),
      Color(0xFFF7DC6F),
      Color(0xFFC0392B),
      Color(0xFF6C3483),
      Color(0xFF5DADE2),
    ];
    return rc >= 0 && rc < cs.length ? cs[rc] : Colors.grey;
  }
}
