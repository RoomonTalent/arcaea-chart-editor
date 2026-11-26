import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:path_provider/path_provider.dart';

import '../models/difficulty.dart';
import '../models/song.dart';
import '../services/arc_storage.dart';
import 'aff_chart.dart';
import 'chart_skin.dart';

typedef ChartBackup = ({String name, DateTime time, String? label});

class ChartBackupHistory {
  ChartBackupHistory(this.folder, this._prefix, {ArcStorage? lock})
    : _lock = lock ?? folder;

  final ArcStorage folder, _lock;
  final String _prefix;

  static Future<ChartBackupHistory> standalone(String source) async {
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    final id = sha256.convert(utf8.encode(source));
    return ChartBackupHistory(ArcStorage(directory.path), '.aff-draft-$id-');
  }

  ChartBackup? _backup(String name) {
    if (!name.startsWith(_prefix) || !name.endsWith('.bak')) return null;
    final parts = name.substring(_prefix.length, name.length - 4).split('~');
    final stamp = int.tryParse(parts.first);
    if (stamp == null || stamp < 0 || stamp > 8640000000000000) return null;
    return (
      name: name,
      time: DateTime.fromMicrosecondsSinceEpoch(stamp),
      label: parts.length == 2 ? parts.last : null,
    );
  }

  Future<List<ChartBackup>> list() => _lock.withLock(
    () async => [
      for (final entry in await folder.list())
        if (entry.kind == EntryKind.file) ?_backup(entry.name),
    ]..sort((a, b) => b.time.compareTo(a.time)),
  );

  Future<String> read(ChartBackup backup) => _lock.withLock(() async {
    _validate(backup);
    return ChartFiles.decode(await folder.read(backup.name));
  });

  Future<void> delete(ChartBackup backup) => _lock.withLock(() async {
    _validate(backup);
    await folder.removeFile(backup.name);
  });

  void _validate(ChartBackup backup) {
    if (_backup(backup.name) != backup ||
        backup.name.contains(RegExp(r'[/\\:]'))) {
      throw ArgumentError('备份不属于此谱面');
    }
  }

  Future<void> add(String text, {String? label}) => _lock.withLock(() async {
    final safeLabel = label?.replaceAll(
      RegExp(r'[^\p{L}\p{N} ._-]', unicode: true),
      '_',
    );
    final suffix = safeLabel == null
        ? ''
        : '~${String.fromCharCodes(safeLabel.runes.take(48))}';
    var stamp = DateTime.now().microsecondsSinceEpoch;
    String name() => '$_prefix$stamp$suffix.bak';
    while (await folder.kind(name()) != null) {
      stamp++;
    }
    final pending = '${_prefix}writing';
    await folder.removeFile(pending);
    await folder.write(pending, Uint8List.fromList(utf8.encode(text)));
    await folder.rename(pending, name());
  });
}

class ChartFiles {
  ChartFiles(
    ArcStorage songs,
    String id,
    this.ratingClass, {
    this.root,
    this.song,
  }) : _songs = songs,
       folder = songs.child(song?.folderPath ?? id),
       name =
           song?.assetName(RatingClass.chartName(ratingClass)) ??
           RatingClass.chartName(ratingClass),
       override = song?.assetName('$ratingClass.ogg') ?? '$ratingClass.ogg' {
    if (!ArcStorage.isSongDirectoryName(song?.folderPath ?? id)) {
      throw FormatException('无效的歌曲资源目录：$id');
    }
    if (!RatingClass.values.contains(ratingClass)) {
      throw ArgumentError.value(ratingClass);
    }
  }

  final ArcStorage _songs, folder;
  final ArcStorage? root;
  final Song? song;
  final int ratingClass;
  double? get bpmBase =>
      song?.difficultyFor(ratingClass)?.bpmBase ?? song?.bpmBase;
  List<String> get backgrounds => [
    song?.difficultyFor(ratingClass)?.bg ?? '',
    song?.bg ?? '',
  ];
  final String name, override;
  bool get isArc4 => _songs.isArc4;
  String get _pending => '.arcaea-aff-pending-$name';
  String get _stage => '.arcaea-aff-stage-$name';
  String get _backupPrefix => '.arcaea-aff-backup-$name-';

  Future<ChartBackupHistory> backupHistory() async {
    await _songs.withLock(_recover);
    return ChartBackupHistory(folder, _backupPrefix, lock: _songs);
  }

  Future<Uint8List> open() => _songs.withLock(() async {
    await _recover();
    return folder.read(name);
  });

  Future<Map<String, String>?> audioSource() async {
    for (final candidate in [
      override,
      song?.assetName('base.ogg') ?? 'base.ogg',
    ]) {
      if (await folder.kind(candidate) == EntryKind.file) {
        return folder.mediaSource(candidate);
      }
    }
    return null;
  }

  Future<ChartSkin> skin() => ChartSkin.load(
    folder: folder,
    root: root,
    chartKey: '$ratingClass',
    side: song?.side ?? 0,
    backgrounds: backgrounds,
    knownFiles: song?.folderPath == null ? null : song!.folderFiles,
  );

  Future<Uint8List> save(Uint8List original, String text) async {
    final chart = AffChart.parse(text);
    if (chart.errors.isNotEmpty) throw FormatException(chart.errors.first);
    final bytes = Uint8List.fromList(utf8.encode(text));
    return _songs.withLock(() async {
      await _recover();
      final current = await folder.read(name);
      if (!listEquals(current, original)) {
        throw StateError('$name 已在其他地方修改，请先导出当前草稿，再重新打开。');
      }
      if (listEquals(current, bytes)) return current;
      await folder.write(_stage, bytes);
      try {
        await folder.rename(name, _pending);
        await folder.rename(_stage, name);
      } catch (_) {
        await _recover();
        if (!listEquals(await folder.read(name), bytes)) rethrow;
      }
      try {
        await _recover();
      } catch (_) {
        // The updated file and its pending backup are both available.
      }
      return bytes;
    });
  }

  Future<String?> lastBackup() async {
    final history = await backupHistory();
    final backups = await history.list();
    return backups.isEmpty ? null : history.read(backups.first);
  }

  Future<void> _recover() async {
    if (await folder.kind(_pending) == EntryKind.file) {
      if (await folder.kind(name) == null) {
        await folder.rename(_pending, name);
      } else {
        var timestamp = DateTime.now().microsecondsSinceEpoch;
        String backup() => '$_backupPrefix$timestamp.bak';
        while (await folder.kind(backup()) != null) {
          timestamp++;
        }
        await folder.rename(_pending, backup());
      }
    }
    await folder.removeFile(_stage);
  }

  static String decode(Uint8List bytes) {
    final text = utf8.decode(bytes);
    return bytes.length >= 3 &&
            bytes[0] == 0xef &&
            bytes[1] == 0xbb &&
            bytes[2] == 0xbf
        ? '\uFEFF$text'
        : text;
  }
}
