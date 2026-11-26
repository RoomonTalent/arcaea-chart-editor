import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/library_folder.dart';
import '../models/pack.dart';
import '../models/song.dart';
import '../models/unlock.dart';
import 'arc_storage.dart';
import 'arc_transaction.dart';
import 'cache_service.dart';
import 'catalog_documents.dart';
import 'file_service.dart';
import 'scanner_service.dart';
import 'song_import.dart';
import 'transfer_bundle.dart';
import 'song_order.dart';

class AppState extends ChangeNotifier {
  final FileService fileService = FileService();
  final CacheService cacheService = CacheService();
  late final ScannerService _scanner = ScannerService(cacheService);

  ScanResult? _scanResult;
  bool _isLoading = false;
  bool _isScanning = false;
  bool _isBusy = false;
  bool _disposed = false;
  int artworkRevision = 0;
  String? _error;
  String _searchQuery = '';
  String? _filterPackId;
  int? _selectedRatingClass;
  bool _missingFilesOnly = false;
  SongSortMode _songSortMode = SongSortMode.defaultOrder;

  ScanResult? get scanResult => _scanResult;
  bool get isLoading => _isLoading;
  bool get isScanning => _isScanning;
  bool get isBusy => _isBusy;
  String? get error => _error;
  String get searchQuery => _searchQuery;
  String? get filterPackId => _filterPackId;
  int? get selectedRatingClass => _selectedRatingClass;
  bool get missingFilesOnly => _missingFilesOnly;
  SongSortMode get songSortMode => _songSortMode;
  bool get hasPath => fileService.hasPath;
  List<LibraryFolder> get libraries => fileService.libraries;

  List<Pack> get packs => _scanResult?.packs ?? [];
  List<Song> get songs => _scanResult?.songs ?? [];
  Map<String, List<Song>> get songsByPack => _scanResult?.songsByPack ?? {};
  List<Unlock> get unlocks => _scanResult?.unlocks ?? [];
  Map<String, List<Unlock>> get unlocksBySongId =>
      _scanResult?.unlocksBySongId ?? {};
  DateTime? get lastScanTime => _scanResult?.scanTime;
  bool get fromCache => _scanResult?.fromCache ?? false;

  List<Song> get filteredSongs {
    final candidates = _filterPackId == null
        ? songs
        : songsByPack[_filterPackId] ?? [];
    final query = _searchQuery.trim().toLowerCase();
    final ratingClass = _selectedRatingClass;
    final matches = candidates.where((song) {
      if (ratingClass != null && song.difficultyFor(ratingClass) == null) {
        return false;
      }
      if (_missingFilesOnly && song.isFolderComplete) return false;
      return query.isEmpty ||
          song.titleLocalized.values.any(
            (title) => title.toLowerCase().contains(query),
          ) ||
          song.displayTitle.toLowerCase().contains(query) ||
          song.artist.toLowerCase().contains(query) ||
          song.id.toLowerCase().contains(query);
    }).toList();
    return sortSongs(matches, packs, _songSortMode, ratingClass: ratingClass);
  }

  Future<void> init() async {
    _isLoading = true;
    _notify();
    try {
      await _exclusive(() async {
        final location = await fileService.savedLocation();
        if (location != null) await _openSaved(location);
      });
    } catch (error) {
      _error = '无法读取之前的目录，请重新选择。$error';
    } finally {
      _isLoading = false;
      _notify();
    }
  }

  Future<void> setBasePathAndScan(String path, {String? name}) async {
    await _exclusive(() => _open(path, name: name), scanning: true);
  }

  Future<void> switchLibrary(String location) async {
    await _exclusive(() => _openSaved(location), scanning: true);
  }

  Future<void> _openSaved(String location) async {
    final folder = libraries
        .where((entry) => entry.location == location)
        .firstOrNull;
    if (folder == null) throw StateError('此文件夹已从列表移除');
    await _open(location);
  }

  Future<void> _open(String location, {String? name}) async {
    final target = await fileService.resolveLibrary(location);
    final candidate = target.storage;
    final result = await _scanner.scan(candidate);
    final switching =
        !hasPath || fileService.storage.identity != candidate.identity;
    await fileService.activate(candidate, target.identity, name: name);
    _scanResult = result;
    if (switching) _resetLibraryFilters();
    _error = null;
  }

  Future<void> renameLibrary(String location, String name) =>
      _exclusive(() => fileService.renameLibrary(location, name));

  Future<void> removeLibrary(String location) => _exclusive(() async {
    await fileService.removeLibrary(location);
    if (!hasPath) {
      _scanResult = null;
      _error = null;
      _resetLibraryFilters();
    }
  });

  void _resetLibraryFilters() {
    _searchQuery = '';
    _filterPackId = null;
    _selectedRatingClass = null;
    _missingFilesOnly = false;
  }

  Future<void> rescan({bool clearCache = false}) async {
    if (_isBusy || !hasPath) return;
    try {
      await _exclusive(() async {
        if (clearCache) await cacheService.clearAllCache();
        await _invalidateArtwork(fileService.storage);
        _scanResult = await _scanner.scan(fileService.storage, force: true);
        artworkRevision++;
        _error = null;
      }, scanning: true);
    } catch (error) {
      _error = error.toString();
      _notify();
    }
  }

  Future<void> _invalidateArtwork(ArcStorage songs) async {
    await songs.invalidateArtwork();
    final root = FileService.arcExtRootFor(songs);
    if (root != null && root.location != songs.location) {
      await root.invalidateArtwork();
    }
  }

  void setSearchQuery(String query) {
    _searchQuery = query;
    _notify();
  }

  void setFilterPack(String? packId) {
    _filterPackId = packId;
    _notify();
  }

  void setDifficultyFilter(int? ratingClass) {
    if (_selectedRatingClass == ratingClass) return;
    _selectedRatingClass = ratingClass;
    _notify();
  }

  void setMissingFilesOnly(bool enabled) {
    if (_missingFilesOnly == enabled) return;
    _missingFilesOnly = enabled;
    _notify();
  }

  void setSongSortMode(SongSortMode mode) {
    if (_songSortMode == mode) return;
    _songSortMode = mode;
    _notify();
  }

  Future<void> addPack(Pack pack) => _change((data) {
    data.addPack(pack.toJson());
    return {'packlist': data.encode('packlist')};
  });

  Future<void> removePack(String id) => _change((data) {
    data.removePack(id);
    return {'packlist': data.encode('packlist')};
  });

  Future<void> removePacks(
    Set<String> ids, {
    required bool includeSongs,
  }) async {
    if (ids.isEmpty) return;
    final deleted = <String>[];
    await _change(
      (data) {
        final affected = data.songsInPacks(ids);
        if (includeSongs) {
          deleted.addAll(data.removeSongRecords(data.songRecordsInPacks(ids)));
        }
        data.removePacks(ids);
        return {
          'packlist': data.encode('packlist'),
          if (affected.isNotEmpty) 'songlist': data.encode('songlist'),
          if (deleted.isNotEmpty) 'unlocks': data.encode('unlocks'),
        };
      },
      deleteIds: deleted,
      deletePackIds: ids,
    );
  }

  Future<void> updatePack(String id, Map<String, dynamic> changes) =>
      _change((data) {
        data.editPack(id, changes);
        return {'packlist': data.encode('packlist')};
      });

  Future<void> updateSong(
    String id,
    Map<String, dynamic> changes, {
    int? recordIndex,
    String? expectedSonglist,
    ArcStorage? expectedStorage,
  }) => _change(
    (data) {
      if (changes.containsKey('set')) {
        data.validateSongPack(changes['set'] as String?);
      }
      data.editSong(id, changes, recordIndex: recordIndex);
      return {'songlist': data.encode('songlist')};
    },
    expectedSonglist:
        expectedSonglist ??
        (recordIndex == null ? null : _scanResult?.manifests['songlist']),
    expectedStorage: expectedStorage,
  );

  Future<void> updateChartBpmBase(
    String id,
    int ratingClass,
    double bpm, {
    int? recordIndex,
    String? expectedSonglist,
    ArcStorage? expectedStorage,
  }) => _change(
    (data) {
      data.setChartBpmBase(id, ratingClass, bpm, recordIndex: recordIndex);
      return {'songlist': data.encode('songlist')};
    },
    expectedSonglist:
        expectedSonglist ??
        (recordIndex == null ? null : _scanResult?.manifests['songlist']),
    expectedStorage: expectedStorage,
  );

  Future<void> deleteSongs(List<String> songIds) async {
    final unique = songIds.toSet();
    if (unique.isEmpty) return;
    await _change((data) {
      data.removeSongs(unique);
      return {
        'songlist': data.encode('songlist'),
        'unlocks': data.encode('unlocks'),
      };
    }, deleteIds: unique.toList());
  }

  Future<void> deleteSongRecords(
    List<Song> records, {
    String? expectedSonglist,
    ArcStorage? expectedStorage,
  }) async {
    if (records.isEmpty) return;
    final deleted = <String>[];
    await _change(
      (data) {
        for (final song in records) {
          data.songRow(song.id, recordIndex: song.recordIndex!);
        }
        deleted.addAll(
          data.removeSongRecords(
            records.map((song) => song.recordIndex!).toSet(),
          ),
        );
        return {
          'songlist': data.encode('songlist'),
          'unlocks': data.encode('unlocks'),
        };
      },
      deleteIds: deleted,
      expectedSonglist: expectedSonglist ?? _scanResult?.manifests['songlist'],
      expectedStorage: expectedStorage,
    );
  }

  Future<void> importSong(
    SongImport source,
    String id,
    Map<String, dynamic> data, [
    List<Map<String, dynamic>> unlocks = const [],
  ]) => _change(
    (documents) {
      source.validateDifficulties(data);
      if (unlocks.any(
        (entry) =>
            entry['songId'] != id ||
            !source.ratingClasses.contains(entry['ratingClass']),
      )) {
        throw const FormatException('解锁条目与导入歌曲的难度不一致');
      }
      documents.addSong(id, data, unlocks);
      return {
        'songlist': documents.encode('songlist'),
        if (unlocks.isNotEmpty) 'unlocks': documents.encode('unlocks'),
      };
    },
    source: source,
    importId: id,
  );

  Future<String> exportSong(
    String id,
    String location, {
    Song? record,
    String? expectedSonglist,
    ArcStorage? expectedStorage,
  }) async {
    final songs = fileService.storage;
    if (expectedStorage != null && !identical(expectedStorage, songs)) {
      throw StateError('歌曲库已切换');
    }
    final snapshot = expectedSonglist ?? _scanResult?.manifests['songlist'];
    final destination = ArcStorage(location);
    if (await destination.isWithin(songs)) {
      throw StateError('请选择 songs 目录之外的导出位置');
    }
    return songs.withReadLock(() async {
      final original = await CatalogDocuments.read(songs);
      if (record != null && utf8.decode(original['songlist']!) != snapshot) {
        throw StateError('歌曲清单已变化，请重新选择歌曲');
      }
      final folder = (await songs.listSongFiles([id]))[id];
      if (folder == null) throw StateError('找不到歌曲资源目录：$id');
      final data = _portableSong(
        CatalogDocuments(
          original,
        ).songTransfer(id, recordIndex: record?.recordIndex),
        folder,
        isArc4: songs.isArc4,
      );
      final source = songs.child(folder.name);
      final root = FileService.arcExtRootFor(songs);
      final shared = <String, String>{};
      return TransferBundle.write(
        destination: destination,
        name: (data['song'] as Map)['id'] as String,
        type: 'song',
        data: {...data, 'backgroundFiles': shared},
        writeAssets: (bundle) async {
          await bundle.createDirectory('song');
          final target = bundle.child('song');
          await source.copyTreeTo(target);
          if (root == null) return;
          final song = data['song'] as Map<String, dynamic>;
          final difficulties = (song['difficulties'] as List?) ?? const [];
          final backgrounds = {
            song['bg'],
            song['bg_inverse'],
            for (final difficulty in difficulties.whereType<Map>()) ...[
              difficulty['bg'],
              difficulty['bg_inverse'],
            ],
          };
          final folders = <String>{};
          final sharedRoot = bundle.child('shared');
          Future<void> copyBackground(String path, String name) async {
            for (final directory in [
              'shared',
              'shared/img',
              'shared/img/bg',
              if (path.startsWith('img/bg/1080/')) 'shared/img/bg/1080',
            ]) {
              if (folders.add(directory)) {
                await bundle.createDirectory(directory);
              }
            }
            await root.copyTo(path, sharedRoot, path);
            shared[path] = path;
            if (await target.kind(name) == null) {
              await root.copyTo(path, target, name);
            }
          }

          for (final bg in backgrounds.whereType<String>()) {
            if (!FileService.isBackgroundId(bg)) continue;
            for (final extension in ['jpg', 'png', 'webp']) {
              final name = '$bg.$extension';
              final high = 'img/bg/1080/$name', normal = 'img/bg/$name';
              if (await root.kind(high) == EntryKind.file) {
                await copyBackground(high, name);
                break;
              }
              if (await root.kind(normal) == EntryKind.file) {
                await copyBackground(normal, name);
                break;
              }
            }
          }
        },
      );
    });
  }

  static Map<String, dynamic> _portableSong(
    Map<String, dynamic> transfer,
    SongFolder folder, {
    required bool isArc4,
    Set<String>? usedIds,
  }) {
    final song = Map<String, dynamic>.of(
      transfer['song'] as Map<String, dynamic>,
    );
    final originalId = song['id'] as String;
    var id =
        ArcStorage.isSongDirectoryName(originalId) &&
            !originalId.startsWith('.') &&
            originalId.trim() == originalId
        ? originalId
        : folder.name;
    FileService.validateId(id);
    final base = id;
    for (
      var number = 2;
      usedIds != null && !usedIds.add(FileService.idKey(id));
      number++
    ) {
      id = '${base}_$number';
    }
    song['id'] = id;
    final declared = (song['difficulties'] ?? song['iculties']) as List?;
    final files = folder.files.map((file) => file.toLowerCase()).toSet();
    if (isArc4 && !files.any(RegExp(r'^[0-4]\.aff$').hasMatch)) {
      throw StateError('歌曲没有可分享的谱面：$originalId');
    }
    final difficulties = [
      for (final row in (declared ?? const []).cast<Map<String, dynamic>>())
        if (!isArc4 || files.contains('${row['ratingClass']}.aff')) row,
    ];
    song.remove('iculties');
    song['difficulties'] = difficulties;
    final classes = difficulties.map((row) => row['ratingClass']).toSet();
    return {
      ...transfer,
      'song': song,
      'unlocks': [
        for (final row
            in (transfer['unlocks'] as List).cast<Map<String, dynamic>>())
          if (!isArc4 || classes.contains(row['ratingClass']))
            {...row, 'songId': id},
      ],
    };
  }

  Future<String> importSongBundle(String location) async {
    final root = ArcStorage(location);
    final destination = fileService.storage;
    final data = await TransferBundle.read(root, 'song');
    final song = data['song'] as Map<String, dynamic>;
    final id = song['id'] as String;
    FileService.validateId(id);
    final packs = (data['packs'] as List).cast<Map<String, dynamic>>();
    final unlocks = (data['unlocks'] as List).cast<Map<String, dynamic>>();
    final source = await SongImport.scanFolder(root.child('song'), id);
    final difficultyEntries = (song['difficulties'] as List)
        .cast<Map<String, dynamic>>();
    final classes = difficultyEntries
        .map((entry) => entry['ratingClass'])
        .toSet();
    if (classes.length != difficultyEntries.length ||
        !classes.every(source.ratingClasses.contains) ||
        unlocks.any(
          (entry) =>
              entry['songId'] != id ||
              !source.ratingClasses.contains(entry['ratingClass']),
        )) {
      throw const FormatException('歌曲包中的难度或解锁条目缺少对应谱面');
    }
    final knownBackgrounds = {
      song['bg'],
      song['bg_inverse'],
      for (final entry in difficultyEntries) ...[
        entry['bg'],
        entry['bg_inverse'],
      ],
    };
    final backgrounds =
        (data['backgroundFiles'] as Map?)?.cast<String, String>() ??
        const <String, String>{};
    for (final entry in backgrounds.entries) {
      final background = FileService.backgroundIdFromPath(entry.key);
      if (entry.key != entry.value ||
          background == null ||
          !knownBackgrounds.contains(background)) {
        throw const FormatException('歌曲包中的背景与歌曲条目不匹配');
      }
    }
    if (!hasPath || !identical(destination, fileService.storage)) {
      throw StateError('目标目录已切换，请重新导入');
    }
    await _change(
      (documents) {
        final packsChanged = documents.restorePacks(packs);
        documents.addSong(id, song, unlocks);
        return {
          'songlist': documents.encode('songlist'),
          if (unlocks.isNotEmpty) 'unlocks': documents.encode('unlocks'),
          if (packsChanged) 'packlist': documents.encode('packlist'),
        };
      },
      source: source,
      importId: id,
      backgrounds: backgrounds,
      backgroundSource: root.child('shared'),
    );
    return id;
  }

  Future<String> exportCatalogBundle(
    String location, {
    Set<String> songIds = const {},
    List<Song> songRecords = const [],
    String? expectedSonglist,
    ArcStorage? expectedStorage,
    Set<String> packIds = const {},
    bool includePackSongs = false,
  }) async {
    final storage = fileService.storage;
    if (expectedStorage != null && !identical(expectedStorage, storage)) {
      throw StateError('歌曲库已切换');
    }
    final destination = ArcStorage(location);
    if (await destination.isWithin(storage)) {
      throw StateError('请选择 songs 目录之外的导出位置');
    }
    final game = FileService.arcExtRootFor(storage);
    final snapshot = expectedSonglist ?? _scanResult?.manifests['songlist'];
    String? output;
    await _exclusive(() async {
      if (!hasPath || !identical(storage, fileService.storage)) {
        throw StateError('歌曲库已切换');
      }
      output = await storage.withReadLock(() async {
        final original = await CatalogDocuments.read(storage);
        if (songRecords.isNotEmpty &&
            utf8.decode(original['songlist']!) != snapshot) {
          throw StateError('歌曲清单已变化，请重新选择歌曲');
        }
        final documents = CatalogDocuments(original);
        final rows = documents.rows('songlist');
        final selected = {
          for (final id in songIds) rows.indexOf(documents.songRow(id)),
          for (final song in songRecords)
            rows.indexOf(
              documents.songRow(song.id, recordIndex: song.recordIndex),
            ),
          if (includePackSongs) ...documents.songRecordsInPacks(packIds),
        };
        if (selected.isEmpty && packIds.isEmpty) throw StateError('没有选中的歌曲或曲包');
        final folders = await storage.listSongFiles([
          for (final index in selected) rows[index]['id'] as String,
        ]);
        final songs = <Map<String, dynamic>>[];
        final unlocks = <Map<String, dynamic>>[];
        final includedPacks = {...packIds};
        final copyFolders = <String, String>{};
        final usedIds = <String>{};
        for (final index in selected) {
          final id = rows[index]['id'] as String;
          final folder = folders[id];
          if (folder == null) throw StateError('找不到歌曲资源目录：$id');
          final transfer = _portableSong(
            documents.songTransfer(id, recordIndex: index),
            folder,
            isArc4: storage.isArc4,
            usedIds: usedIds,
          );
          final song = transfer['song'] as Map<String, dynamic>;
          songs.add(song);
          copyFolders[song['id'] as String] = folder.name;
          unlocks.addAll(transfer['unlocks'] as List<Map<String, dynamic>>);
          final pack = song['set'] as String?;
          if (pack != null && pack.isNotEmpty && pack != 'single') {
            includedPacks.add(pack);
          }
        }
        final packs = documents.packsFor(includedPacks);
        final packKeys = {
          for (final row in packs) row['id'] as String,
          if (songs.any((song) => song['set'] == 'single')) 'single',
        };
        final packFiles = <String>[];
        final backgrounds = <String>[];
        return TransferBundle.write(
          destination: destination,
          name: 'share',
          type: 'catalog',
          data: {
            'songs': songs,
            'packs': packs,
            'unlocks': unlocks,
            'packFiles': packFiles,
            'backgroundFiles': backgrounds,
          },
          writeAssets: (bundle) async {
            if (songs.isNotEmpty) await bundle.createDirectory('songs');
            for (final song in songs) {
              final id = song['id'] as String;
              await bundle.createDirectory('songs/$id');
              await storage
                  .child(copyFolders[id]!)
                  .copyTreeTo(bundle.child('songs/$id'));
            }
            for (final path in await _packArtwork(
              storage,
              packKeys,
              images: _packImages(packs),
            )) {
              await TransferBundle.ensureParents(bundle, path);
              await storage.copyTo(path, bundle, path);
              packFiles.add(path);
            }
            if (game == null) return;
            for (final id in _backgroundIds(songs)) {
              for (final directory in ['img/bg/1080', 'img/bg']) {
                for (final extension in ['jpg', 'png', 'webp']) {
                  final path = '$directory/$id.$extension';
                  if (await game.kind(path) != EntryKind.file) continue;
                  await TransferBundle.ensureParents(bundle, 'shared/$path');
                  await game.copyTo(path, bundle, 'shared/$path');
                  backgrounds.add(path);
                }
              }
            }
          },
        );
      });
    });
    return output!;
  }

  static Set<String> _backgroundIds(List<Map<String, dynamic>> songs) => {
    for (final song in songs)
      for (final record in [
        song,
        ...(song['difficulties'] as List? ?? const []).whereType<Map>(),
      ])
        for (final key in ['bg', 'bg_inverse'])
          if (record[key] case final String id
              when FileService.isBackgroundId(id))
            id,
  };

  static Set<String> _packImages(Iterable<Map<String, dynamic>> packs) => {
    for (final row in packs)
      if (row['img'] case final String image
          when ArcStorage.isSongDirectoryName(image))
        image.toLowerCase(),
  };

  static bool _ownsPackFile(
    String path,
    Set<String> ids, {
    Set<String> images = const {},
  }) {
    if (!ArcStorage.isSafeRelativePath(path) ||
        !RegExp(
          r'^pack/(?:1080/)?[^/]+\.(?:png|jpe?g|webp)$',
          caseSensitive: false,
        ).hasMatch(path)) {
      return false;
    }
    if (images.contains(path.split('/').last.toLowerCase())) return true;
    final match = RegExp(
      r'^pack/(?:1080/)?(?:1080_select_|select_|1080_small_|divider_)([^/]+)\.(?:png|jpe?g|webp)$',
      caseSensitive: false,
    ).firstMatch(path);
    if (match == null) return false;
    final name = match[1]!.toLowerCase();
    final keys = ids.map((id) => id.toLowerCase()).toSet();
    return keys.contains(name) ||
        keys.contains(
          name.replaceFirst(RegExp(r'_(?:alt|selected)$|-pressed$'), ''),
        );
  }

  static Future<List<String>> _packArtwork(
    ArcStorage storage,
    Set<String> ids, {
    Set<String> images = const {},
  }) async {
    final result = <String>[];
    if (ids.isEmpty) return result;
    for (final directory in ['pack', 'pack/1080']) {
      if (await storage.kind(directory) != EntryKind.directory) continue;
      for (final item in await storage.list(directory)) {
        final path = '$directory/${item.name}';
        if (item.kind == EntryKind.file &&
            _ownsPackFile(path, ids, images: images)) {
          result.add(path);
        }
      }
    }
    return result;
  }

  Future<({int songs, int packs})> importCatalogBundle(String location) async {
    final bundle = ArcStorage(location);
    final expected = fileService.storage;
    final data = await TransferBundle.read(
      bundle,
      'catalog',
      alternateType: 'song',
    );
    if (data['type'] == 'song') {
      if (!hasPath || !identical(expected, fileService.storage)) {
        throw StateError('目标曲库已切换');
      }
      await importSongBundle(location);
      return (songs: 1, packs: (data['packs'] as List).length);
    }
    final songs = (data['songs'] as List).cast<Map<String, dynamic>>();
    final packs = (data['packs'] as List).cast<Map<String, dynamic>>();
    final unlocks = (data['unlocks'] as List).cast<Map<String, dynamic>>();
    if (songs.isEmpty && packs.isEmpty) {
      throw const FormatException('分享包没有歌曲或曲包');
    }
    final imports = <String, SongImport>{};
    final keys = <String>{};
    for (final song in songs) {
      final id = song['id'] as String;
      FileService.validateId(id);
      if (!keys.add(FileService.idKey(id))) {
        throw const FormatException('分享包的歌曲 ID 重复');
      }
      final source = await SongImport.scanFolder(bundle.child('songs/$id'), id);
      final classes = (song['difficulties'] as List)
          .cast<Map<String, dynamic>>()
          .map((item) => item['ratingClass'])
          .toList();
      if (classes.toSet().length != classes.length ||
          !classes.every(source.ratingClasses.contains)) {
        throw FormatException('歌曲 $id 的难度条目缺少谱面');
      }
      imports[id] = source;
    }
    if (unlocks.any(
      (row) =>
          imports[row['songId']]?.ratingClasses.contains(row['ratingClass']) !=
          true,
    )) {
      throw const FormatException('分享包包含无法匹配歌曲谱面的解锁条目');
    }
    final packKeys = {
      for (final pack in packs) pack['id'] as String,
      if (songs.any((song) => song['set'] == 'single')) 'single',
    };
    final packFiles = (data['packFiles'] as List? ?? const []).cast<String>();
    final packImages = _packImages(packs);
    if (!packFiles.every(
      (path) => _ownsPackFile(path, packKeys, images: packImages),
    )) {
      throw const FormatException('分享包包含与所选曲包无关的素材');
    }
    final known = _backgroundIds(songs);
    final backgrounds = (data['backgroundFiles'] as List? ?? const [])
        .cast<String>();
    for (final path in backgrounds) {
      if (!known.contains(FileService.backgroundIdFromPath(path))) {
        throw const FormatException('分享包包含与歌曲无关的共享背景');
      }
    }
    if (!hasPath || !identical(expected, fileService.storage)) {
      throw StateError('目标曲库已切换');
    }
    await _change(
      (documents) {
        final packsChanged = documents.restorePacks(packs);
        for (final song in songs) {
          final id = song['id'] as String;
          documents.addSong(
            id,
            song,
            unlocks.where((row) => row['songId'] == id).toList(),
          );
        }
        return {
          if (packsChanged || songs.isEmpty)
            'packlist': documents.encode('packlist'),
          if (songs.isNotEmpty) 'songlist': documents.encode('songlist'),
          if (unlocks.isNotEmpty) 'unlocks': documents.encode('unlocks'),
        };
      },
      imports: imports,
      packFiles: {for (final path in packFiles) path: path},
      packSource: bundle,
      backgrounds: {for (final path in backgrounds) path: path},
      backgroundSource: bundle.child('shared'),
    );
    return (songs: songs.length, packs: packs.length);
  }

  Future<void> _change(
    ManifestChanges Function(CatalogDocuments) edit, {
    SongImport? source,
    String? importId,
    List<String> deleteIds = const [],
    Map<String, String> backgrounds = const {},
    ArcStorage? backgroundSource,
    Map<String, SongImport> imports = const {},
    Map<String, String> packFiles = const {},
    ArcStorage? packSource,
    Set<String> deletePackIds = const {},
    String? expectedSonglist,
    ArcStorage? expectedStorage,
  }) => _exclusive(() async {
    if (!hasPath) throw StateError('请先选择游戏数据目录');
    final storage = fileService.storage;
    if (expectedStorage != null && !identical(expectedStorage, storage)) {
      throw StateError('歌曲库已切换');
    }
    await storage.withLock(() async {
      final transaction = ArcTransaction(storage);
      await transaction.recover();

      final original = await CatalogDocuments.read(storage);
      if (expectedSonglist != null &&
          utf8.decode(original['songlist']!) != expectedSonglist) {
        throw StateError('歌曲清单已变化，请重新扫描后再操作');
      }
      final documents = CatalogDocuments(original, isArc4: storage.isArc4);
      final deletedPackImages = _packImages(
        documents
            .rows('packlist')
            .where((row) => deletePackIds.contains(row['id'])),
      );
      final changes = edit(documents);
      final bytes = {...original};
      for (final entry in changes.entries) {
        bytes[entry.key] = Uint8List.fromList(utf8.encode(entry.value));
      }
      final parsed = await _scanner.parse(
        bytes,
        previous: _scanResult,
        isArc4: storage.isArc4,
      );
      final files = <String, SongFolder>{
        if (_scanResult?.manifests['songlist'] ==
            utf8.decode(original['songlist']!))
          ...?_scanResult?.folderFiles,
      };
      final sourceEntries =
          await source?.checkedEntries() ?? const <ArcEntry>[];
      final incoming = <String, SongDirectoryImport>{
        for (final entry in imports.entries)
          entry.key: (
            storage: entry.value.storage,
            entries: await entry.value.checkedEntries(),
          ),
        if (source != null)
          ?importId: (storage: source.storage, entries: sourceEntries),
      };
      final scanned = parsed.songs
          .map((song) => song.id)
          .where((id) => !incoming.containsKey(id) && !files.containsKey(id))
          .toList();
      if (scanned.isNotEmpty) {
        files.addAll(await storage.listSongFiles(scanned));
      }

      if (incoming.isNotEmpty) {
        final existing = (await storage.list())
            .map((entry) => FileService.idKey(entry.name))
            .toSet();
        for (final entry in incoming.entries) {
          if (existing.contains(FileService.idKey(entry.key))) {
            throw StateError('歌曲目录或同名资源已存在：${entry.key}');
          }
          files[entry.key] = (
            name: entry.key,
            files: [
              for (final asset in entry.value.entries)
                if (asset.kind == EntryKind.file) asset.name,
            ],
          );
        }
      }
      final removedFolders = <String>{};
      if (deleteIds.isNotEmpty) {
        final remainingIds = parsed.songs.map((song) => song.id).toSet();
        final directories = await storage.songDirectories({
          ...deleteIds,
          ...remainingIds,
        });
        final retained = {for (final id in remainingIds) ?directories[id]};
        removedFolders.addAll(
          deleteIds
              .map((id) => directories[id])
              .whereType<String>()
              .where((folder) => !retained.contains(folder)),
        );
        files.removeWhere((id, _) => !remainingIds.contains(id));
      }
      await transaction.run(
        changes,
        original: original,
        imports: incoming,
        packFiles: packFiles,
        packSource: packSource,
        removedPackFiles: [
          for (final path in await _packArtwork(
            storage,
            deletePackIds,
            images: deletedPackImages,
          ))
            if (!_ownsPackFile(path, {
              for (final pack in parsed.packs) pack.id,
              'single',
            }, images: _packImages(documents.rows('packlist'))))
              path,
        ],
        deleteIds: removedFolders.toList(),
        keepBackups: deleteIds.isNotEmpty,
        backgrounds: backgrounds,
        backgroundSource: backgroundSource,
      );
      if (incoming.isNotEmpty ||
          deleteIds.isNotEmpty ||
          packFiles.isNotEmpty ||
          deletePackIds.isNotEmpty ||
          backgrounds.isNotEmpty) {
        await _invalidateArtwork(storage);
        artworkRevision++;
      }
      _scanResult = parsed.attach(files);
      if (_filterPackId != null &&
          !songsByPack.containsKey(_filterPackId) &&
          !packs.any((pack) => pack.id == _filterPackId)) {
        _filterPackId = null;
      }
      _error = null;
      await _scanner.save(storage, bytes, _scanResult!);
    });
  });

  Future<void> _exclusive(
    Future<void> Function() work, {
    bool scanning = false,
  }) async {
    if (_isBusy) throw StateError('正在处理另一项操作，请稍后重试');
    _isBusy = true;
    _isScanning = scanning;
    _notify();
    try {
      await work();
    } finally {
      _isBusy = false;
      _isScanning = false;
      _notify();
    }
  }

  void clearError() {
    _error = null;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
