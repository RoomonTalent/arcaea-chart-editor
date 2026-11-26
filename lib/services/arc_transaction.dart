import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'arc_storage.dart';
import 'file_service.dart';

typedef ManifestChanges = Map<String, String>;
typedef SongDirectoryImport = ({ArcStorage storage, List<ArcEntry> entries});

/// Recovers a group of same-directory renames after an exception or restart.
class ArcTransaction {
  static const _journal = FileService.recoveryJournal;
  static const _committed = '.arcaea-manager-committed.bin';

  final ArcStorage storage;
  ArcStorage? get _game => FileService.arcExtRootFor(storage);
  ArcTransaction(this.storage);

  Future<void> recover() async {
    if (await storage.kind(_journal) == null) {
      // A provider may have retained the commit marker after journal cleanup.
      await storage.removeFile(_committed);
      return;
    }
    final plan = _TransactionPlan.fromJson(
      jsonDecode(utf8.decode(await storage.read(_journal)))
          as Map<String, dynamic>,
    );
    final committed = await storage.kind(_committed) != null;
    for (final path in plan.packFiles) {
      final stage = plan.backgroundStage(path);
      if (committed &&
          await storage.kind(path) == null &&
          await storage.kind(stage) == EntryKind.file) {
        await storage.rename(stage, path);
      } else {
        await storage.removeFile(stage);
      }
    }
    if (_game case final game?) {
      for (final path in plan.backgrounds) {
        final stage = plan.backgroundStage(path);
        if (committed &&
            await game.kind(path) == null &&
            await game.kind(stage) == EntryKind.file) {
          await game.rename(stage, path);
        } else {
          await game.removeFile(stage);
        }
      }
    }
    if (!committed) {
      for (final path in plan.removedPackFiles) {
        final backup = plan.removedPackFile(path);
        if (await storage.kind(backup) == EntryKind.file) {
          await storage.rename(backup, path);
        }
      }
      for (final id in plan.importIds) {
        if (await storage.kind(plan.importReady(id)) != null &&
            await storage.kind(plan.importStage(id)) == null &&
            await storage.kind(id) == EntryKind.directory) {
          await storage.rename(id, plan.importStage(id));
        }
      }
      for (final id in plan.deleteIds) {
        final held = plan.quarantine(id);
        if (await storage.kind(held) != null) await storage.rename(held, id);
      }
      for (final name in plan.manifests) {
        final backup = plan.backup(name);
        if (await storage.kind(backup) == null) continue;
        await storage.removeFile(name);
        await storage.rename(backup, name);
      }
    }
    for (final name in plan.manifests) {
      await storage.removeFile(plan.staged(name));
      final backup = plan.backup(name);
      if (committed &&
          (plan.keepBackups ||
              plan.deleteIds.isNotEmpty ||
              plan.removedPackFiles.isNotEmpty) &&
          await storage.kind(backup) != null) {
        await storage.rename(backup, plan.deletedManifest(name));
      } else {
        await storage.removeFile(backup);
      }
    }
    for (final id in plan.importIds) {
      await storage.removeFile(plan.importReady(id));
      if (await storage.kind(plan.importStage(id)) == EntryKind.directory) {
        await storage.child(plan.importStage(id)).clearStage();
        await storage.removeEmptyDirectory(plan.importStage(id));
      }
    }
    await storage.removeFile(_journal);
    await storage.removeFile(_committed);
  }

  Future<void> run(
    ManifestChanges changes, {
    required Map<String, Uint8List> original,
    String? importId,
    ArcStorage? source,
    List<ArcEntry> sourceEntries = const [],
    List<String> deleteIds = const [],
    bool keepBackups = false,
    Map<String, String> backgrounds = const {},
    ArcStorage? backgroundSource,
    Map<String, SongDirectoryImport> imports = const {},
    Map<String, String> packFiles = const {},
    ArcStorage? packSource,
    List<String> removedPackFiles = const [],
  }) async {
    await recover();
    final game = _game;
    if (game == null && backgrounds.isNotEmpty) {
      throw StateError('此歌曲包包含共享背景，请授权完整的 Arc4 或 ArcExt 目录后重新导入');
    }
    final missing = <String, String>{};
    final songsToCopy = {...imports};
    if (importId != null) {
      songsToCopy[importId] = (storage: source!, entries: sourceEntries);
    }
    final missingPackFiles = <String, String>{};
    for (final entry in packFiles.entries) {
      _TransactionPlan.validatePackFile(entry.key);
      if (await storage.kind(entry.key) == null) {
        missingPackFiles[entry.key] = entry.value;
      }
    }
    if (game != null) {
      for (final entry in backgrounds.entries) {
        _TransactionPlan.validateBackground(entry.key);
        if (await game.kind(entry.key) == null) {
          missing[entry.key] = entry.value;
        }
      }
    }
    final plan = _TransactionPlan(
      DateTime.now().microsecondsSinceEpoch.toString(),
      changes.keys.toList(),
      songsToCopy.keys.toList(),
      deleteIds,
      missing.keys.toList(),
      missingPackFiles.keys.toList(),
      removedPackFiles,
      keepBackups,
    );
    plan.validate();

    final stagedJournal = plan.staged('journal');
    try {
      await storage.write(stagedJournal, _utf8(jsonEncode(plan.toJson())));
      await storage.rename(stagedJournal, _journal);
      for (final name in plan.manifests) {
        await storage.write(plan.staged(name), _utf8(changes[name]!));
      }
      for (final entry in songsToCopy.entries) {
        final id = entry.key;
        await storage.createDirectory(plan.importStage(id));
        await entry.value.storage.copyTreeTo(
          storage.child(plan.importStage(id)),
          entries: entry.value.entries,
        );
        if (await storage.kind(id) != null) {
          throw StateError('歌曲目录已存在：$id');
        }
      }
      for (final entry in missingPackFiles.entries) {
        for (final folder in [
          'pack',
          if (entry.key.startsWith('pack/1080/')) 'pack/1080',
        ]) {
          if (await storage.kind(folder) == null) {
            await storage.createDirectory(folder);
          }
        }
        await packSource!.copyTo(
          entry.value,
          storage,
          plan.backgroundStage(entry.key),
        );
      }
      if (game != null) {
        for (final entry in missing.entries) {
          var directory = '';
          for (final part in entry.key.split('/')..removeLast()) {
            directory = directory.isEmpty ? part : '$directory/$part';
            if (await game.kind(directory) == null) {
              await game.createDirectory(directory);
            }
          }
          await backgroundSource!.copyTo(
            entry.value,
            game,
            plan.backgroundStage(entry.key),
          );
        }
      }
      for (final entry in original.entries) {
        if (!listEquals(await storage.read(entry.key), entry.value)) {
          throw StateError('${entry.key} 已被其他程序修改，请重新扫描');
        }
      }
      for (final name in plan.manifests) {
        await storage.rename(name, plan.backup(name));
        await storage.rename(plan.staged(name), name);
      }
      for (final id in songsToCopy.keys) {
        await storage.write(plan.importReady(id), Uint8List(0));
        await storage.rename(plan.importStage(id), id);
      }
      for (final id in deleteIds) {
        // Keep the original audio and charts available for manual restoration.
        if (await storage.kind(id) == EntryKind.directory) {
          await storage.rename(id, plan.quarantine(id));
        }
      }
      for (final path in removedPackFiles) {
        if (await storage.kind(path) == EntryKind.file) {
          await storage.rename(path, plan.removedPackFile(path));
        }
      }
      await storage.write(_committed, Uint8List(0));
    } catch (error) {
      // The write may have succeeded on the provider despite a communication error.
      if (await storage.kind(_committed) == null) {
        try {
          await recover();
          await storage.removeFile(stagedJournal);
        } catch (rollbackError) {
          throw StateError('写入失败：$error。恢复失败：$rollbackError。请重新扫描以重试恢复。');
        }
        rethrow;
      }
    }
    try {
      await recover();
    } catch (_) {
      // A committed operation is durable. The next scan can retry cleanup.
    }
  }

  Uint8List _utf8(String text) => Uint8List.fromList(utf8.encode(text));
}

class _TransactionPlan {
  final String token;
  final List<String> manifests;
  final List<String> importIds;
  final List<String> deleteIds;
  final List<String> backgrounds;
  final List<String> packFiles;
  final List<String> removedPackFiles;
  final bool keepBackups;

  _TransactionPlan(
    this.token,
    this.manifests,
    this.importIds,
    this.deleteIds,
    this.backgrounds,
    this.packFiles,
    this.removedPackFiles,
    this.keepBackups,
  );

  factory _TransactionPlan.fromJson(Map<String, dynamic> json) {
    return _TransactionPlan(
      json['token'] as String,
      List<String>.from(json['manifests'] as List),
      json['importIds'] == null
          ? [if (json['importId'] case final String id) id]
          : List<String>.from(json['importIds'] as List),
      List<String>.from(json['deleteIds'] as List),
      List<String>.from(json['backgrounds'] as List? ?? const []),
      List<String>.from(json['packFiles'] as List? ?? const []),
      List<String>.from(json['removedPackFiles'] as List? ?? const []),
      json['keepBackups'] == true,
    )..validate();
  }

  void validate() {
    if (!RegExp(r'^\d+$').hasMatch(token) ||
        manifests.isEmpty ||
        !manifests.every(FileService.manifests.contains) ||
        manifests.toSet().length != manifests.length) {
      throw const FormatException('恢复日志格式无效');
    }
    for (final id in importIds) {
      FileService.validateId(id);
    }
    for (final id in deleteIds) {
      FileService.validateId(id);
    }
    for (final path in backgrounds) {
      validateBackground(path);
    }
    for (final path in [...packFiles, ...removedPackFiles]) {
      validatePackFile(path);
    }
  }

  static void validatePackFile(String path) {
    if (!ArcStorage.isSafeRelativePath(path) ||
        !RegExp(
          r'^pack/(?:1080/)?[^/]+\.(?:png|jpe?g|webp)$',
          caseSensitive: false,
        ).hasMatch(path)) {
      throw const FormatException('导入包的曲包素材路径无效');
    }
  }

  static void validateBackground(String path) {
    if (FileService.backgroundIdFromPath(path) == null) {
      throw const FormatException('导入包的背景路径无效');
    }
  }

  Map<String, dynamic> toJson() => {
    'token': token,
    'manifests': manifests,
    'importIds': importIds,
    'deleteIds': deleteIds,
    if (backgrounds.isNotEmpty) 'backgrounds': backgrounds,
    if (packFiles.isNotEmpty) 'packFiles': packFiles,
    if (removedPackFiles.isNotEmpty) 'removedPackFiles': removedPackFiles,
    if (keepBackups) 'keepBackups': true,
  };

  String staged(String name) => '.arcaea-manager-stage-$token-$name.bin';
  String backup(String name) => '.arcaea-manager-backup-$token-$name.bin';
  String _importSuffix(String id) =>
      importIds.length <= 1 ? token : '$token-$id';
  String importReady(String id) =>
      '.arcaea-manager-ready-${_importSuffix(id)}.bin';
  String importStage(String id) =>
      '.arcaea-manager-import-${_importSuffix(id)}';
  String deletedManifest(String name) =>
      '.arcaea-manager-removed-$token-$name.json';
  String quarantine(String id) => '.arcaea-manager-removed-$token-$id';
  String backgroundStage(String path) => _backgroundMarker(path, 'stage');
  String removedPackFile(String path) => _backgroundMarker(path, 'removed');
  String _backgroundMarker(String path, String marker) {
    final cut = path.lastIndexOf('/');
    return '${path.substring(0, cut)}/.arcaea-manager-$marker-$token-${path.substring(cut + 1)}';
  }
}
