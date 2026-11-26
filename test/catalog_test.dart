import 'dart:convert';
import 'dart:io';

import 'package:arcaea_manager/chart/aff_chart.dart';
import 'package:arcaea_manager/chart/chart_files.dart';
import 'package:arcaea_manager/models/difficulty.dart';
import 'package:arcaea_manager/pages/difficulty_badge.dart';
import 'package:arcaea_manager/pages/song_detail_page.dart';
import 'package:arcaea_manager/pages/song_management_page.dart';
import 'package:arcaea_manager/services/app_state.dart';
import 'package:arcaea_manager/services/arc_storage.dart';
import 'package:arcaea_manager/services/arc_transaction.dart';
import 'package:arcaea_manager/services/cache_service.dart';
import 'package:arcaea_manager/services/catalog_documents.dart';
import 'package:arcaea_manager/services/file_service.dart';
import 'package:arcaea_manager/services/scanner_service.dart';
import 'package:arcaea_manager/services/song_import.dart';
import 'package:arcaea_manager/services/song_order.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory songs;
  late AppState app;

  Future<void> write(String name, Object value) =>
      File(p.join(songs.path, name)).writeAsString(jsonEncode(value));

  Future<List<dynamic>> rows(String name, String key) async =>
      (jsonDecode(await File(p.join(songs.path, name)).readAsString())
              as Map<String, dynamic>)[key]
          as List;

  Map<String, dynamic> song(String id, List<int> classes) => {
    'id': id,
    'title_localized': {'en': id, 'ja': '日本語'},
    'set': 'base',
    'difficulties': [
      for (final type in classes) {'ratingClass': type, 'rating': 9},
    ],
  };

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('arcaea-manager-tests-');
    songs = await Directory(
      p.join(root.path, 'ArcExt', 'songs'),
    ).create(recursive: true);
    await write('packlist', {
      'packs': [
        {
          'id': 'base',
          'section': 'arcaea',
          'name_localized': {'en': 'Base', 'ja': '日本語'},
          'new_game_field': {'value': 1},
        },
        {'id': 'child', 'pack_parent': 'base'},
      ],
    });
    await write('songlist', {
      'songs': [
        {
          ...song('original', [0, 1, 2]),
          'idx': 2,
        },
      ],
    });
    await write('unlocks', {'unlocks': []});
    final folder = await Directory(p.join(songs.path, 'original')).create();
    await File(p.join(folder.path, 'base.ogg')).writeAsString('audio');
    app = AppState();
    await app.setBasePathAndScan(root.path);
  });

  tearDown(() async {
    app.dispose();
    // Only remove the exact directory created by this test.
    final temporary = p.normalize(
      await Directory.systemTemp.resolveSymbolicLinks(),
    );
    final fixture = p.normalize(await root.resolveSymbolicLinks());
    if (p.dirname(fixture) == temporary &&
        p.basename(fixture).startsWith('arcaea-manager-tests-')) {
      await Directory(fixture).delete(recursive: true);
    }
  });

  Future<SongImport> source(String id, List<int> charts) async {
    final directory = await Directory(p.join(root.path, id)).create();
    for (final name in [
      ...charts.map((number) => '$number.aff'),
      'unrelated.aff',
      'base.ogg',
      'base.jpg',
    ]) {
      await File(p.join(directory.path, name)).writeAsString('fixture');
    }
    return SongImport.scan(directory.path);
  }

  test('缓存命中不列歌曲目录，清单新增只扫描新增歌曲，手动扫描可重新索引', () async {
    final storage = _CountingStorage(songs.path);
    final cache = _MemoryCatalogCache();
    final scanner = ScannerService(cache);
    await scanner.scan(storage);
    expect(storage.listedSongs, [
      <String>['original'],
    ]);
    expect(cache.saves, 1);
    await File(p.join(songs.path, 'original', '4.aff')).writeAsString('chart');
    final before = await scanner.scan(storage);
    expect(before.fromCache, isTrue);
    expect(before.songs.single.folderFiles, isNot(contains('4.aff')));
    expect(storage.listedSongs, hasLength(1));
    expect(cache.saves, 1);

    await write('unlocks', {'unlocks': [], 'fixture': true});
    await scanner.scan(storage);
    expect(storage.listedSongs, hasLength(1));

    await Directory(p.join(songs.path, 'added')).create();
    await write('songlist', {
      'songs': [
        song('original', [0, 1, 2]),
        song('added', [0, 1, 2]),
      ],
    });
    final updated = await scanner.scan(storage);
    expect(updated.songs.map((song) => song.id), ['original', 'added']);
    expect(storage.listedSongs.last, ['added']);
    final rescanned = await scanner.scan(storage, force: true);
    expect(rescanned.songs.first.folderFiles, contains('4.aff'));
    expect(storage.listedSongs.last, unorderedEquals(['original', 'added']));

    SharedPreferences.setMockInitialValues({});
    final selectedSongsFolder = AppState();
    addTearDown(selectedSongsFolder.dispose);
    await selectedSongsFolder.setBasePathAndScan(songs.path);
    final artworkRoot = selectedSongsFolder.fileService.arcExtRoot()!;
    expect(artworkRoot.location, isNot(songs.path));
    final revision = artworkRoot.artworkVersion;
    await selectedSongsFolder.rescan();
    expect(artworkRoot.artworkVersion, revision + 1);
  });

  test('旧目录自动迁移，Arc4 与 ArcExt 分别保存，坏库切换保留当前库', () async {
    final wrapper = await Directory(p.join(root.path, 'legacy')).create();
    final arc4 = await Directory(p.join(wrapper.path, 'Arc4')).create();
    final old = await Directory(p.join(arc4.path, 'songs')).create();
    for (final (name, key) in [
      ('songlist', 'songs'),
      ('packlist', 'packs'),
      ('unlocks', 'unlocks'),
    ]) {
      await File(p.join(old.path, name)).writeAsString(jsonEncode({key: []}));
    }
    SharedPreferences.setMockInitialValues({'arcaea_base_path': root.path});
    final migrated = AppState();
    addTearDown(migrated.dispose);
    await migrated.init();
    expect(migrated.songs.single.id, 'original');
    expect(migrated.libraries.single.prefix, 'ArcExt/songs');
    await migrated.setBasePathAndScan(wrapper.path, name: '旧版');
    expect(migrated.libraries.map((item) => item.displayName), [
      p.basename(root.path),
      '旧版',
    ]);
    expect(migrated.fileService.storage.isArc4, isTrue);
    expect(migrated.fileService.arcExtRoot()!.prefix, 'Arc4');
    await migrated.setBasePathAndScan(arc4.path);
    expect(migrated.libraries, hasLength(2));
    await migrated.renameLibrary(wrapper.path, 'Arc4 测试');
    final reopened = AppState();
    addTearDown(reopened.dispose);
    await reopened.init();
    expect(reopened.fileService.basePath, wrapper.path);
    expect(reopened.libraries.last.displayName, 'Arc4 测试');
    await reopened.switchLibrary(root.path);
    expect(reopened.songs.single.id, 'original');
    await File(p.join(old.path, 'songlist')).writeAsString('{');
    await expectLater(
      reopened.switchLibrary(wrapper.path),
      throwsFormatException,
    );
    expect(reopened.fileService.basePath, root.path);
    expect(reopened.songs.single.id, 'original');
    await reopened.removeLibrary(wrapper.path);
    expect(reopened.libraries.single.location, root.path);
    expect(await old.exists(), isTrue);
  });

  test('Arc4 旧字段和同 ID 行可独立编辑、读写谱面及跨库分享', () async {
    final arc4 = await Directory(
      p.join(root.path, 'older', 'Arc4'),
    ).create(recursive: true);
    final old = ArcStorage(arc4.path).child('songs');
    await ArcStorage(arc4.path).createDirectory('songs');
    await old.createDirectory('r.i.p');
    await old.write('r.i.p/2.aff', utf8.encode(AffChart.blank));
    await old.write('r.i.p/base.ogg', utf8.encode('music'));
    await old.write('r.i.p/BASE_256.JPG', utf8.encode('cover'));
    await old.createDirectory('pack');
    await old.write('pack/legacy cover.PNG', utf8.encode('pack-art'));
    await old.write(
      'packlist',
      utf8.encode(
        jsonEncode({
          'packs': [
            {'id': 'base', 'plus_character': false, 'img': 'legacy cover.PNG'},
            {'id': 'legacy'},
          ],
        }),
      ),
    );
    await old.write(
      'songlist',
      utf8.encode(
        jsonEncode({
          'songs': [
            {
              ...song('r.i.p.', [2]),
              'title_localized': {'en': 'First'},
            },
            {
              'id': 'r.i.p.',
              'set': 'legacy',
              'title_localized': {'en': 'Second'},
              'iculties': [
                {'ratingClass': 0, 'rating': 0},
                {'ratingClass': 1, 'rating': 7},
                {'ratingClass': 2, 'rating': 9},
              ],
            },
          ],
        }),
      ),
    );
    await old.write('unlocks', utf8.encode('{"unlocks": []}'));
    await app.setBasePathAndScan(arc4.path);
    expect(app.packs.first.plusCharacter, -1);
    final first = app.songs.first, second = app.songs.last;
    expect(second.pastDifficulty, isNull);
    expect(second.futureDifficulty!.rating, 9);
    expect(FileService.songImages(second), ['r.i.p/BASE_256.JPG']);
    final snapshot = app.scanResult!.manifests['songlist']!;
    final swapped = jsonDecode(snapshot) as Map<String, dynamic>;
    swapped['songs'] = (swapped['songs'] as List).reversed.toList();
    await old.write('songlist', utf8.encode(jsonEncode(swapped)));
    await app.rescan();
    await expectLater(
      app.deleteSongRecords([second], expectedSonglist: snapshot),
      throwsStateError,
    );
    expect(app.songs.first.displayTitle, 'Second');
    await old.write('songlist', utf8.encode(snapshot));
    await app.rescan();
    await app.updateSong(second.id, {
      'artist': 'second only',
    }, recordIndex: second.recordIndex);
    await app.updateChartBpmBase(
      second.id,
      2,
      160,
      recordIndex: second.recordIndex,
    );
    expect(app.songs.first.artist, isEmpty);
    expect(app.songs.last.artist, 'second only');
    expect(app.songs.last.futureDifficulty!.bpmBase, 160);
    final files = ChartFiles(old, second.id, 2, song: app.songs.last);
    final original = await files.open();
    await files.save(original, '${AffChart.blank}(200,2);');
    expect(utf8.decode(await old.read('r.i.p/2.aff')), contains('(200,2);'));
    final bundle = await app.exportCatalogBundle(
      root.path,
      songRecords: app.songs,
    );
    expect(
      await ArcStorage(bundle).kind('pack/legacy cover.PNG'),
      EntryKind.file,
    );
    expect(await ArcStorage(bundle).kind('songs/r.i.p/2.aff'), EntryKind.file);
    expect(
      await ArcStorage(bundle).kind('songs/r.i.p_2/2.aff'),
      EntryKind.file,
    );
    expect(await old.kind('r.i.p/base.ogg'), EntryKind.file);
    await app.removePacks({'legacy'}, includeSongs: true);
    expect(app.songs.single.displayTitle, first.displayTitle);
    expect(await old.kind('r.i.p/base.ogg'), EntryKind.file);
    await app.switchLibrary(root.path);
    await app.importCatalogBundle(bundle);
    expect(
      app.songs.map((song) => song.id),
      containsAll(['original', 'r.i.p', 'r.i.p_2']),
    );
    expect(await old.kind('r.i.p/base.ogg'), EntryKind.file);
  });

  test('多首歌曲和仅曲包分享均保留素材，删除曲包可保留包内歌曲', () async {
    final library = ArcStorage(songs.path);
    await library.createDirectory('pack');
    await library.createDirectory('pack/1080');
    await library.write('pack/1080_select_base.png', utf8.encode('cover'));
    await library.write(
      'pack/1080/divider_child-pressed.png',
      utf8.encode('divider'),
    );
    await app.importSong(await source('batchone', [2]), 'batchone', {
      ...song('batchone', [2]),
      'set': 'child',
    });
    await app.importSong(
      await source('batchtwo', [2, 4]),
      'batchtwo',
      song('batchtwo', [2, 4]),
    );
    final exported = await app.exportCatalogBundle(
      root.path,
      songIds: {'batchone', 'batchtwo'},
    );
    final packOnly = await app.exportCatalogBundle(
      root.path,
      packIds: {'child'},
    );
    final bundle = ArcStorage(exported);
    expect(await bundle.kind('songs/batchtwo/4.aff'), EntryKind.file);
    expect(
      await bundle.kind('pack/1080/divider_child-pressed.png'),
      EntryKind.file,
    );
    expect(await library.kind('batchone/base.ogg'), EntryKind.file);
    final target = await Directory(
      p.join(root.path, 'new', 'ArcExt', 'songs'),
    ).create(recursive: true);
    final targetStorage = ArcStorage(target.path);
    for (final (name, key) in [
      ('packlist', 'packs'),
      ('songlist', 'songs'),
      ('unlocks', 'unlocks'),
    ]) {
      await targetStorage.write(name, utf8.encode(jsonEncode({key: []})));
    }
    await app.setBasePathAndScan(target.path);
    expect(await app.importCatalogBundle(packOnly), (songs: 0, packs: 2));
    expect(app.songs, isEmpty);
    expect(
      await targetStorage.kind('pack/1080_select_base.png'),
      EntryKind.file,
    );
    expect(await app.importCatalogBundle(exported), (songs: 2, packs: 2));
    expect(
      app.songs.map((song) => song.id),
      containsAll(['batchone', 'batchtwo']),
    );
    await app.removePacks({'child'}, includeSongs: false);
    expect(
      app.songs.singleWhere((song) => song.id == 'batchone').set_,
      'single',
    );
    expect(await targetStorage.kind('batchone/base.ogg'), EntryKind.file);
    expect(
      await targetStorage.kind('pack/1080/divider_child-pressed.png'),
      isNull,
    );
    await app.removePacks({'base'}, includeSongs: true);
    expect(app.songs.map((song) => song.id), ['batchone']);
    expect(await targetStorage.kind('batchtwo'), isNull);
    expect(
      (await targetStorage.list()).any(
        (entry) =>
            entry.name.startsWith('.arcaea-manager-removed-') &&
            entry.name.endsWith('-batchtwo'),
      ),
      isTrue,
    );
  });

  test('歌曲包复制完整目录并跨库恢复歌曲、曲包与解锁条目', () async {
    final shared = await Directory(
      p.join(root.path, 'ArcExt', 'img', 'bg', '1080'),
    ).create(recursive: true);
    final artwork = File(p.join(shared.path, 'portable_bg.jpg'));
    await artwork.writeAsString('source background');
    final imported = await source('portable', [0, 2, 4]);
    await imported.storage.createDirectory('custom');
    await imported.storage.write('custom/asset.dat', utf8.encode('nested'));
    await app.importSong(
      imported,
      'portable',
      {
        ...song('portable', [0, 2, 4]),
        'set': 'child',
        'bg': 'portable_bg',
        'additional_files': [
          {'file_name': 'custom/asset.dat'},
        ],
      },
      [
        {'songId': 'portable', 'ratingClass': 4, 'conditions': []},
      ],
    );
    final sourceSonglist = await File(
      p.join(songs.path, 'songlist'),
    ).readAsString();
    final exported = await app.exportSong('portable', root.path);
    expect(await artwork.readAsString(), 'source background');
    expect(
      await File(p.join(songs.path, 'songlist')).readAsString(),
      sourceSonglist,
    );
    expect(
      await File(p.join(songs.path, 'portable', 'base.ogg')).exists(),
      isTrue,
    );
    final target = await Directory(
      p.join(root.path, 'destination', 'ArcExt', 'songs'),
    ).create(recursive: true);
    for (final (name, key) in [
      ('songlist', 'songs'),
      ('unlocks', 'unlocks'),
      ('packlist', 'packs'),
    ]) {
      await File(
        p.join(target.path, name),
      ).writeAsString(jsonEncode({key: []}));
    }
    await app.setBasePathAndScan(target.path);
    final bundledChart = File(p.join(exported, 'song', '4.aff'));
    final chart = await bundledChart.readAsBytes();
    await bundledChart.delete();
    await expectLater(app.importSongBundle(exported), throwsFormatException);
    expect(await Directory(p.join(target.path, 'portable')).exists(), isFalse);
    await bundledChart.writeAsBytes(chart);
    expect(await app.importSongBundle(exported), 'portable');
    expect(
      await File(
        p.join(target.parent.path, 'img', 'bg', '1080', 'portable_bg.jpg'),
      ).readAsString(),
      'source background',
    );
    expect(app.songs.single.set_, 'child');
    expect(app.packs.map((pack) => pack.id), containsAll(['base', 'child']));
    expect(app.unlocksBySongId['portable'], hasLength(1));
    expect(
      await File(
        p.join(target.path, 'portable', 'custom', 'asset.dat'),
      ).readAsString(),
      'nested',
    );
    await expectLater(app.importSongBundle(exported), throwsStateError);
  });

  test(
    'ETR can be the fourth chart and has its own missing-file check',
    () async {
      final imported = await source('onlyetr', [4, 2, 0, 1]);
      expect(imported.ratingClasses, [0, 1, 2, 4]);
      await app.importSong(
        imported,
        'onlyetr',
        song('onlyetr', imported.ratingClasses),
      );
      final saved = app.songs.singleWhere((item) => item.id == 'onlyetr');
      expect(saved.idx, 3);
      expect(saved.hasEternalChart, isTrue);
      expect(saved.hasBeyondChart, isFalse);
      expect(saved.isFolderComplete, isTrue);
      app.setDifficultyFilter(RatingClass.eternal);
      expect(app.filteredSongs.single.id, 'onlyetr');
      app.setDifficultyFilter(RatingClass.beyond);
      expect(app.filteredSongs, isEmpty);
      await File(p.join(songs.path, 'onlyetr', '4.aff')).delete();
      await app.rescan();
      expect(
        app.songs.singleWhere((item) => item.id == 'onlyetr').missingFiles,
        ['4.aff'],
      );
    },
  );

  test('five-class import, filtering and duplicate target checks', () async {
    final imported = await source('allcharts', [4, 2, 3, 1, 0]);
    expect(imported.ratingClasses, [0, 1, 2, 3, 4]);
    await expectLater(
      app.importSong(imported, 'allcharts', song('allcharts', [0, 1, 2, 3])),
      throwsFormatException,
    );
    await app.importSong(
      imported,
      'allcharts',
      song('allcharts', imported.ratingClasses),
    );
    for (final ratingClass in RatingClass.values) {
      app.setDifficultyFilter(ratingClass);
      expect(app.filteredSongs.any((entry) => entry.id == 'allcharts'), isTrue);
    }
    app.setDifficultyFilter(RatingClass.eternal);
    expect(app.filteredSongs.single.difficultyCount, 5);
    await expectLater(
      app.importSong(
        imported,
        'ALLCHARTS',
        song('ALLCHARTS', imported.ratingClasses),
      ),
      throwsStateError,
    );
    await Directory(p.join(songs.path, 'unregistered')).create();
    await expectLater(
      app.importSong(
        imported,
        'unregistered',
        song('unregistered', imported.ratingClasses),
      ),
      throwsStateError,
    );
  });

  test('patches retain other languages and unknown fields', () async {
    await app.updateSong('original', {
      'title_localized': {'en': 'edited'},
    });
    await app.updatePack('base', {
      'name_localized': {'en': 'edited'},
    });
    final songEntry = (await rows('songlist', 'songs')).single as Map;
    final packEntry = (await rows('packlist', 'packs')).first as Map;
    expect(songEntry['title_localized'], {'en': 'edited', 'ja': '日本語'});
    expect(packEntry['name_localized'], {'en': 'edited', 'ja': '日本語'});
    expect(packEntry['new_game_field'], {'value': 1});
    await expectLater(app.removePack('base'), throwsStateError);
  });

  test('bad target retains original catalog and saved directory', () async {
    final invalid = await Directory(p.join(root.path, 'invalid')).create();
    await expectLater(
      app.setBasePathAndScan(invalid.path),
      throwsFormatException,
    );
    expect(app.fileService.basePath, root.path);
    expect(await app.fileService.savedLocation(), root.path);
    expect(app.songs.single.id, 'original');
  });

  test('malformed unlocks prevents any change to the songlist', () async {
    final file = File(p.join(songs.path, 'songlist'));
    final before = await file.readAsString();
    await File(p.join(songs.path, 'unlocks')).writeAsString('invalid');
    await expectLater(app.deleteSongs(['original']), throwsFormatException);
    expect(await file.readAsString(), before);
    expect(
      await File(p.join(songs.path, 'original', 'base.ogg')).exists(),
      isTrue,
    );
  });

  test(
    'successful delete preserves indices, folders and manifest backups',
    () async {
      final imported = await source('another', [2]);
      await app.importSong(
        imported,
        'another',
        song('another', imported.ratingClasses),
      );
      await app.deleteSongs(['original']);
      expect(app.songs.single.idx, 3);
      expect(await Directory(p.join(songs.path, 'original')).exists(), isFalse);
      final files = await app.fileService.storage.list();
      final recovery = files.singleWhere(
        (entry) => entry.name.endsWith('-original'),
      );
      expect(
        await app.fileService.storage.kind('${recovery.name}/base.ogg'),
        EntryKind.file,
      );
      expect(
        files.any((entry) => entry.name.endsWith('-songlist.json')),
        isTrue,
      );
      expect(
        files.any((entry) => entry.name.endsWith('-unlocks.json')),
        isTrue,
      );
    },
  );

  test(
    'failed second manifest replacement restores both original files',
    () async {
      final storage = _FailingStorage(songs.path);
      final originals = await CatalogDocuments.read(storage);
      final transaction = ArcTransaction(storage);
      await expectLater(
        transaction.run(
          {'songlist': '{"songs":[]}', 'unlocks': '{"unlocks":[],"value":1}'},
          original: originals,
          deleteIds: ['original'],
        ),
        throwsA(isA<FileSystemException>()),
      );
      final restored = await CatalogDocuments.read(storage);
      expect(restored, originals);
      expect(await storage.kind('original'), EntryKind.directory);
    },
  );

  test(
    'scan can locate and recover an interrupted manifest replacement',
    () async {
      final storage = app.fileService.storage;
      await storage.rename(
        'songlist',
        '.arcaea-manager-backup-123-songlist.bin',
      );
      await File(
        p.join(songs.path, '.arcaea-manager-journal.json'),
      ).writeAsString(
        jsonEncode({
          'token': '123',
          'manifests': ['songlist'],
          'importId': null,
          'deleteIds': [],
        }),
      );
      final reopened = AppState();
      addTearDown(reopened.dispose);
      await reopened.setBasePathAndScan(root.path);
      expect(reopened.songs.single.id, 'original');
      expect(await storage.kind('songlist'), EntryKind.file);
      expect(await storage.kind('.arcaea-manager-journal.json'), isNull);
    },
  );
  test(
    'interrupted import cleanup preserves a pre-existing target directory',
    () async {
      final storage = app.fileService.storage;
      const stage = '.arcaea-manager-import-364';
      await storage.createDirectory(stage);
      await File(
        p.join(songs.path, stage, '4.aff'),
      ).writeAsString('partial copy');
      await File(
        p.join(songs.path, '.arcaea-manager-journal.json'),
      ).writeAsString(
        jsonEncode({
          'token': '364',
          'manifests': ['songlist'],
          'importId': 'original',
          'deleteIds': [],
        }),
      );
      await app.rescan();
      expect(await storage.kind(stage), isNull);
      expect(await storage.kind('original/base.ogg'), EntryKind.file);
      expect(app.songs.single.id, 'original');
    },
  );

  test(
    'case-variant duplicate id cannot quarantine a shared asset folder',
    () async {
      await write('songlist', {
        'songs': [
          {
            ...song('original', [0]),
            'idx': 2,
          },
          {
            ...song('ORIGINAL', [0]),
            'idx': 7,
          },
        ],
      });
      await app.rescan();
      await expectLater(app.deleteSongs(['ORIGINAL']), throwsStateError);
      expect(
        await app.fileService.storage.kind('original/base.ogg'),
        EntryKind.file,
      );
      expect(await rows('songlist', 'songs'), hasLength(2));
    },
  );

  test(
    'simultaneous writers keep both edits when they share one library',
    () async {
      final second = AppState();
      addTearDown(second.dispose);
      await second.setBasePathAndScan(songs.path);
      await Future.wait([
        app.updateSong('original', {
          'title_localized': {'en': 'title'},
        }),
        second.updateSong('original', {'artist': 'artist'}),
      ]);
      final entry = (await rows('songlist', 'songs')).single as Map;
      expect(entry['title_localized'], {'en': 'title', 'ja': '日本語'});
      expect(entry['artist'], 'artist');
    },
  );
  test(
    'permanently hidden placeholders are excluded from difficulty categories',
    () async {
      await write('songlist', {
        'songs': [
          {
            ...song('placeholder', [3]),
            'idx': 1,
            'difficulties': [
              {'ratingClass': 0, 'rating': 0, 'hidden_until': 'always'},
              {'ratingClass': 3, 'rating': 11},
            ],
          },
        ],
      });
      await app.rescan();
      app.setDifficultyFilter(RatingClass.past);
      expect(app.filteredSongs, isEmpty);
      app.setDifficultyFilter(RatingClass.beyond);
      expect(app.filteredSongs.single.availableDifficulties.single.rating, 11);
    },
  );

  testWidgets('difficulty filters and sorting work from the song grid', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.runAsync(() async {
      final entries = {
        'five-charts': [0, 1, 2, 3, 4],
        'etr-only': [0, 1, 2, 4],
        'byd-only': [0, 1, 2, 3],
      };
      for (final entry in entries.entries) {
        final folder = await Directory(p.join(songs.path, entry.key)).create();
        for (final chart in entry.value) {
          await File(
            p.join(folder.path, RatingClass.chartName(chart)),
          ).create();
        }
      }
      await write('songlist', {
        'songs': [
          for (final (index, entry) in entries.entries.indexed)
            {...song(entry.key, entry.value), 'idx': index + 1},
        ],
      });
      await app.rescan();
    });

    Widget page({double scale = 1}) => ChangeNotifierProvider.value(
      value: app,
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: const SongManagementPage(),
      ),
    );
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    final fiveChartCard = find.ancestor(
      of: find.text('five-charts'),
      matching: find.byType(Card),
    );
    final fiveBadges = find.descendant(
      of: fiveChartCard,
      matching: find.byType(DifficultyBadge),
    );
    expect(fiveBadges, findsNWidgets(5));
    expect(
      tester
          .widgetList<DifficultyBadge>(fiveBadges)
          .every((badge) => !badge.highlighted),
      isTrue,
    );

    tester.view.physicalSize = const Size(413, 760);
    await tester.pumpWidget(page(scale: 2));
    await tester.pumpAndSettle();
    expect(fiveBadges, findsNWidgets(5));
    final cardBounds = tester.getRect(fiveChartCard);
    for (var index = 0; index < 5; index++) {
      final bounds = tester.getRect(fiveBadges.at(index));
      expect(bounds.bottom, lessThanOrEqualTo(cardBounds.bottom));
      expect(bounds.right, lessThanOrEqualTo(cardBounds.right));
    }
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(360, 760);
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Eternal'));
    await tester.pumpAndSettle();
    expect(find.text('etr-only'), findsOneWidget);
    expect(find.text('byd-only'), findsNothing);
    final highlighted = find.byWidgetPredicate(
      (widget) => widget is DifficultyBadge && widget.highlighted,
    );
    expect(highlighted, findsNWidgets(2));
    expect(
      tester
          .widgetList<DifficultyBadge>(highlighted)
          .every(
            (badge) => badge.difficulty.ratingClass == RatingClass.eternal,
          ),
      isTrue,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('排序方式'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(CheckedPopupMenuItem<SongSortMode>, '歌曲名称'),
    );
    await tester.pumpAndSettle();
    expect(app.songSortMode, SongSortMode.title);
    expect(app.filteredSongs.first.id, 'etr-only');

    await tester.tap(find.text('five-charts'));
    await tester.pumpAndSettle();
    expect(find.byType(SongDetailPage), findsOneWidget);
    expect(highlighted, findsWidgets);
    expect(
      tester
          .widgetList<DifficultyBadge>(highlighted)
          .every(
            (badge) => badge.difficulty.ratingClass == RatingClass.eternal,
          ),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });
}

class _MemoryCatalogCache extends CacheService {
  CatalogIndex? index;
  int saves = 0;

  @override
  Future<CatalogIndex?> load(String identity) async => index;

  @override
  Future<void> save(
    String identity,
    String fingerprint,
    Map<String, SongFolder> folderFiles,
  ) async {
    saves++;
    index = (fingerprint: fingerprint, files: folderFiles);
  }
}

class _CountingStorage extends ArcStorage {
  _CountingStorage(super.location);

  final listedSongs = <List<String>>[];

  @override
  Future<Map<String, SongFolder>> listSongFiles(Iterable<String> ids) {
    final batch = ids.toList();
    listedSongs.add(batch);
    return super.listSongFiles(batch);
  }
}

class _FailingStorage extends ArcStorage {
  bool _failed = false;

  _FailingStorage(super.location);

  @override
  Future<void> rename(String name, String newName) {
    if (!_failed && name.contains('-stage-') && newName == 'unlocks') {
      _failed = true;
      return Future.error(const FileSystemException('injected failure'));
    }
    return super.rename(name, newName);
  }
}
