import '../models/difficulty.dart';
import 'arc_storage.dart';

class SongImport {
  final ArcStorage storage;
  final String suggestedId;
  final List<ArcEntry> entries;
  final List<int> ratingClasses;

  SongImport._(
    this.storage,
    this.suggestedId,
    this.entries,
    this.ratingClasses,
  );

  static Future<SongImport> scan(String location) async {
    final storage = ArcStorage(location);
    final name = location.startsWith('content://')
        ? Uri.parse(location).pathSegments.last.split(RegExp(r'[:/]')).last
        : location
              .split(RegExp(r'[/\\]'))
              .where((part) => part.isNotEmpty)
              .last;
    return scanFolder(storage, name);
  }

  static Future<SongImport> scanFolder(ArcStorage storage, String name) async {
    final entries = await storage.list();
    final classes = _classes(entries);
    if (classes.isEmpty) {
      throw const FormatException('找不到可导入的谱面。请至少提供一个 0.aff 到 4.aff 文件。');
    }
    return SongImport._(storage, name, entries, classes);
  }

  bool hasFile(String name) => entries.any(
    (entry) =>
        entry.kind == EntryKind.file &&
        entry.name.toLowerCase() == name.toLowerCase(),
  );

  void validateDifficulties(Map<String, dynamic> song) {
    final entries = (song['difficulties'] as List).cast<Map<String, dynamic>>();
    final classes = entries.map((entry) => entry['ratingClass']).toSet();
    if (entries.length != ratingClasses.length ||
        !classes.containsAll(ratingClasses)) {
      throw const FormatException('难度条目与谱面文件不一致');
    }
  }

  Future<List<ArcEntry>> checkedEntries() async {
    final current = await storage.list();
    final classes = _classes(current);
    if (classes.join(',') != ratingClasses.join(',')) {
      throw StateError('源目录的谱面已变更，请重新选择');
    }
    return current;
  }

  static List<int> _classes(List<ArcEntry> entries) {
    final files = {
      for (final entry in entries)
        if (entry.kind == EntryKind.file) entry.name.toLowerCase(),
    };
    return RatingClass.values
        .where(
          (ratingClass) => files.contains(RatingClass.chartName(ratingClass)),
        )
        .toList();
  }
}
