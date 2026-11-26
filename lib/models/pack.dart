/// 曲包信息
class Pack {
  final String id;
  final String section;
  final String? image;
  final Map<String, String> nameLocalized;
  final Map<String, String> descriptionLocalized;
  final int plusCharacter;
  final bool isExtendPack;
  final bool customBanner;
  final bool cutoutPackImage;
  final bool smallPackImage;
  final String? packParent;

  /// 此曲包信息在 packlist 文件中的行号
  final int? lineNumber;

  const Pack({
    required this.id,
    required this.section,
    this.image,
    required this.nameLocalized,
    required this.descriptionLocalized,
    this.plusCharacter = -1,
    this.isExtendPack = true,
    this.customBanner = false,
    this.cutoutPackImage = false,
    this.smallPackImage = false,
    this.packParent,
    this.lineNumber,
  });

  factory Pack.fromJson(Map<String, dynamic> json, {int? lineNumber}) {
    return Pack(
      lineNumber: lineNumber,
      id: json['id'] ?? '',
      section: json['section'] ?? '',
      image: json['img'] as String?,
      nameLocalized:
          (json['name_localized'] as Map<String, dynamic>?)?.map(
            (k, v) => MapEntry(k, v.toString()),
          ) ??
          {},
      descriptionLocalized:
          (json['description_localized'] as Map<String, dynamic>?)?.map(
            (k, v) => MapEntry(k, v.toString()),
          ) ??
          {},
      plusCharacter: json['plus_character'] is int
          ? json['plus_character'] as int
          : -1,
      isExtendPack: json['is_extend_pack'] ?? true,
      customBanner: json['custom_banner'] ?? false,
      cutoutPackImage: json['cutout_pack_image'] ?? false,
      smallPackImage: json['small_pack_image'] ?? false,
      packParent: json['pack_parent'],
    );
  }

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{
      'id': id,
      'section': section,
      'name_localized': nameLocalized,
      'description_localized': descriptionLocalized,
      'plus_character': plusCharacter,
      'is_extend_pack': isExtendPack,
    };
    if (customBanner) map['custom_banner'] = true;
    if (cutoutPackImage) map['cutout_pack_image'] = true;
    if (smallPackImage) map['small_pack_image'] = true;
    if (packParent != null) map['pack_parent'] = packParent;
    if (image != null) map['img'] = image;
    return map;
  }

  String get displayName {
    return nameLocalized['en'] ??
        nameLocalized['ja'] ??
        nameLocalized['ko'] ??
        nameLocalized['zh-Hans'] ??
        nameLocalized['zh-Hant'] ??
        id;
  }

  /// 获取曲包对应的图片文件名（不带路径前缀和扩展名）
  String get packImageKey => id;

  String get sectionDisplay {
    switch (section) {
      case 'arcaea':
        return 'Arcaea';
      case 'mainstory':
        return '主线故事';
      case 'mainstory2':
        return '主线故事 II';
      case 'sidestory':
        return '支线故事';
      case 'collab':
        return '联动';
      default:
        return section;
    }
  }

  Pack copyWith({
    String? id,
    String? section,
    Map<String, String>? nameLocalized,
    Map<String, String>? descriptionLocalized,
    int? plusCharacter,
    bool? isExtendPack,
    bool? customBanner,
    bool? cutoutPackImage,
    bool? smallPackImage,
    String? packParent,
  }) {
    return Pack(
      id: id ?? this.id,
      section: section ?? this.section,
      image: image,
      nameLocalized: nameLocalized ?? this.nameLocalized,
      descriptionLocalized: descriptionLocalized ?? this.descriptionLocalized,
      plusCharacter: plusCharacter ?? this.plusCharacter,
      isExtendPack: isExtendPack ?? this.isExtendPack,
      customBanner: customBanner ?? this.customBanner,
      cutoutPackImage: cutoutPackImage ?? this.cutoutPackImage,
      smallPackImage: smallPackImage ?? this.smallPackImage,
      packParent: packParent ?? this.packParent,
    );
  }

  @override
  String toString() => 'Pack($id, $displayName)';
}
