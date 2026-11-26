import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'arc_storage.dart';

typedef CatalogIndex = ({String fingerprint, Map<String, SongFolder> files});

class CacheService {
  static const _version = 3;
  Future<Directory> get _directory async => Directory(
    p.join((await getApplicationCacheDirectory()).path, 'arcaea_manager'),
  );

  Future<File> _index(String identity) async {
    // A collision is handled by checking the full directory identity in the cache.
    var hash = 0x811c9dc5;
    for (final codeUnit in identity.codeUnits) {
      hash = ((hash ^ codeUnit) * 0x01000193) & 0xffffffff;
    }
    return File(
      p.join((await _directory).path, 'arc_${hash.toRadixString(16)}.json'),
    );
  }

  Future<CatalogIndex?> load(String identity) async {
    try {
      final file = await _index(identity);
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (json['version'] != _version || json['identity'] != identity) {
        return null;
      }
      final files = (json['folderFiles'] as Map<String, dynamic>).map((
        id,
        value,
      ) {
        final folder = value as Map<String, dynamic>;
        final name = folder['name'] as String;
        if (!ArcStorage.isSongDirectoryName(name)) {
          throw const FormatException('无效的歌曲目录');
        }
        return MapEntry(id, (
          name: name,
          files: List<String>.from(folder['files'] as List),
        ));
      });
      return (fingerprint: json['fingerprint'] as String, files: files);
    } catch (_) {
      // An unavailable or corrupt cache can always be rebuilt.
      return null;
    }
  }

  Future<void> save(
    String identity,
    String fingerprint,
    Map<String, SongFolder> folderFiles,
  ) async {
    try {
      final file = await _index(identity);
      await file.parent.create(recursive: true);
      final staged = File('${file.path}.tmp');
      await staged.writeAsString(
        jsonEncode({
          'version': _version,
          'identity': identity,
          'fingerprint': fingerprint,
          'folderFiles': folderFiles.map(
            (id, folder) =>
                MapEntry(id, {'name': folder.name, 'files': folder.files}),
          ),
        }),
        flush: true,
      );
      await staged.rename(file.path);
    } catch (_) {
      // A failed cache write does not invalidate a successful resource scan.
    }
  }

  Future<void> clearAllCache() async {
    final directory = await _directory;
    if (!await directory.exists()) return;
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is File && p.basename(entry.path).startsWith('arc_')) {
        await entry.delete();
      }
    }
  }
}
