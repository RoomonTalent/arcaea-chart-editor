import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_state.dart';
import '../services/file_service.dart';
import '../models/difficulty.dart';
import 'arc_image.dart';
import 'catalog_action.dart';
import '../models/pack.dart';
import '../models/song.dart';
import 'song_detail_page.dart';

class PackDetailPage extends StatefulWidget {
  final Pack pack;
  const PackDetailPage({super.key, required this.pack});

  @override
  State<PackDetailPage> createState() => _PackDetailPageState();
}

class _PackDetailPageState extends State<PackDetailPage> {
  late TextEditingController _nameCtrl;
  String _selSection = '';
  bool _hasChanges = false;

  static const _sections = {
    'arcaea': 'Arcaea',
    'mainstory': '主线故事',
    'mainstory2': '主线故事 II',
    'sidestory': '支线故事',
    'collab': '联动',
  };

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(
      text: widget.pack.nameLocalized['en'] ?? '',
    );
    _selSection = widget.pack.section;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  void _markChanged() {
    if (!_hasChanges) setState(() => _hasChanges = true);
  }

  Future<void> _save(AppState state) async {
    final current = state.packs
        .where((pack) => pack.id == widget.pack.id)
        .firstOrNull;
    if (current == null) return;
    final name = _nameCtrl.text.trim();
    final changes = <String, dynamic>{
      if (_nameCtrl.text != (current.nameLocalized['en'] ?? ''))
        'name_localized': {'en': name},
      if (_selSection != current.section) 'section': _selSection,
    };
    if (changes.isEmpty) {
      setState(() => _hasChanges = false);
      return;
    }
    final saved = await catalogAction(
      context,
      () => state.updatePack(current.id, changes),
      success: '曲包信息已保存',
    );
    if (saved && mounted) setState(() => _hasChanges = false);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
        // 获取最新数据
        final pack =
            state.packs.where((p) => p.id == widget.pack.id).firstOrNull ??
            widget.pack;
        final packSongs = state.songsByPack[pack.id] ?? [];
        final sections = {
          ..._sections,
          if (!_sections.containsKey(pack.section))
            pack.section: pack.section.isEmpty ? '其他' : pack.section,
        };

        return Scaffold(
          appBar: AppBar(
            title: Text(pack.displayName),
            actions: [
              if (_hasChanges)
                IconButton(
                  icon: const Icon(Icons.save),
                  tooltip: '保存修改',
                  onPressed: state.isBusy ? null : () => _save(state),
                ),
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 曲包图片
                Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      width: 200,
                      height: 120,
                      child: ArcImage(
                        candidates: FileService.packImages(
                          pack.id,
                          parent: pack.packParent,
                          image: pack.image,
                        ),
                        fallback: _placeholder(),
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // 可编辑字段
                Text(
                  '编辑曲包信息',
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
                          controller: _nameCtrl,
                          enabled: !state.isBusy,
                          decoration: const InputDecoration(
                            labelText: '曲包名称 (英文)',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          onChanged: (_) => _markChanged(),
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<String>(
                          initialValue: _selSection,
                          decoration: const InputDecoration(
                            labelText: '分类',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          items: sections.entries
                              .map(
                                (e) => DropdownMenuItem(
                                  value: e.key,
                                  child: Text(e.value),
                                ),
                              )
                              .toList(),
                          onChanged: state.isBusy
                              ? null
                              : (v) {
                                  if (v != null) {
                                    setState(() => _selSection = v);
                                    _markChanged();
                                  }
                                },
                        ),
                      ],
                    ),
                  ),
                ),

                const Divider(height: 32),

                // 曲包信息（只读）
                Text(
                  '详细信息',
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
                        _InfoRow('ID', pack.id),
                        _InfoRow('分类', _sections[pack.section] ?? pack.section),
                        _InfoRow('扩展包', pack.isExtendPack ? '是' : '否'),
                        if (pack.packParent != null)
                          _InfoRow('父曲包', pack.packParent!),
                        _InfoRow('歌曲数量', '${packSongs.length}'),
                        _InfoRow('图片文件', '1080_select_${pack.id}.png'),
                      ],
                    ),
                  ),
                ),

                const Divider(height: 32),

                // 此曲包下的歌曲列表
                Row(
                  children: [
                    Text(
                      '曲包歌曲 (${packSongs.length})',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    if (pack.lineNumber != null)
                      Text(
                        'packlist L:${pack.lineNumber}',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),

                if (packSongs.isEmpty)
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(
                        child: Text(
                          '此曲包下暂无歌曲',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    ),
                  )
                else
                  ...packSongs.map(
                    (song) => _SongTile(
                      song: song,
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => SongDetailPage(song: song),
                          ),
                        );
                      },
                    ),
                  ),

                const SizedBox(height: 32),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _placeholder() {
    return Container(
      color: Colors.grey.withValues(alpha: 0.2),
      child: const Icon(Icons.album, size: 48, color: Colors.grey),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label, value;
  const _InfoRow(this.label, this.value);
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

/// 歌曲列表项（用于曲包详情页）
class _SongTile extends StatelessWidget {
  final Song song;
  final VoidCallback onTap;

  const _SongTile({required this.song, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final diffs = song.availableDifficulties;
    return Card(
      margin: const EdgeInsets.only(bottom: 4),
      child: ListTile(
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            width: 44,
            height: 44,
            child: ArcImage(
              candidates: FileService.songImages(song, smallFirst: true),
              fallback: const Icon(Icons.music_note),
              cacheWidth: 96,
            ),
          ),
        ),
        title: Text(
          song.displayTitle,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
        subtitle: Wrap(
          spacing: 4,
          runSpacing: 2,
          children: diffs.map((d) {
            final c = _diffColor(d.ratingClass);
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: c.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                '${RatingClass.toName(d.ratingClass)} ${d.ratingDisplay}',
                style: TextStyle(
                  fontSize: 10,
                  color: c,
                  fontWeight: FontWeight.bold,
                ),
              ),
            );
          }).toList(),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
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
