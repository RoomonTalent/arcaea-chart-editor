import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum EntryKind { file, directory, other }

typedef ArcEntry = ({String name, EntryKind kind});
typedef SongFolder = ({String name, List<String> files});

/// A selected directory, with all operations restricted to its descendants.
class ArcStorage {
  static const _channel = MethodChannel('arcaea_manager/treestorage');
  static Future<void> _pendingAccess = Future.value();
  static final _artworkRevisions = <String, int>{};
  final String location;
  final String prefix;
  String? _folderName;
  String? get folderName => _folderName;
  int get artworkVersion => _artworkRevisions[location] ?? 0;

  ArcStorage(this.location, {this.prefix = ''});

  static Future<String?> pick(String title, {bool persist = true}) {
    if (Platform.isAndroid) {
      return _channel.invokeMethod<String>('pick', {'persist': persist});
    }
    return FilePicker.platform.getDirectoryPath(dialogTitle: title);
  }

  static Future<String?> pickExportDirectory(String title) {
    if (Platform.isAndroid) {
      return _channel.invokeMethod<String>('pick', {
        'persist': false,
        'write': true,
      });
    }
    return FilePicker.platform.getDirectoryPath(dialogTitle: title);
  }

  static Future<void> releaseSelection(String location) async {
    if (!location.startsWith('content://')) return;
    try {
      await _channel.invokeMethod<void>('releasePermission', {
        'tree': location,
      });
    } on PlatformException {
      // The provider may have already revoked the grant.
    }
  }

  static Future<String?> selectedFolderName(String location) async {
    if (!location.startsWith('content://')) return null;
    try {
      return await _channel.invokeMethod<String>('selectedFolderName', {
        'tree': location,
      });
    } on PlatformException {
      return null;
    }
  }

  bool get _isTree => location.startsWith('content://');
  late final _canonicalRoot = Directory(location).resolveSymbolicLinks();
  String displayPath(String name) {
    final relative = _relative(name);
    if (!_isTree) return p.joinAll([location, ...relative.split('/')]);
    final selected = Uri.parse(location).pathSegments.last;
    return '$selected/$relative';
  }

  String get identity => '$location|$prefix';

  /// Identifies the songs directory independently of the selected parent.
  Future<String> catalogIdentity() async {
    final relative = _relative('');
    if (_isTree) {
      _folderName = await selectedFolderName(location);
      final document = await _channel.invokeMethod<String>(
        'directoryId',
        _args(relative),
      );
      if (document == null) throw StateError('找不到歌曲目录');
      return 'tree:${Uri.parse(location).authority}:$document';
    }
    final path = await Directory(
      await _diskPath(relative),
    ).resolveSymbolicLinks();
    return Platform.isWindows ? path.toLowerCase() : path;
  }

  bool get isArc4 {
    if (prefix.startsWith('Arc4/')) return true;
    if (prefix.startsWith('ArcExt/')) return false;
    final components = _isTree
        ? Uri.parse(location).pathSegments.last.split(RegExp(r'[:/]'))
        : p.split(p.normalize(location));
    final selected = (folderName ?? components.last).toLowerCase();
    return selected == 'arc4' ||
        (prefix.isEmpty &&
            selected == 'songs' &&
            components.length >= 2 &&
            components[components.length - 2].toLowerCase() == 'arc4');
  }

  /// A shared lock keeps recovery from interpreting an active write as interrupted.
  Future<T> withLock<T>(Future<T> Function() action) =>
      _locked(action, write: true);

  Future<T> withReadLock<T>(Future<T> Function() action) =>
      _locked(action, write: false);

  Future<T> _locked<T>(
    Future<T> Function() action, {
    required bool write,
  }) async {
    final previous = _pendingAccess;
    final finished = Completer<void>();
    _pendingAccess = finished.future;
    try {
      await previous;
      final name = '.arcaea-manager-lock.bin';
      final path = _isTree
          ? p.join((await getApplicationSupportDirectory()).path, name)
          : await _diskPath(_relative(name));
      final file = File(path);
      if (!write && !await file.exists()) return await action();
      final lock = await file.open(
        mode: write ? FileMode.append : FileMode.read,
      );
      try {
        await lock.lock(
          write ? FileLock.blockingExclusive : FileLock.blockingShared,
        );
        return await action();
      } finally {
        await lock.close();
      }
    } finally {
      finished.complete();
    }
  }

  ArcStorage child(String directory) =>
      ArcStorage(location, prefix: _relative(directory));

  String _relative(String name) {
    final parts = [
      if (prefix.isNotEmpty) ...prefix.split('/'),
      if (name.isNotEmpty) ...name.split('/'),
    ];
    if (parts.any((part) => !_isPathComponent(part))) {
      throw FormatException('无效的相对路径 $name');
    }
    return parts.join('/');
  }

  static final _invalidComponent = RegExp(r'[<>:"/\\|?*\x00-\x1f]');
  static final _windowsDevice = RegExp(
    r'^(con|prn|aux|nul|com[1-9¹²³]|lpt[1-9¹²³])$',
    caseSensitive: false,
  );
  static final _trailingDotsAndSpaces = RegExp(r'[. ]+$');

  static String songDirectoryKey(String name) =>
      name.replaceFirst(_trailingDotsAndSpaces, '').toLowerCase();

  static bool _isPathComponent(String name) =>
      name.isNotEmpty &&
      !_invalidComponent.hasMatch(name) &&
      !_trailingDotsAndSpaces.hasMatch(name) &&
      !_windowsDevice.hasMatch(name.split('.').first.trimRight());

  static bool isSongDirectoryName(String name) =>
      _isPathComponent(name) &&
      !name.toLowerCase().startsWith('.arcaea-manager-') &&
      !const [
        'pack',
        'packlist',
        'songlist',
        'unlocks',
      ].contains(name.toLowerCase());

  static bool isSafeRelativePath(String name) {
    final parts = name.split('/');
    return parts.length <= 32 &&
        parts.every((part) => _isPathComponent(part) && part.length <= 200);
  }

  Future<String> _diskPath(String relative) async {
    // Canonicalize the selected root and reject links inside that root.
    var result = await _canonicalRoot;
    if (relative.isEmpty) return result;
    for (final part in relative.split('/')) {
      result = p.join(result, part);
      if (await FileSystemEntity.type(result, followLinks: false) ==
          FileSystemEntityType.link) {
        throw FileSystemException('资源目录中包含链接', result);
      }
    }
    return result;
  }

  Map<String, Object?> _args(String relative) => {
    'tree': location,
    'path': relative,
  };

  Future<EntryKind?> kind(String name) async {
    final relative = _relative(name);
    if (_isTree) {
      return switch (await _channel.invokeMethod<String>(
        'kind',
        _args(relative),
      )) {
        'file' => EntryKind.file,
        'directory' => EntryKind.directory,
        null => null,
        _ => EntryKind.other,
      };
    }
    return switch (await FileSystemEntity.type(
      await _diskPath(relative),
      followLinks: false,
    )) {
      FileSystemEntityType.file => EntryKind.file,
      FileSystemEntityType.directory => EntryKind.directory,
      FileSystemEntityType.notFound => null,
      _ => EntryKind.other,
    };
  }

  Future<List<ArcEntry>> list([String name = '']) async {
    final relative = _relative(name);
    if (_isTree) {
      final entries = await _channel.invokeListMethod<List<Object?>>(
        'list',
        _args(relative),
      );
      return entries!
          .map(
            (entry) => (
              name: entry[0] as String,
              kind: entry[1] == 'directory'
                  ? EntryKind.directory
                  : EntryKind.file,
            ),
          )
          .toList();
    }
    final result = <ArcEntry>[];
    final dir = Directory(await _diskPath(relative));
    await for (final entry in dir.list(followLinks: false)) {
      result.add((
        name: p.basename(entry.path),
        kind: switch (entry) {
          Directory() => EntryKind.directory,
          File() => EntryKind.file,
          _ => EntryKind.other,
        },
      ));
    }
    return result;
  }

  Future<Map<String, String>> songDirectories(Iterable<String> ids) async {
    final exact = <String>{};
    final aliases = <String, String?>{};
    for (final entry in await list()) {
      if (entry.kind != EntryKind.directory ||
          !isSongDirectoryName(entry.name)) {
        continue;
      }
      exact.add(entry.name);
      final key = songDirectoryKey(entry.name);
      aliases[key] = aliases.containsKey(key) ? null : entry.name;
    }
    final resolved = <String, String>{};
    for (final id in ids.toSet()) {
      final key = songDirectoryKey(id);
      final name = exact.contains(id) ? id : aliases[key];
      if (name != null) resolved[id] = name;
    }
    return resolved;
  }

  Future<Map<String, SongFolder>> listSongFiles(Iterable<String> ids) async {
    final directories = await songDirectories(ids);
    final names = directories.values.toSet();
    final Map<String, List<String>> files;
    if (_isTree) {
      final result = await _channel.invokeMapMethod<String, List<Object?>>(
        'songFiles',
        {..._args(_relative('')), 'ids': names.toList()},
      );
      files = result!.map((key, value) => MapEntry(key, value.cast<String>()));
    } else {
      files = {
        for (final name in names)
          name: [
            for (final entry in await list(name))
              if (entry.kind == EntryKind.file) entry.name,
          ],
      };
    }
    return {
      for (final entry in directories.entries)
        entry.key: (name: entry.value, files: files[entry.value] ?? []),
    };
  }

  Future<Uint8List> readArtwork(List<String> candidates, int width) async {
    if (_isTree) {
      final bytes = await _channel.invokeMethod<Uint8List>('firstImage', {
        ..._args(_relative('')),
        'candidates': candidates.map(_relative).toList(),
        'width': width,
      });
      if (bytes != null) return bytes;
    } else {
      for (final name in candidates) {
        final file = File(await _diskPath(_relative(name)));
        if (await file.exists()) return file.readAsBytes();
      }
    }
    throw const FileSystemException('找不到对应图片');
  }

  Future<void> invalidateArtwork() async {
    _artworkRevisions[location] = artworkVersion + 1;
    if (_isTree) await _channel.invokeMethod<void>('invalidateArtwork');
  }

  Future<void> removeEmptyDirectory(String name) async {
    final relative = _relative(name);
    if (await kind(name) != EntryKind.directory ||
        (await list(name)).isNotEmpty) {
      return;
    }
    if (_isTree) {
      await _channel.invokeMethod<void>(
        'removeEmptyDirectory',
        _args(relative),
      );
    } else {
      await Directory(await _diskPath(relative)).delete();
    }
  }

  Future<Uint8List> read(String name) async {
    final relative = _relative(name);
    if (_isTree) {
      return (await _channel.invokeMethod<Uint8List>('read', _args(relative)))!;
    }
    return File(await _diskPath(relative)).readAsBytes();
  }

  Future<Map<String, Uint8List>> readFiles(List<String> names) async {
    if (_isTree) {
      if (names.any((name) => name.contains('/'))) {
        throw ArgumentError('只能批量读取同一目录内的文件');
      }
      return (await _channel.invokeMapMethod<String, Uint8List>('readFiles', {
        ..._args(_relative('')),
        'names': names,
      }))!;
    }
    final result = <String, Uint8List>{};
    for (final name in names) {
      try {
        result[name] = await read(name);
      } catch (error) {
        throw StateError('无法读取 $name：$error');
      }
    }
    return result;
  }

  Future<Map<String, String>> mediaSource(String name) async {
    final relative = _relative(name);
    if (_isTree) return {'tree': location, 'path': relative};
    return {'file': await _diskPath(relative)};
  }

  Future<void> copyTo(String name, ArcStorage target, String newName) async {
    final sourcePath = _relative(name);
    final targetPath = target._relative(newName);
    if (await target.kind(newName) != null) {
      throw FileSystemException('复制目标已存在', newName);
    }
    if (_isTree && target._isTree) {
      await _channel.invokeMethod<void>('copy', {
        ..._args(sourcePath),
        'targetTree': target.location,
        'target': targetPath,
      });
    } else if (!_isTree && !target._isTree) {
      await File(
        await _diskPath(sourcePath),
      ).copy(await target._diskPath(targetPath));
    } else {
      await target.write(newName, await read(name));
    }
  }

  Future<bool> isWithin(ArcStorage parent) async {
    if (_isTree != parent._isTree) return false;
    if (_isTree) {
      final child = Uri.parse(location), base = Uri.parse(parent.location);
      if (child.authority != base.authority) return false;
      String path(Uri uri, String prefix) =>
          [uri.pathSegments.last, if (prefix.isNotEmpty) prefix].join('/');
      final target = path(child, prefix);
      final source = path(base, parent.prefix);
      return target == source || target.startsWith('$source/');
    }
    final target = await _diskPath(prefix);
    final source = await parent._diskPath(parent.prefix);
    return p.equals(target, source) || p.isWithin(source, target);
  }

  Future<void> copyTreeTo(ArcStorage target, {List<ArcEntry>? entries}) async {
    for (final entry in entries ?? await list()) {
      if (entry.name.startsWith('.arcaea-')) continue;
      if (entry.kind == EntryKind.file) {
        await copyTo(entry.name, target, entry.name);
      } else if (entry.kind == EntryKind.directory) {
        await target.createDirectory(entry.name);
        await child(entry.name).copyTreeTo(target.child(entry.name));
      }
    }
  }

  /// Removes the contents of a staging folder created by the caller.
  Future<void> clearStage() async {
    for (final entry in await list()) {
      if (entry.kind == EntryKind.file) {
        await removeFile(entry.name);
      } else if (entry.kind == EntryKind.directory) {
        await child(entry.name).clearStage();
        await removeEmptyDirectory(entry.name);
      }
    }
  }

  Future<void> write(String name, Uint8List bytes) async {
    final relative = _relative(name);
    if (_isTree) {
      await _channel.invokeMethod<void>('write', {
        ..._args(relative),
        'bytes': bytes,
      });
      return;
    }
    await File(await _diskPath(relative)).writeAsBytes(bytes, flush: true);
  }

  Future<void> createDirectory(String name) async {
    final relative = _relative(name);
    if (_isTree) {
      await _channel.invokeMethod<void>('createDirectory', _args(relative));
      return;
    }
    await Directory(await _diskPath(relative)).create();
  }

  Future<void> rename(String name, String newName) async {
    final source = _relative(name);
    final target = _relative(newName);
    if (await kind(newName) != null) {
      throw FileSystemException('目标已存在', newName);
    }
    if (_isTree) {
      await _channel.invokeMethod<void>('rename', {
        ..._args(source),
        'target': target,
      });
      return;
    }
    final sourcePath = await _diskPath(source);
    final targetPath = await _diskPath(target);
    if (await kind(name) == EntryKind.directory) {
      await Directory(sourcePath).rename(targetPath);
    } else {
      await File(sourcePath).rename(targetPath);
    }
  }

  Future<void> removeFile(String name) async {
    final relative = _relative(name);
    if (await kind(name) != EntryKind.file) return;
    if (_isTree) {
      await _channel.invokeMethod<void>('removeFile', _args(relative));
      return;
    }
    await File(await _diskPath(relative)).delete();
  }
}
