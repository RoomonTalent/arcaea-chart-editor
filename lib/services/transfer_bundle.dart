import 'dart:convert';
import 'dart:typed_data';

import 'arc_storage.dart';

/// A portable directory with a completion manifest written after the assets.
class TransferBundle {
  static const manifest = 'transfer.json';

  static Future<Map<String, dynamic>> read(
    ArcStorage source,
    String type, {
    String? alternateType,
  }) async {
    final bytes = await source.read(manifest);
    if (bytes.length > 4 * 1024 * 1024) {
      throw const FormatException('导入包的目录清单过大');
    }
    final data = jsonDecode(utf8.decode(bytes));
    if (data is! Map<String, dynamic> ||
        data['version'] != 1 ||
        (data['type'] != type &&
            (alternateType == null || data['type'] != alternateType))) {
      throw const FormatException('导入包类型或版本不匹配');
    }
    return data;
  }

  static Future<void> ensureParents(ArcStorage target, String path) async {
    var directory = '';
    for (final part in path.split('/')..removeLast()) {
      directory = directory.isEmpty ? part : '$directory/$part';
      if (await target.kind(directory) == null) {
        await target.createDirectory(directory);
      }
    }
  }

  static Future<String> write({
    required ArcStorage destination,
    required String name,
    required String type,
    required Map<String, dynamic> data,
    required Future<void> Function(ArcStorage) writeAssets,
  }) async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final output = '$type-$name-$stamp';
    final staging = '.arcaea-transfer-$stamp';
    await destination.createDirectory(staging);
    final folder = destination.child(staging);
    try {
      await writeAssets(folder);
      await folder.write(
        manifest,
        Uint8List.fromList(
          utf8.encode(
            const JsonEncoder.withIndent(
              '  ',
            ).convert({'type': type, 'version': 1, ...data}),
          ),
        ),
      );
      await destination.rename(staging, output);
    } catch (_) {
      if (await destination.kind(staging) == EntryKind.directory) {
        await folder.clearStage();
        await destination.removeEmptyDirectory(staging);
      } else if (await destination.kind(output) == EntryKind.directory) {
        return destination.displayPath(output);
      }
      rethrow;
    }
    return destination.displayPath(output);
  }
}
