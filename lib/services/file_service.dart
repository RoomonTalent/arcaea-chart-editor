import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/library_folder.dart';
import '../models/song.dart';
import 'arc_storage.dart';

class FileService {
  static const _oldPathKey = 'arcaea_base_path';
  static const _librariesKey = 'arcaea_libraries';
  static const recoveryJournal = '.arcaea-manager-journal.json';
  static const manifests = ['packlist', 'songlist', 'unlocks'];
  ArcStorage? _storage;
  List<LibraryFolder>? _libraries;
  String? _savedLocation;
  ArcStorage get storage => _storage!;
  String? get basePath => _storage?.location;
  bool get hasPath => _storage != null;
  List<LibraryFolder> get libraries => _libraries ?? const [];

  ArcStorage? arcExtRoot() =>
      _storage == null ? null : arcExtRootFor(_storage!);

  static ArcStorage? arcExtRootFor(ArcStorage songs) {
    switch (songs.prefix) {
      case 'songs':
        return ArcStorage(songs.location);
      case 'ArcExt/songs':
      case 'Arc4/songs':
        return ArcStorage(
          songs.location,
          prefix: songs.prefix.split('/').first,
        );
      default:
        if (songs.location.startsWith('content://')) return null;
        final location = p.normalize(songs.location);
        if (p.basename(location).toLowerCase() == 'songs') {
          return ArcStorage(p.dirname(location));
        }
        return null;
    }
  }

  Future<String?> savedLocation() async {
    await _loadLibraries();
    return _savedLocation;
  }

  Future<void> _loadLibraries() async {
    if (_libraries != null) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_librariesKey);
    if (raw != null) {
      try {
        final saved = jsonDecode(raw) as Map<String, dynamic>;
        final folders = (saved['folders'] as List).cast<Map<String, dynamic>>();
        final active = saved['active'] as String?;
        _libraries = List.unmodifiable(folders.map(LibraryFolder.fromJson));
        _savedLocation = libraries.any((folder) => folder.location == active)
            ? active
            : null;
        return;
      } on FormatException {
        // Recover the previous single-folder preference.
      } on TypeError {
        // Recover the previous single-folder preference.
      }
    }
    final oldPath = prefs.getString(_oldPathKey);
    _libraries = List.unmodifiable([
      if (oldPath != null && oldPath.isNotEmpty) LibraryFolder(oldPath),
    ]);
    _savedLocation = libraries.firstOrNull?.location;
  }

  /// Accept Arc4 or ArcExt, their songs directory, or their parent.
  Future<ArcStorage> locate(String location, {String? prefix}) async {
    final selected = ArcStorage(location);
    bool containsManifests(List<ArcEntry> entries) {
      final files = {
        for (final entry in entries)
          if (entry.kind == EntryKind.file) entry.name,
      };
      return files.containsAll(manifests) || files.contains(recoveryJournal);
    }

    if (prefix != null) {
      final candidate = selected.child(prefix);
      if (containsManifests(await candidate.list())) return candidate;
    } else {
      final children = await selected.list();
      if (containsManifests(children)) return selected;

      for (final name in ['songs', 'Arc4', 'ArcExt']) {
        if (!children.any(
          (entry) => entry.name == name && entry.kind == EntryKind.directory,
        )) {
          continue;
        }
        final candidate = selected.child(
          name == 'songs' ? 'songs' : '$name/songs',
        );
        if (await candidate.kind('') == EntryKind.directory &&
            containsManifests(await candidate.list())) {
          return candidate;
        }
      }
    }
    throw const FormatException('找不到完整的 songs/packlist、songlist 和 unlocks');
  }

  Future<({ArcStorage storage, String identity})> resolveLibrary(
    String location,
  ) async {
    await _loadLibraries();
    final saved = libraries
        .where((folder) => folder.location == location)
        .firstOrNull;
    final candidate = await locate(location, prefix: saved?.prefix);
    final identity = await candidate.catalogIdentity();
    final alias = libraries
        .where(
          (folder) =>
              folder.location != location && folder.catalogIdentity == identity,
        )
        .firstOrNull;
    if (alias != null) {
      final needsParentGrant =
          alias.location.startsWith('content://') &&
          alias.prefix == '' &&
          candidate.prefix.isNotEmpty;
      if (!needsParentGrant) {
        try {
          final existing = await locate(alias.location, prefix: alias.prefix);
          if (await existing.catalogIdentity() == identity) {
            return (storage: existing, identity: identity);
          }
        } on Exception {
          // The new selection can replace a deleted path or revoked grant.
        }
      }
    }
    return (storage: candidate, identity: identity);
  }

  Future<void> activate(
    ArcStorage candidate,
    String identity, {
    String? name,
  }) async {
    final location = candidate.location;
    final next = libraries.toList();
    bool matches(LibraryFolder folder) =>
        folder.location == location || folder.catalogIdentity == identity;
    final index = next.indexWhere(matches);
    final folder = LibraryFolder(
      location,
      name: _customName(name) ?? (index < 0 ? null : next[index].name),
      folderName: candidate.folderName,
      prefix: candidate.prefix,
      catalogIdentity: identity,
    );
    if (index < 0) {
      next.add(folder);
    } else {
      next[index] = folder;
      next.removeWhere((entry) => !identical(entry, folder) && matches(entry));
    }
    final replaced = libraries
        .where((entry) => entry.location != location && matches(entry))
        .toList();
    await _saveLibraries(next, location);
    _storage = candidate;
    for (final entry in replaced) {
      await ArcStorage.releaseSelection(entry.location);
    }
  }

  Future<void> renameLibrary(String location, String name) async {
    await _loadLibraries();
    final next = libraries.toList();
    final index = next.indexWhere((folder) => folder.location == location);
    if (index < 0) throw StateError('此文件夹已从列表移除');
    next[index] = next[index].withName(_customName(name));
    await _saveLibraries(next, _savedLocation);
  }

  Future<void> removeLibrary(String location) async {
    await _loadLibraries();
    if (!libraries.any((folder) => folder.location == location)) return;
    final remaining = libraries.where((folder) => folder.location != location);
    await _saveLibraries(
      remaining.toList(),
      _savedLocation == location ? null : _savedLocation,
    );
    if (basePath == location) _storage = null;
    await ArcStorage.releaseSelection(location);
  }

  String? _customName(String? value) {
    final name = value?.trim();
    return name == null || name.isEmpty ? null : name;
  }

  Future<void> _saveLibraries(List<LibraryFolder> next, String? active) async {
    final prefs = await SharedPreferences.getInstance();
    final saved = jsonEncode({
      'folders': next.map((folder) => folder.toJson()).toList(),
      'active': active,
    });
    if (!await prefs.setString(_librariesKey, saved)) {
      throw StateError('无法保存文件夹列表');
    }
    _libraries = List.unmodifiable(next);
    _savedLocation = active;
  }

  static String idKey(String id) => ArcStorage.songDirectoryKey(id);

  static bool isBackgroundId(String id) =>
      !id.startsWith('.') && ArcStorage.isSongDirectoryName(id);

  static String? backgroundIdFromPath(String path) {
    if (!ArcStorage.isSafeRelativePath(path)) return null;
    final id = RegExp(
      r'^img/bg/(?:1080/)?([^/]+)\.(?:jpg|png|webp)$',
    ).firstMatch(path)?.group(1);
    return id != null && isBackgroundId(id) ? id : null;
  }

  static void validateId(String id) {
    if (id.startsWith('.') ||
        id != id.trim() ||
        !ArcStorage.isSongDirectoryName(id)) {
      throw FormatException('无效的资源 ID：$id');
    }
  }

  static List<String> songImages(Song song, {bool smallFirst = false}) {
    final directory = song.folderPath;
    if (directory == null) return [];
    final files = {
      for (final file in song.folderFiles ?? const <String>[])
        file.toLowerCase(): file,
    };
    return [
      for (final candidate in song.artworkNames(smallFirst: smallFirst))
        if (files[candidate] case final file?) '$directory/$file',
    ];
  }

  static List<String> packImages(
    String id, {
    String? parent,
    String? image,
  }) => [
    if (image != null && ArcStorage.isSongDirectoryName(image)) 'pack/$image',
    if (ArcStorage.isSongDirectoryName(id)) ...[
      'pack/1080_select_$id.png',
      'pack/select_$id.png',
      'pack/1080_select_${id}_alt.png',
      'pack/1080/divider_$id.png',
      'pack/1080_small_$id.png',
      'pack/1080_small_${id}_selected.png',
    ],
    if (parent != null && parent.isNotEmpty && parent != id)
      ...packImages(parent),
  ];
}
