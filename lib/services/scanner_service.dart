import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/difficulty.dart';
import '../models/pack.dart';
import '../models/song.dart';
import '../models/unlock.dart';
import 'arc_storage.dart';
import 'arc_transaction.dart';
import 'cache_service.dart';
import 'catalog_documents.dart';

class ScanResult {
  final Map<String, String> manifests;
  final Map<String, SongFolder> folderFiles;
  final List<Pack> packs;
  final List<Song> songs;
  final List<Unlock> unlocks;
  final Map<String, List<Unlock>> unlocksBySongId;
  final Map<String, List<Song>> songsByPack;
  final DateTime scanTime;
  final bool fromCache;

  ScanResult(
    this.manifests,
    this.folderFiles,
    this.packs,
    this.songs,
    this.unlocks, {
    required this.fromCache,
  }) : scanTime = DateTime.now(),
       unlocksBySongId = <String, List<Unlock>>{},
       songsByPack = <String, List<Song>>{} {
    for (final unlock in unlocks) {
      unlocksBySongId.putIfAbsent(unlock.songId, () => []).add(unlock);
    }
    for (final song in songs) {
      songsByPack.putIfAbsent(song.set_, () => []).add(song);
    }
  }
}

class ParsedCatalog {
  final Map<String, String> manifests;
  final List<Pack> packs;
  final List<Song> songs;
  final List<Unlock> unlocks;

  ParsedCatalog(this.manifests, this.packs, this.songs, this.unlocks);

  ScanResult attach(Map<String, SongFolder> files, {bool fromCache = false}) {
    final songsWithFiles = songs.map((song) {
      final folder = files[song.id];
      final names = folder?.files ?? const <String>[];
      final normalized = names.map((name) => name.toLowerCase()).toSet();
      return song.copyWith(
        folderPath: folder?.name,
        folderFiles: names,
        hasBeyondChart: normalized.contains(
          RatingClass.chartName(RatingClass.beyond),
        ),
        hasEternalChart: normalized.contains(
          RatingClass.chartName(RatingClass.eternal),
        ),
      );
    }).toList();
    return ScanResult(
      manifests,
      files,
      packs,
      songsWithFiles,
      unlocks,
      fromCache: fromCache,
    );
  }
}

class ScannerService {
  final CacheService _cache;
  ScannerService(this._cache);

  Future<ScanResult> scan(
    ArcStorage storage, {
    bool force = false,
    ScanResult? previous,
  }) => storage.withLock(() async {
    await ArcTransaction(storage).recover();
    final bytes = await CatalogDocuments.read(storage);
    final catalog = await parse(
      bytes,
      previous: previous,
      isArc4: storage.isArc4,
    );
    final fingerprint = _fingerprint(bytes);
    final cached = force ? null : await _cache.load(storage.identity);
    if (cached?.fingerprint == fingerprint) {
      return catalog.attach(cached!.files, fromCache: true);
    }

    final ids = catalog.songs.map((song) => song.id).toSet();
    final files = <String, SongFolder>{
      for (final id in ids) id: ?cached?.files[id],
    };
    final missing = ids.difference(files.keys.toSet());
    if (missing.isNotEmpty) files.addAll(await storage.listSongFiles(missing));
    await _cache.save(storage.identity, fingerprint, files);
    return catalog.attach(files, fromCache: cached != null);
  });

  Future<ParsedCatalog> parse(
    Map<String, Uint8List> bytes, {
    ScanResult? previous,
    required bool isArc4,
  }) => compute(_parse, (bytes: bytes, previous: previous, isArc4: isArc4));

  Future<void> save(
    ArcStorage storage,
    Map<String, Uint8List> bytes,
    ScanResult result,
  ) => _cache.save(storage.identity, _fingerprint(bytes), result.folderFiles);
}

String _fingerprint(Map<String, Uint8List> documents) {
  var hash = 0xcbf29ce484222325;
  for (final name in CatalogDocuments.keys.keys) {
    final bytes = documents[name]!;
    for (final value in bytes) {
      hash = (hash ^ value) * 0x100000001b3;
    }
    hash = (hash ^ bytes.length) * 0x100000001b3;
  }
  return hash.toRadixString(16);
}

ParsedCatalog _parse(
  ({Map<String, Uint8List> bytes, ScanResult? previous, bool isArc4}) input,
) {
  final text = input.bytes.map(
    (name, bytes) => MapEntry(name, utf8.decode(bytes)),
  );
  final previous = input.previous;

  List<T> entries<T>(
    String name,
    T Function(Map<String, dynamic>, int?, int) build,
  ) {
    try {
      final source = text[name]!;
      final key = CatalogDocuments.keys[name]!;
      final json = jsonDecode(source) as Map<String, dynamic>;
      final lines = _entryLines(source, key);
      final rows = (json[key] as List).cast<Map<String, dynamic>>();
      return [
        for (var index = 0; index < rows.length; index++)
          build(rows[index], index < lines.length ? lines[index] : null, index),
      ];
    } catch (error) {
      throw FormatException('$name 格式无效：$error');
    }
  }

  bool unchanged(String name) => previous?.manifests[name] == text[name];

  return ParsedCatalog(
    text,
    unchanged('packlist')
        ? previous!.packs
        : entries(
            'packlist',
            (json, line, _) => Pack.fromJson(json, lineNumber: line),
          ),
    unchanged('songlist')
        ? previous!.songs
        : entries(
            'songlist',
            (json, line, index) => Song.fromJson(
              json,
              lineNumber: line,
              recordIndex: index,
              isArc4: input.isArc4,
            ),
          ),
    unchanged('unlocks')
        ? previous!.unlocks
        : entries(
            'unlocks',
            (json, line, _) => Unlock.fromJson(json, lineNumber: line),
          ),
  );
}

/// Collect the start line of each direct object in the named top-level array.
List<int> _entryLines(String source, String key) {
  final result = <int>[];
  var depth = 0;
  var line = 1;
  var offset = 0;
  var awaitingArray = false;
  var inArray = false;
  final quotedKey = jsonEncode(key);

  for (final token in RegExp(
    r'"(?:\\.|[^"\\])*"|[{}\[\]:,]',
  ).allMatches(source)) {
    for (; offset < token.start; offset++) {
      if (source.codeUnitAt(offset) == 10) line++;
    }
    offset = token.end;
    final value = token.group(0);
    if (depth == 1 && value == quotedKey) awaitingArray = true;
    if (value == '[' || value == '{') {
      if (depth == 1) {
        inArray = awaitingArray && value == '[';
        awaitingArray = false;
      }
      if (inArray && depth == 2 && value == '{') result.add(line);
      depth++;
    } else if (value == ']' || value == '}') {
      depth--;
      if (depth == 1 && inArray) return result;
    } else if (depth == 1 && value == ',') {
      awaitingArray = false;
    }
  }
  return result;
}
