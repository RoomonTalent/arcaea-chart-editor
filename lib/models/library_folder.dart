import 'package:path/path.dart' as p;

class LibraryFolder {
  const LibraryFolder(
    this.location, {
    this.name,
    this.folderName,
    this.prefix,
    this.catalogIdentity,
  });

  final String location;
  final String? name;
  final String? folderName;
  final String? prefix;
  final String? catalogIdentity;

  String get displayPath => location.startsWith('content://')
      ? Uri.parse(location).pathSegments.last
      : location;

  String get defaultName {
    if (folderName case final name? when name.isNotEmpty) return name;
    if (location.startsWith('content://')) {
      return displayPath
              .split(RegExp(r'[:/]'))
              .where((part) => part.isNotEmpty)
              .lastOrNull ??
          displayPath;
    }
    final basename = p.basename(p.normalize(location));
    return basename.isEmpty ? location : basename;
  }

  String get displayName => name ?? defaultName;

  LibraryFolder withName(String? value) => LibraryFolder(
    location,
    name: value,
    folderName: folderName,
    prefix: prefix,
    catalogIdentity: catalogIdentity,
  );

  factory LibraryFolder.fromJson(Map<String, dynamic> json) => LibraryFolder(
    json['location'] as String,
    name: json['name'] as String?,
    folderName: json['folderName'] as String?,
    prefix: json['prefix'] as String?,
    catalogIdentity: json['catalogIdentity'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'location': location,
    'name': name,
    'folderName': folderName,
    'prefix': prefix,
    'catalogIdentity': catalogIdentity,
  };
}
