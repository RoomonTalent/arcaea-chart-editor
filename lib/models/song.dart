import 'difficulty.dart';

/// 歌曲信息
class Song {
  static const coverNames = ['1080_base.jpg', 'base.jpg'];
  static const thumbnailNames = ['1080_base_256.jpg', 'base_256.jpg'];

  final int idx;
  final int? recordIndex;
  final bool isArc4;
  Object get recordKey => (id, recordIndex);
  final String id;
  final Map<String, String> titleLocalized;
  final String artist;
  final String bpm;
  final double bpmBase;
  final String set_; // pack id
  final String purchase;
  final int audioPreview;
  final int audioPreviewEnd;
  final int side;
  final String bg;
  final String bgInverse;
  final bool worldUnlock;
  final int date;
  final String version;
  final List<Difficulty> difficulties;

  /// 歌曲在 songlist 文件中的行号
  final int? lineNumber;

  /// 歌曲文件夹路径
  final String? folderPath;

  /// 歌曲文件夹下的文件列表（用于检查文件完整性）
  final List<String>? folderFiles;

  /// 是否有 3.aff (Beyond 难度铺面)
  final bool hasBeyondChart;

  /// 是否有 4.aff (Eternal 难度铺面)
  final bool hasEternalChart;

  const Song({
    required this.idx,
    this.recordIndex,
    this.isArc4 = false,
    required this.id,
    required this.titleLocalized,
    required this.artist,
    required this.bpm,
    required this.bpmBase,
    required this.set_,
    this.purchase = '',
    this.audioPreview = 0,
    this.audioPreviewEnd = 0,
    this.side = 0,
    this.bg = '',
    this.bgInverse = '',
    this.worldUnlock = false,
    this.date = 0,
    this.version = '',
    this.difficulties = const [],
    this.lineNumber,
    this.folderPath,
    this.folderFiles,
    this.hasBeyondChart = false,
    this.hasEternalChart = false,
  });

  factory Song.fromJson(
    Map<String, dynamic> json, {
    int? lineNumber,
    int? recordIndex,
    bool isArc4 = false,
  }) {
    return Song(
      lineNumber: lineNumber,
      recordIndex: recordIndex,
      isArc4: isArc4,
      idx: json['idx'] ?? 0,
      id: json['id'] ?? '',
      titleLocalized:
          (json['title_localized'] as Map<String, dynamic>?)?.map(
            (k, v) => MapEntry(k, v.toString()),
          ) ??
          {},
      artist: json['artist'] ?? '',
      bpm: json['bpm'] ?? '',
      bpmBase: (json['bpm_base'] ?? 0).toDouble(),
      set_: json['set'] ?? '',
      purchase: json['purchase'] ?? '',
      audioPreview: json['audioPreview'] ?? 0,
      audioPreviewEnd: json['audioPreviewEnd'] ?? 0,
      side: json['side'] ?? 0,
      bg: json['bg'] ?? '',
      bgInverse: json['bg_inverse'] ?? '',
      worldUnlock: json['world_unlock'] ?? false,
      date: json['date'] ?? 0,
      version: json['version'] ?? '',
      difficulties:
          ((json['difficulties'] ?? json['iculties']) as List<dynamic>?)
              ?.map((e) => Difficulty.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{
      'idx': idx,
      'id': id,
      'title_localized': titleLocalized,
      'artist': artist,
      'bpm': bpm,
      'bpm_base': bpmBase,
      'set': set_,
      'purchase': purchase,
      'audioPreview': audioPreview,
      'audioPreviewEnd': audioPreviewEnd,
      'side': side,
      'bg': bg,
      'bg_inverse': bgInverse,
      'date': date,
      'version': version,
      'difficulties': difficulties.map((d) => d.toJson()).toList(),
    };
    if (worldUnlock) map['world_unlock'] = true;
    return map;
  }

  String get displayTitle {
    return titleLocalized['en'] ??
        titleLocalized['ja'] ??
        titleLocalized['ko'] ??
        titleLocalized['zh-Hans'] ??
        titleLocalized['zh-Hant'] ??
        id;
  }

  /// 获取三个标准难度的信息
  Difficulty? get pastDifficulty => difficultyFor(RatingClass.past);
  Difficulty? get presentDifficulty => difficultyFor(RatingClass.present);
  Difficulty? get futureDifficulty => difficultyFor(RatingClass.future);
  Difficulty? get beyondDifficulty => difficultyFor(RatingClass.beyond);
  Difficulty? get eternalDifficulty => difficultyFor(RatingClass.eternal);

  Difficulty? difficultyFor(int ratingClass) => availableDifficulties
      .where((difficulty) => difficulty.ratingClass == ratingClass)
      .firstOrNull;

  /// 获取所有有效难度列表
  Iterable<Difficulty> get availableDifficulties => difficulties.where(
    (difficulty) =>
        !difficulty.isPermanentlyHidden && _hasDifficulty(difficulty),
  );

  bool _hasDifficulty(Difficulty difficulty) =>
      !isArc4 ||
      difficulty.rating > 0 ||
      (folderFiles?.any(
            (name) =>
                name.toLowerCase() ==
                RatingClass.chartName(difficulty.ratingClass),
          ) ??
          false);

  /// 难度数量
  int get difficultyCount => difficulties.length;

  Iterable<String> artworkNames({bool smallFirst = false}) sync* {
    if (smallFirst) yield* thumbnailNames;
    yield* coverNames;
    if (!smallFirst) yield* thumbnailNames;
    for (final difficulty in availableDifficulties) {
      if (difficulty.jacketOverride) {
        yield* RatingClass.jacketNames(
          difficulty.ratingClass,
          smallFirst: smallFirst,
        );
      }
    }
  }

  String? assetName(String name) {
    final files = folderFiles;
    if (files == null) return null;
    if (files.contains(name)) return name;
    final matches = files
        .where((file) => file.toLowerCase() == name.toLowerCase())
        .take(2)
        .toList();
    return matches.length == 1 ? matches.single : null;
  }

  bool get isFolderComplete => missingFiles.isEmpty;

  List<String> get missingFiles {
    final files = folderFiles;
    if (files == null) return [];
    final names = files.map((name) => name.toLowerCase()).toSet();
    final expected = difficulties.where(_hasDifficulty);
    final required = {
      if (expected.isEmpty || expected.any((item) => !item.audioOverride))
        'base.ogg',
      for (final difficulty in expected)
        if (RatingClass.values.contains(difficulty.ratingClass))
          RatingClass.chartName(difficulty.ratingClass),
      for (final difficulty in expected)
        if (difficulty.audioOverride) '${difficulty.ratingClass}.ogg',
    };
    return [
      ...required.where((name) => !names.contains(name)),
      if (!artworkNames().any(names.contains)) 'base.jpg 或 1080_base.jpg',
      for (final difficulty in expected)
        if (difficulty.jacketOverride &&
            !RatingClass.jacketNames(
              difficulty.ratingClass,
            ).any(names.contains))
          '难度 ${difficulty.difficultyName} 封面',
    ];
  }

  Song copyWith({
    int? idx,
    String? id,
    Map<String, String>? titleLocalized,
    String? artist,
    String? bpm,
    double? bpmBase,
    String? set_,
    String? purchase,
    int? audioPreview,
    int? audioPreviewEnd,
    int? side,
    String? bg,
    String? bgInverse,
    bool? worldUnlock,
    int? date,
    String? version,
    List<Difficulty>? difficulties,
    String? folderPath,
    List<String>? folderFiles,
    bool? hasBeyondChart,
    bool? hasEternalChart,
  }) {
    return Song(
      idx: idx ?? this.idx,
      recordIndex: recordIndex,
      isArc4: isArc4,
      id: id ?? this.id,
      titleLocalized: titleLocalized ?? this.titleLocalized,
      artist: artist ?? this.artist,
      bpm: bpm ?? this.bpm,
      bpmBase: bpmBase ?? this.bpmBase,
      set_: set_ ?? this.set_,
      purchase: purchase ?? this.purchase,
      audioPreview: audioPreview ?? this.audioPreview,
      audioPreviewEnd: audioPreviewEnd ?? this.audioPreviewEnd,
      side: side ?? this.side,
      bg: bg ?? this.bg,
      bgInverse: bgInverse ?? this.bgInverse,
      worldUnlock: worldUnlock ?? this.worldUnlock,
      date: date ?? this.date,
      version: version ?? this.version,
      difficulties: difficulties ?? this.difficulties,
      lineNumber: lineNumber,
      folderPath: folderFiles == null
          ? folderPath ?? this.folderPath
          : folderPath,
      folderFiles: folderFiles ?? this.folderFiles,
      hasBeyondChart: hasBeyondChart ?? this.hasBeyondChart,
      hasEternalChart: hasEternalChart ?? this.hasEternalChart,
    );
  }

  @override
  String toString() => 'Song($idx, $id, $displayTitle)';
}
