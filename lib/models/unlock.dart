/// 解锁条件类型
class UnlockConditionType {
  static const int stepRequired = 101; // 需要步数
  static const int characterRequired = 104; // 需要角色
  // 更多类型可参考 Arcaea Wiki

  static String toName(int type) {
    switch (type) {
      case 101:
        return 'World阶梯步数';
      case 104:
        return '需要特定角色';
      default:
        return '条件类型 $type';
    }
  }
}

/// 解锁条件
class UnlockCondition {
  final int type;
  final int? min;
  final int? max;

  const UnlockCondition({required this.type, this.min, this.max});

  factory UnlockCondition.fromJson(Map<String, dynamic> json) {
    return UnlockCondition(
      type: json['type'] ?? 0,
      min: json['min'],
      max: json['max'],
    );
  }

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{'type': type};
    if (min != null) map['min'] = min;
    if (max != null) map['max'] = max;
    return map;
  }

  String get description {
    final name = UnlockConditionType.toName(type);
    if (min != null && max != null && min! > 0) {
      return '$name: $min~$max步';
    } else if (min != null && min! > 0) {
      return '$name: ≥$min步';
    }
    return name;
  }

  @override
  String toString() => description;
}

/// 歌曲解锁信息
class Unlock {
  final String songId;
  final int ratingClass;
  final List<UnlockCondition> conditions;

  /// 在 unlocks 文件中的行号
  final int? lineNumber;

  const Unlock({
    required this.songId,
    required this.ratingClass,
    required this.conditions,
    this.lineNumber,
  });

  factory Unlock.fromJson(Map<String, dynamic> json, {int? lineNumber}) {
    return Unlock(
      lineNumber: lineNumber,
      songId: json['songId'] ?? '',
      ratingClass: json['ratingClass'] ?? 0,
      conditions:
          (json['conditions'] as List<dynamic>?)
              ?.map((e) => UnlockCondition.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'songId': songId,
      'ratingClass': ratingClass,
      'conditions': conditions.map((c) => c.toJson()).toList(),
    };
  }

  String get difficultyName {
    switch (ratingClass) {
      case 0:
        return 'PST';
      case 1:
        return 'PRS';
      case 2:
        return 'FTR';
      case 3:
        return 'BYD';
      case 4:
        return 'ETR';
      default:
        return '???';
    }
  }

  String get conditionsSummary {
    return conditions.map((c) => c.description).join(' | ');
  }

  @override
  String toString() => 'Unlock($songId, $difficultyName)';
}
