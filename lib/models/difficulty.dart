/// 难度等级常量
class RatingClass {
  static const int past = 0;
  static const int present = 1;
  static const int future = 2;
  static const int beyond = 3;
  static const int eternal = 4;

  static const values = [past, present, future, beyond, eternal];

  static String chartName(int ratingClass) => '$ratingClass.aff';

  static List<String> jacketNames(int ratingClass, {bool smallFirst = false}) =>
      [
        if (smallFirst) ...[
          '1080_${ratingClass}_256.jpg',
          '${ratingClass}_256.jpg',
        ],
        '1080_$ratingClass.jpg',
        '$ratingClass.jpg',
        if (!smallFirst) ...[
          '1080_${ratingClass}_256.jpg',
          '${ratingClass}_256.jpg',
        ],
      ];

  static String toName(int ratingClass) {
    switch (ratingClass) {
      case past:
        return 'PST';
      case present:
        return 'PRS';
      case future:
        return 'FTR';
      case beyond:
        return 'BYD';
      case eternal:
        return 'ETR';
      default:
        return '???';
    }
  }

  static String toFullName(int ratingClass) {
    switch (ratingClass) {
      case past:
        return 'Past';
      case present:
        return 'Present';
      case future:
        return 'Future';
      case beyond:
        return 'Beyond';
      case eternal:
        return 'Eternal';
      default:
        return 'Unknown';
    }
  }

  static int fromName(String name) {
    switch (name.toUpperCase()) {
      case 'PST':
        return past;
      case 'PRS':
        return present;
      case 'FTR':
        return future;
      case 'BYD':
        return beyond;
      case 'ETR':
        return eternal;
      default:
        return -1;
    }
  }
}

/// 歌曲难度信息
class Difficulty {
  final int ratingClass;
  final String chartDesigner;
  final String jacketDesigner;
  final int rating;
  final bool ratingPlus;
  final bool jacketOverride;
  final bool audioOverride;
  final String bg;
  final String bgInverse;
  final double? bpmBase;
  final int? date;
  final String? version;
  final String? hiddenUntil;

  /// 歌曲在 songlist 文件中的行号（用于快速定位）
  final int? lineNumber;

  const Difficulty({
    required this.ratingClass,
    required this.chartDesigner,
    required this.jacketDesigner,
    required this.rating,
    this.ratingPlus = false,
    this.jacketOverride = false,
    this.audioOverride = false,
    this.bg = '',
    this.bgInverse = '',
    this.bpmBase,
    this.date,
    this.version,
    this.hiddenUntil,
    this.lineNumber,
  });

  factory Difficulty.fromJson(Map<String, dynamic> json) {
    return Difficulty(
      ratingClass: json['ratingClass'] ?? 0,
      chartDesigner: json['chartDesigner'] ?? '',
      jacketDesigner: json['jacketDesigner'] ?? '',
      rating: json['rating'] ?? 0,
      ratingPlus: json['ratingPlus'] ?? false,
      jacketOverride: json['jacketOverride'] ?? false,
      audioOverride: json['audioOverride'] ?? false,
      bg: json['bg'] ?? '',
      bgInverse: json['bg_inverse'] ?? '',
      bpmBase: (json['bpm_base'] as num?)?.toDouble(),
      date: json['date'],
      version: json['version'],
      hiddenUntil: json['hidden_until']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{
      'ratingClass': ratingClass,
      'chartDesigner': chartDesigner,
      'jacketDesigner': jacketDesigner,
      'rating': rating,
    };
    if (ratingPlus) map['ratingPlus'] = true;
    if (jacketOverride) map['jacketOverride'] = true;
    if (audioOverride) map['audioOverride'] = true;
    if (bg.isNotEmpty) map['bg'] = bg;
    if (bgInverse.isNotEmpty) map['bg_inverse'] = bgInverse;
    if (bpmBase != null) map['bpm_base'] = bpmBase;
    if (date != null) map['date'] = date;
    if (version != null) map['version'] = version;
    if (hiddenUntil != null) map['hidden_until'] = hiddenUntil;
    return map;
  }

  bool get isPermanentlyHidden => hiddenUntil == 'always';

  String get ratingDisplay {
    if (rating <= 0) return '?';
    final base = '$rating';
    if (ratingPlus) return '$base+';
    return base;
  }

  String get difficultyName => RatingClass.toName(ratingClass);

  @override
  String toString() => '${RatingClass.toName(ratingClass)} $ratingDisplay';
}
