import 'dart:convert';
import 'dart:typed_data';

import 'arc_storage.dart';
import 'file_service.dart';

class CatalogDocuments {
  static const keys = {
    'packlist': 'packs',
    'songlist': 'songs',
    'unlocks': 'unlocks',
  };

  final Map<String, Uint8List> original;
  final Map<String, Map<String, dynamic>> _documents;
  final bool isArc4;

  CatalogDocuments(this.original, {this.isArc4 = false})
    : _documents = original.map((name, bytes) {
        try {
          final document =
              jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
          final rows = document[keys[name]] as List;
          rows.cast<Map<String, dynamic>>().toList();
          return MapEntry(name, document);
        } catch (error) {
          throw FormatException('$name 格式无效：$error');
        }
      });

  static Future<Map<String, Uint8List>> read(ArcStorage storage) =>
      storage.readFiles(FileService.manifests);

  List<Map<String, dynamic>> rows(String name) =>
      (_documents[name]![keys[name]] as List).cast<Map<String, dynamic>>();

  String encode(String name) =>
      const JsonEncoder.withIndent('    ').convert(_documents[name]);

  Map<String, dynamic> songRow(String id, {int? recordIndex}) {
    if (recordIndex == null) return _byId('songlist', id);
    final songs = rows('songlist');
    if (recordIndex < 0 ||
        recordIndex >= songs.length ||
        songs[recordIndex]['id'] != id) {
      throw StateError('歌曲清单已变化，请重新选择歌曲');
    }
    return songs[recordIndex];
  }

  void editSong(String id, Map<String, dynamic> changes, {int? recordIndex}) =>
      _merge(songRow(id, recordIndex: recordIndex), changes, 'title_localized');

  void setChartBpmBase(
    String id,
    int ratingClass,
    double bpm, {
    int? recordIndex,
  }) {
    final song = songRow(id, recordIndex: recordIndex);
    final difficulties = (song['difficulties'] ?? song['iculties']) as List?;
    final difficulty = difficulties
        ?.whereType<Map<String, dynamic>>()
        .where((entry) => entry['ratingClass'] == ratingClass)
        .firstOrNull;
    if (difficulty == null) throw StateError('songlist 中找不到对应的难度条目');
    if (!bpm.isFinite || bpm <= 0) throw const FormatException('基准 BPM 必须大于 0');
    difficulty['bpm_base'] = bpm;
  }

  void editPack(String id, Map<String, dynamic> changes) {
    if (changes.containsKey('pack_parent')) {
      _validateParent(id, changes['pack_parent'] as String?);
    }
    _merge(_byId('packlist', id), changes, 'name_localized');
  }

  void addPack(Map<String, dynamic> pack) {
    final id = pack['id'] as String;
    FileService.validateId(id);
    _requireUnused('packlist', id);
    _validateParent(id, pack['pack_parent'] as String?);
    rows('packlist').add(pack);
  }

  Map<String, dynamic> songTransfer(String id, {int? recordIndex}) {
    final song = songRow(id, recordIndex: recordIndex);
    return {
      'song': song,
      'packs': packsFor([
        if (song['set'] case final String id when id != 'single') id,
      ]),
      'unlocks': rows('unlocks').where((row) => row['songId'] == id).toList(),
    };
  }

  List<Map<String, dynamic>> packsFor(Iterable<String> ids) {
    final packs = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final id in ids) {
      final parents = <Map<String, dynamic>>[];
      final branch = <String>{};
      String? current = id;
      while (current != null && current.isNotEmpty && !seen.contains(current)) {
        if (!branch.add(current)) throw StateError('曲包存在循环上级');
        final record = _byId('packlist', current);
        parents.add(record);
        current = record['pack_parent'] as String?;
      }
      for (final record in parents.reversed) {
        seen.add(record['id'] as String);
        packs.add(record);
      }
    }
    return packs;
  }

  Set<String> songsInPacks(Set<String> packs) => {
    for (final row in rows('songlist'))
      if (packs.contains(row['set'])) row['id'] as String,
  };

  Set<int> songRecordsInPacks(Set<String> packs) => {
    for (final (index, row) in rows('songlist').indexed)
      if (packs.contains(row['set'])) index,
  };

  void removePacks(Set<String> ids) {
    for (final id in ids) {
      _byId('packlist', id);
    }
    for (final song in rows('songlist')) {
      if (ids.contains(song['set'])) song['set'] = 'single';
    }
    for (final pack in rows('packlist')) {
      if (ids.contains(pack['pack_parent'])) pack.remove('pack_parent');
    }
    rows('packlist').removeWhere((pack) => ids.contains(pack['id']));
  }

  bool restorePacks(List<Map<String, dynamic>> packs) {
    var changed = false;
    for (final pack in packs) {
      final id = pack['id'] as String;
      if (rows('packlist').any((entry) => entry['id'] == id)) {
        _byId('packlist', id);
        continue;
      }
      addPack(pack);
      changed = true;
    }
    return changed;
  }

  void removePack(String id) {
    final pack = _byId('packlist', id);
    final songs = rows('songlist').where((entry) => entry['set'] == id).length;
    final children = rows(
      'packlist',
    ).where((entry) => entry['pack_parent'] == id).length;
    if (songs > 0 || children > 0) {
      throw StateError('请先迁移此曲包的 $songs 首歌曲和 $children 个子曲包');
    }
    rows('packlist').remove(pack);
  }

  void addSong(
    String id,
    Map<String, dynamic> song,
    List<Map<String, dynamic>> unlocks,
  ) {
    FileService.validateId(id);
    if (song['id'] != id) throw StateError('歌曲 ID 不一致');
    _requireUnused('songlist', id);
    validateSongPack(song['set'] as String? ?? '');
    if (rows('unlocks').any((entry) => entry['songId'] == id)) {
      throw StateError('歌曲 $id 已有解锁条目，请先处理现有条目');
    }

    // Existing indices can contain gaps and may be referenced outside this file.
    var nextIndex = 0;
    for (final entry in rows('songlist')) {
      final index = entry['idx'];
      if (index is int && index >= nextIndex) nextIndex = index + 1;
    }
    final record = {...song};
    if (isArc4) {
      record.remove('idx');
    } else {
      record['idx'] = nextIndex;
    }
    rows('songlist').add(record);
    rows('unlocks').addAll(unlocks);
  }

  void removeSongs(Set<String> ids) {
    for (final id in ids) {
      FileService.validateId(id);
      _byId('songlist', id);
      final key = FileService.idKey(id);
      if (rows('songlist').any((entry) {
        final other = entry['id'];
        return other is String &&
            other != id &&
            FileService.idKey(other) == key;
      })) {
        throw StateError('存在大小写不同的同名歌曲，请先处理重复 ID：$id');
      }
    }
    rows('songlist').removeWhere((entry) => ids.contains(entry['id']));
    rows('unlocks').removeWhere((entry) => ids.contains(entry['songId']));
  }

  Set<String> removeSongRecords(Set<int> indices) {
    final songs = rows('songlist');
    final removed = <String>{};
    for (final index in indices.toList()..sort((a, b) => b.compareTo(a))) {
      removed.add(songs.removeAt(index)['id'] as String);
    }
    final remaining = songs.map((song) => song['id']).toSet();
    rows('unlocks').removeWhere(
      (entry) =>
          removed.contains(entry['songId']) &&
          !remaining.contains(entry['songId']),
    );
    return removed;
  }

  void validateSongPack(String? id) {
    if (id != null && id != 'single') _byId('packlist', id);
  }

  void _validateParent(String id, String? parent) {
    final visited = {FileService.idKey(id)};
    while (parent != null && parent.isNotEmpty) {
      if (!visited.add(FileService.idKey(parent))) {
        throw StateError('曲包不能成为自己的上级');
      }
      parent = _byId('packlist', parent)['pack_parent'] as String?;
    }
  }

  Map<String, dynamic> _byId(String name, String id) {
    final matches = rows(name).where((entry) => entry['id'] == id).toList();
    if (matches.length != 1) {
      throw StateError(
        matches.isEmpty ? '$name 中找不到 ID：$id' : '$name 中存在重复 ID：$id',
      );
    }
    return matches.single;
  }

  void _requireUnused(String name, String id) {
    final key = FileService.idKey(id);
    if (rows(name).any(
      (entry) =>
          entry['id'] is String &&
          FileService.idKey(entry['id'] as String) == key,
    )) {
      throw StateError('$name 中已存在 ID：$id');
    }
  }

  void _merge(
    Map<String, dynamic> record,
    Map<String, dynamic> changes,
    String localeKey,
  ) {
    for (final entry in changes.entries) {
      if (entry.key == localeKey) {
        record[localeKey] = {
          ...?record[localeKey] as Map<String, dynamic>?,
          ...entry.value as Map<String, dynamic>,
        };
      } else if (entry.value == null) {
        record.remove(entry.key);
      } else {
        record[entry.key] = entry.value;
      }
    }
  }
}
