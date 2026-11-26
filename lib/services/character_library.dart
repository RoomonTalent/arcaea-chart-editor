import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:shared_preferences/shared_preferences.dart';

import 'arc_storage.dart';
import 'gettext_catalog.dart';
import 'transfer_bundle.dart';

class CharacterAsset {
  final String id;
  final List<String> paths;

  CharacterAsset(this.id, this.paths);

  int get number => int.parse(RegExp(r'^-?\d+').stringMatch(id)!);

  List<String> get previewPaths => [
    ...paths.where((name) => name.endsWith('_icon.png')),
    ...paths.where((name) => !name.endsWith('_icon.png')),
  ];
}

class CharacterLibrary {
  final ArcStorage root;
  final SharedPreferences _preferences;
  final Map<String, dynamic> _profiles;
  final String _settingsKey;
  Map<int, Map<String, String>> _reference;

  CharacterLibrary._(
    this.root,
    this._preferences,
    this._profiles,
    this._settingsKey,
    this._reference,
  );

  static const languages = ['zh-Hans', 'zh-Hant', 'ja', 'ko'];
  static final _backupPattern = RegExp(
    r'^\.arcaea-manager-original-(\d+)-(.+)$',
  );
  static final _portraitPattern = RegExp(
    r'^(-?\d+[a-z]*)(?:_([a-z0-9]+))?\.png$',
  );
  static final _profileId = RegExp(r'^-?\d{1,8}[a-z]*$');
  static final _voice = RegExp(r'^(-?\d+)_[a-z0-9_]+\.ogg$');

  static Future<CharacterLibrary> open(ArcStorage root) async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'arcaea_character_profiles_${root.identity}';
    if (await root.kind(_importJournal) == EntryKind.file) {
      await root.withLock(() => _recoverImport(root, prefs, key));
    }
    final data =
        jsonDecode(prefs.getString(key) ?? '{}') as Map<String, dynamic>;
    return CharacterLibrary._(
      root,
      prefs,
      (data['profiles'] as Map<String, dynamic>?) ?? {},
      key,
      _readReference(data['reference'] ?? []),
    );
  }

  Future<List<CharacterAsset>> list() async {
    final groups = <String, Set<String>>{};
    for (final directory in ['char', 'char/1080']) {
      if (await root.kind(directory) != EntryKind.directory) continue;
      final files = await root.list(directory);
      final removed = {
        for (final file in files)
          if (RegExp(
                r'^\.arcaea-manager-removed-\d+-(.+)$',
              ).firstMatch(file.name)
              case final match?)
            match[1]!,
      };
      for (final file in files) {
        if (file.kind != EntryKind.file) continue;
        final backup = _backupPattern.firstMatch(file.name);
        final name = backup?.group(2) ?? file.name;
        if (backup != null && removed.contains(name)) continue;
        final match = _portraitPattern.firstMatch(name);
        if (match == null) continue;
        groups.putIfAbsent(match.group(1)!, () => {}).add('$directory/$name');
      }
    }
    return [
      for (final group in groups.entries)
        CharacterAsset(group.key, group.value.toList()..sort()),
    ]..sort((a, b) {
      final number = a.number.compareTo(b.number);
      return number != 0 ? number : a.id.compareTo(b.id);
    });
  }

  Map<String, dynamic> profile(String id) =>
      Map<String, dynamic>.from((_profiles[id] as Map?) ?? {});

  String? referenceName(int id) =>
      const {0: 'Hikari', 1: 'Tairitsu'}[id] ?? _reference[id]?['name'];

  String? defaultSkill(int id) =>
      _reference[id]?['skill_id'] ?? (id == 0 ? 'gauge_easy' : null);

  List<String> get skills => {
    'gauge_easy',
    'note_mirror',
    for (final entry in _reference.values) ...[
      if (entry['skill_id'] case final skill? when skill.isNotEmpty) skill,
      if (entry['skill_id_uncap'] case final skill? when skill.isNotEmpty)
        skill,
    ],
  }.toList()..sort();

  Future<void> updateProfile(String id, Map<String, dynamic> fields) async {
    final next = {..._profiles, id: fields};
    await _persist(next, _reference);
    _profiles[id] = fields;
  }

  Future<int> importReference(Uint8List bytes) async {
    final reference = _readReference(jsonDecode(utf8.decode(bytes)));
    if (reference.isEmpty) throw const FormatException('资料中没有有效的人物 ID 和名称');
    await _persist(_profiles, reference);
    _reference = reference;
    return reference.length;
  }

  Future<void> _checkExportDestination(ArcStorage destination) async {
    for (final directory in ['char', 'voice', 'tl']) {
      if (await destination.isWithin(root.child(directory))) {
        throw StateError('请选择人物资源目录之外的导出位置');
      }
    }
  }

  Future<String> exportCharacter(CharacterAsset asset, String location) async {
    final destination = ArcStorage(location);
    await _checkExportDestination(destination);
    return root.withReadLock(() async {
      final data = await _characterTransfer(asset.number, await list());
      return TransferBundle.write(
        destination: destination,
        name: asset.id,
        type: 'character',
        data: data,
        writeAssets: (folder) => _copyCharacterAssets(data, folder),
      );
    });
  }

  Future<String> exportCharacters(Set<int> ids, String location) async {
    final destination = ArcStorage(location);
    await _checkExportDestination(destination);
    if (ids.isEmpty) throw StateError('没有选中的人物');
    return root.withReadLock(() async {
      final assets = await list();
      final entries = [
        for (final id in ids) await _characterTransfer(id, assets),
      ];
      return TransferBundle.write(
        destination: destination,
        name: 'share',
        type: 'characters',
        data: {'ids': ids.toList()},
        writeAssets: (folder) async {
          for (final data in entries) {
            final id = data['id'];
            await folder.createDirectory('$id');
            final target = folder.child('$id');
            await _copyCharacterAssets(data, target);
            await target.write(
              TransferBundle.manifest,
              utf8.encode(
                jsonEncode({'version': 1, 'type': 'character', ...data}),
              ),
            );
          }
        },
      );
    });
  }

  Future<Map<String, dynamic>> _characterTransfer(
    int id,
    List<CharacterAsset> assets,
  ) async {
    final related = assets.where((entry) => entry.number == id).toList();
    final files = <String>[];
    for (final path in related.expand((entry) => entry.paths)) {
      if (await root.kind(path) == EntryKind.file) files.add(path);
    }
    if (await root.kind('voice') == EntryKind.directory) {
      for (final entry in await root.list('voice')) {
        if (entry.kind == EntryKind.file &&
            _voice.firstMatch(entry.name)?.group(1) == '$id') {
          files.add('voice/${entry.name}');
        }
      }
    }
    if (!files.any((path) => path.startsWith('char/'))) {
      throw StateError('没有可导出的人物立绘');
    }
    final profiles = {for (final entry in related) entry.id: profile(entry.id)};
    final nameKeys = {
      ?referenceName(id),
      for (final profile in profiles.values)
        if (profile['translationKey'] case final String key when key.isNotEmpty)
          key,
    };
    final translations = <String, Map<String, String>>{};
    for (final language in languages) {
      final catalog = await loadTranslations(language);
      if (catalog == null) continue;
      final names = nameKeys.map((key) => key.toLowerCase()).toSet();
      translations[language] = {
        for (final entry in catalog.messages.entries)
          if (names.contains(entry.key.toLowerCase())) entry.key: entry.value,
      };
    }
    return {
      'id': id,
      'files': files,
      'profiles': profiles,
      'reference': ?_reference[id],
      'translations': translations,
    };
  }

  Future<void> _copyCharacterAssets(
    Map<String, dynamic> data,
    ArcStorage folder,
  ) async {
    final directories = <String>{};
    for (final path in data['files'] as List<String>) {
      await _ensureParents(folder, path, directories);
      await root.copyTo(path, folder, path);
    }
  }

  Future<void> removeCharacters(Set<int> ids) async {
    if (ids.isEmpty) return;
    await root.withLock(() async {
      await _recoverImport(root, _preferences, _settingsKey);
      final paths = <String>{};
      for (final asset in await list()) {
        if (!ids.contains(asset.number)) continue;
        for (final path in asset.paths) {
          if (await root.kind(path) == EntryKind.file) paths.add(path);
        }
      }
      if (await root.kind('voice') == EntryKind.directory) {
        for (final entry in await root.list('voice')) {
          final id = int.tryParse(
            _voice.firstMatch(entry.name)?.group(1) ?? '',
          );
          if (entry.kind == EntryKind.file && ids.contains(id)) {
            paths.add('voice/${entry.name}');
          }
        }
      }
      if (paths.isEmpty) return;
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final nextProfiles = {..._profiles}
        ..removeWhere(
          (key, _) =>
              _profileId.hasMatch(key) &&
              ids.contains(CharacterAsset(key, const []).number),
        );
      final nextReference = {..._reference}
        ..removeWhere((key, _) => ids.contains(key));
      try {
        await root.write(
          _importJournalStage,
          utf8.encode(
            jsonEncode({
              'stamp': stamp,
              'settingsKey': _settingsKey,
              'deleting': true,
              'files': [
                for (final path in paths) {'path': path, 'exists': true},
              ],
            }),
          ),
        );
        await root.rename(_importJournalStage, _importJournal);
        for (final path in paths) {
          final change = _CharacterChange(path, stamp, true, deleting: true);
          await root.rename(path, change.backup);
        }
        if (!await _preferences.setString(
          _settingsKey,
          _settingsData(nextProfiles, nextReference, importToken: stamp),
        )) {
          throw StateError('无法保存人物档案');
        }
      } catch (_) {
        await _preferences.reload();
        if (!_importCommitted(_preferences, _settingsKey, stamp)) {
          await _recoverImport(root, _preferences, _settingsKey);
          rethrow;
        }
      }
      _profiles
        ..clear()
        ..addAll(nextProfiles);
      _reference = nextReference;
      try {
        await _recoverImport(root, _preferences, _settingsKey);
      } catch (_) {
        // The committed journal will be cleaned up next time the library opens.
      }
      await root.invalidateArtwork();
    });
  }

  Future<int> importCharacter(
    ArcStorage bundle, {
    required bool replaceExisting,
  }) async {
    final data = await TransferBundle.read(bundle, 'character');
    final id = data['id'] as int;
    await importCharacters(
      {id: bundle},
      replaceExisting: {if (replaceExisting) id},
    );
    return id;
  }

  Future<int> importCharacters(
    Map<int, ArcStorage> bundles, {
    required Set<int> replaceExisting,
  }) async {
    final records = [
      for (final entry in bundles.entries)
        await _readCharacter(entry.key, entry.value),
    ];
    return root.withLock(() async {
      await _recoverImport(root, _preferences, _settingsKey);
      final existing = (await list()).map((asset) => asset.number).toSet();
      if (bundles.keys.any(
        (id) => existing.contains(id) && !replaceExisting.contains(id),
      )) {
        throw StateError('部分人物已存在，请确认替换后重新导入');
      }
      final paths = <String, ArcStorage>{};
      final profiles = <String, dynamic>{};
      final reference = <int, Map<String, String>>{};
      final translations = <String, Map<String, String>>{};
      for (final record in records) {
        if (!replaceExisting.contains(record.id) &&
            record.profiles.keys.any(_profiles.containsKey)) {
          throw StateError('人物 ${record.id} 的档案已存在');
        }
        paths.addAll(record.paths);
        profiles.addAll(record.profiles);
        reference.addAll(record.reference);
        for (final item in record.translations.entries) {
          translations.putIfAbsent(item.key, () => {}).addAll(item.value);
        }
      }
      final directories = <String>{};
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final plan = <_CharacterChange>[];
      final catalogs = <String, Uint8List>{};
      final nextReference = {..._reference, ...reference};
      final nextProfiles = {..._profiles, ...profiles};
      final serialized = _settingsData(
        nextProfiles,
        nextReference,
        importToken: stamp,
      );
      try {
        for (final path in paths.keys) {
          await _ensureParents(root, path, directories);
          plan.add(await _planChange(path, stamp));
        }
        for (final language in languages) {
          final entries = translations[language];
          if (entries == null || entries.isEmpty) continue;
          final catalog =
              await loadTranslations(language) ??
              GettextCatalog({'': 'Content-Type: text/plain; charset=UTF-8\n'});
          for (final entry in entries.entries) {
            final key = catalog.messages.keys.firstWhere(
              (key) => key.toLowerCase() == entry.key.toLowerCase(),
              orElse: () => entry.key,
            );
            catalog.messages[key] = entry.value;
          }
          final path = 'tl/$language.mo';
          await _ensureParents(root, path, directories);
          plan.add(await _planChange(path, stamp));
          catalogs[path] = catalog.encode();
        }
        await root.write(
          _importJournalStage,
          utf8.encode(
            jsonEncode({
              'stamp': stamp,
              'settingsKey': _settingsKey,
              'files': [
                for (final change in plan)
                  {'path': change.path, 'exists': change.existed},
              ],
            }),
          ),
        );
        await root.rename(_importJournalStage, _importJournal);
        for (final change in plan) {
          final catalog = catalogs[change.path];
          if (catalog == null) {
            await paths[change.path]!.copyTo(change.path, root, change.stage);
          } else {
            await root.write(change.stage, catalog);
          }
        }
        for (final change in plan) {
          if (change.existed) await root.rename(change.path, change.backup);
          await root.rename(change.stage, change.path);
        }
        if (!await _preferences.setString(_settingsKey, serialized)) {
          throw StateError('无法保存人物档案');
        }
      } catch (_) {
        await _preferences.reload();
        if (!_importCommitted(_preferences, _settingsKey, stamp)) {
          await _recoverImport(root, _preferences, _settingsKey);
          rethrow;
        }
      }
      _profiles.addAll(profiles);
      _reference = nextReference;
      try {
        await _recoverImport(root, _preferences, _settingsKey);
      } catch (_) {
        // Keep the committed journal for cleanup when the library is opened.
      }
      await root.invalidateArtwork();
      return bundles.length;
    });
  }

  Future<
    ({
      int id,
      Map<String, ArcStorage> paths,
      Map<String, dynamic> profiles,
      Map<int, Map<String, String>> reference,
      Map<String, Map<String, String>> translations,
    })
  >
  _readCharacter(int id, ArcStorage bundle) async {
    final data = await TransferBundle.read(bundle, 'character');
    if (data['id'] != id) throw const FormatException('人物包的 ID 与清单不一致');
    final paths = (data['files'] as List).cast<String>().toSet();
    bool belongs(String name) =>
        _profileId.hasMatch(name) &&
        CharacterAsset(name, const []).number == id;
    bool isPortrait(String path) {
      final parts = path.split('/');
      if (parts.first != 'char' ||
          (parts.length != 2 && !(parts.length == 3 && parts[1] == '1080'))) {
        return false;
      }
      final name = _portraitPattern.firstMatch(parts.last)?.group(1);
      return name != null && belongs(name);
    }

    bool isVoice(String path) {
      final parts = path.split('/');
      return parts.length == 2 &&
          parts.first == 'voice' &&
          _voice.firstMatch(parts.last)?.group(1) == '$id';
    }

    final profiles = (data['profiles'] as Map<String, dynamic>).map((
      key,
      value,
    ) {
      final profile = (value as Map<String, dynamic>);
      if (!belongs(key) ||
          [
            profile['alias'],
            profile['skill'],
            profile['translationKey'],
          ].any((item) => item != null && item is! String) ||
          (profile['offline'] != null && profile['offline'] is! bool)) {
        throw const FormatException('导入包含有无效的人物档案');
      }
      return MapEntry(key, {
        for (final field in ['alias', 'skill', 'translationKey', 'offline'])
          if (profile.containsKey(field)) field: profile[field],
      });
    });
    if (paths.length > 300 ||
        !paths.any(isPortrait) ||
        paths.any((path) => !isPortrait(path) && !isVoice(path))) {
      throw const FormatException('导入包包含无效的人物素材路径');
    }
    final reference = <int, Map<String, String>>{};
    if (data['reference'] case final Map entry) {
      reference.addAll(
        _readReference([
          {...entry, 'character_id': id},
        ]),
      );
    }
    final rawTranslations = (data['translations'] as Map<String, dynamic>);
    final nameKeys = {
      ?reference[id]?['name']?.toLowerCase(),
      ?referenceName(id)?.toLowerCase(),
      for (final profile in profiles.values)
        if (profile['translationKey'] case final String key) key.toLowerCase(),
    };
    final translations = <String, Map<String, String>>{};
    for (final language in languages) {
      final entries = rawTranslations[language];
      if (entries is! Map || entries.isEmpty) continue;
      final output = <String, String>{};
      for (final entry in entries.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is! String ||
            value is! String ||
            !nameKeys.contains(key.toLowerCase()) ||
            key.contains('\u0000') ||
            value.contains('\u0000')) {
          throw const FormatException('导入包包含无效的人物译文');
        }
        output[key] = value;
      }
      translations[language] = output;
    }
    for (final path in paths.where(isPortrait)) {
      await _verifyPng(await bundle.read(path));
    }
    return (
      id: id,
      paths: {for (final path in paths) path: bundle},
      profiles: profiles,
      reference: reference,
      translations: translations,
    );
  }

  static const _importJournal = '.arcaea-character-import.json';
  static const _importJournalStage = '.arcaea-character-import-stage.json';
  static const _importCommit = '.arcaea-character-import-committed';

  Future<_CharacterChange> _planChange(String path, int stamp) async {
    final kind = await root.kind(path);
    if (kind != null && kind != EntryKind.file) {
      throw StateError('人物素材目标不是文件：$path');
    }
    return _CharacterChange(path, stamp, kind == EntryKind.file);
  }

  static bool _importCommitted(
    SharedPreferences preferences,
    String key,
    int stamp,
  ) =>
      (jsonDecode(preferences.getString(key) ?? '{}') as Map)['importToken'] ==
      stamp;

  static Future<void> _recoverImport(
    ArcStorage root,
    SharedPreferences preferences,
    String key,
  ) async {
    if (await root.kind(_importJournal) != EntryKind.file) {
      await root.removeFile(_importJournalStage);
      await root.removeFile(_importCommit);
      return;
    }
    final data =
        jsonDecode(utf8.decode(await root.read(_importJournal))) as Map;
    final stamp = data['stamp'] as int;
    final savedKey = data['settingsKey'] as String? ?? key;
    if (!savedKey.startsWith('arcaea_character_profiles_') || stamp <= 0) {
      throw const FormatException('人物导入恢复日志格式无效');
    }
    final marked =
        await root.kind(_importCommit) == EntryKind.file &&
        utf8.decode(await root.read(_importCommit)) == '$stamp';
    final committed = marked || _importCommitted(preferences, savedKey, stamp);
    if (committed && !marked) {
      await root.write(_importCommit, utf8.encode('$stamp'));
    }
    for (final row in (data['files'] as List).reversed) {
      final path = row['path'] as String;
      if (!RegExp(
        r'^(?:char/(?:1080/)?-?\d+[a-z0-9_]*\.png|voice/-?\d+_[a-z0-9_]+\.ogg|tl/(?:zh-Hans|zh-Hant|ja|ko)\.mo)$',
      ).hasMatch(path)) {
        throw const FormatException('人物导入恢复日志路径无效');
      }
      final change = _CharacterChange(
        path,
        stamp,
        row['exists'] as bool,
        deleting: data['deleting'] == true,
      );
      if (!committed) {
        if (change.existed &&
            await root.kind(change.backup) == EntryKind.file) {
          await root.removeFile(path);
          await root.rename(change.backup, path);
        } else if (!change.existed && await root.kind(change.stage) == null) {
          await root.removeFile(path);
        }
      }
      if (change.existed || committed) await root.removeFile(change.stage);
    }
    if (!committed) {
      // Remove uninstalled stages only after all destination files are restored.
      for (final row in data['files'] as List) {
        if (row['exists'] == false) {
          await root.removeFile(
            _CharacterChange(row['path'] as String, stamp, false).stage,
          );
        }
      }
    }
    await root.removeFile(_importJournal);
    await root.removeFile(_importJournalStage);
    await root.removeFile(_importCommit);
  }

  static Future<void> _ensureParents(
    ArcStorage storage,
    String path,
    Set<String> directories,
  ) async {
    var prefix = '';
    for (final part in path.split('/')..removeLast()) {
      prefix = prefix.isEmpty ? part : '$prefix/$part';
      if (directories.add(prefix) && await storage.kind(prefix) == null) {
        await storage.createDirectory(prefix);
      }
    }
  }

  static Map<int, Map<String, String>> _readReference(dynamic value) {
    if (value is! List) {
      throw const FormatException('人物资料应为 characters.json 数组');
    }
    return {
      for (final row in value)
        if (row is Map && row['character_id'] is int && row['name'] is String)
          row['character_id'] as int: {
            for (final key in ['name', 'skill_id', 'skill_id_uncap'])
              if (row[key] is String) key: row[key] as String,
          },
    };
  }

  Future<void> _persist(
    Map<String, dynamic> profiles,
    Map<int, Map<String, String>> reference,
  ) async {
    if (await root.kind(_importJournal) == EntryKind.file) {
      await root.withLock(
        () => _recoverImport(root, _preferences, _settingsKey),
      );
    }
    final written = await _preferences.setString(
      _settingsKey,
      _settingsData(profiles, reference),
    );
    if (!written) throw StateError('无法保存人物档案');
  }

  static String _settingsData(
    Map<String, dynamic> profiles,
    Map<int, Map<String, String>> reference, {
    int? importToken,
  }) => jsonEncode({
    'profiles': profiles,
    'reference': [
      for (final item in reference.entries)
        {'character_id': item.key, ...item.value},
    ],
    'importToken': ?importToken,
  });

  Future<GettextCatalog?> loadTranslations(String language) async {
    if (!languages.contains(language)) throw ArgumentError.value(language);
    final path = 'tl/$language.mo';
    return await root.kind(path) == EntryKind.file
        ? GettextCatalog.decode(await root.read(path))
        : null;
  }

  Future<void> updateTranslation(
    String language,
    String key,
    String value,
  ) async {
    if (key.isEmpty ||
        key.contains('\u0000') ||
        value.trim().isEmpty ||
        value.contains('\u0000')) {
      throw const FormatException('请选择普通文本键并填写译文');
    }
    await root.withLock(() async {
      final catalog = await loadTranslations(language);
      if (catalog == null || !catalog.messages.containsKey(key)) {
        throw StateError('此语言的译文键不存在');
      }
      catalog.messages[key] = value.trim();
      await _replace('tl/$language.mo', catalog.encode());
    });
  }

  Future<List<String>> backups(String path) async {
    final separator = path.lastIndexOf('/');
    final directory = path.substring(0, separator);
    final name = path.substring(separator + 1);
    if (await root.kind(directory) != EntryKind.directory) return [];
    final backups = <(int, String)>[];
    for (final entry in await root.list(directory)) {
      final match = _backupPattern.firstMatch(entry.name);
      if (entry.kind == EntryKind.file && match?.group(2) == name) {
        backups.add((int.parse(match!.group(1)!), '$directory/${entry.name}'));
      }
    }
    backups.sort((a, b) => b.$1.compareTo(a.$1));
    return backups.map((entry) => entry.$2).toList();
  }

  Future<void> replacePortrait(String path, Uint8List bytes) async {
    if (!path.startsWith('char/') ||
        !_portraitPattern.hasMatch(path.split('/').last)) {
      throw const FormatException('无效的立绘文件');
    }
    await _verifyPng(bytes);
    await root.withLock(() async {
      await _replace(path, bytes);
      await root.invalidateArtwork();
    });
  }

  static Future<void> _verifyPng(Uint8List bytes) async {
    const signature = [137, 80, 78, 71, 13, 10, 26, 10];
    if (bytes.length < 24 ||
        bytes.length > 32 * 1024 * 1024 ||
        !List.generate(
          8,
          (i) => bytes[i] == signature[i],
        ).every((value) => value)) {
      throw const FormatException('请选择不超过 32 MB 的 PNG 图片');
    }
    final header = ByteData.sublistView(bytes);
    final width = header.getUint32(16);
    final height = header.getUint32(20);
    if (min(width, height) < 1 ||
        max(width, height) > 8192 ||
        width * height > 20000000) {
      throw const FormatException('图片尺寸超出支持范围');
    }
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: 1,
      targetHeight: 1,
    );
    try {
      final frame = await codec.getNextFrame();
      frame.image.dispose();
    } finally {
      codec.dispose();
    }
  }

  Future<void> restore(String path, {String? backup}) async {
    await root.withLock(() async {
      final versions = await backups(path);
      final source = backup ?? versions.firstOrNull;
      if (source == null || !versions.contains(source)) {
        throw StateError('找不到所选备份');
      }
      await _replace(path, await root.read(source));
      await root.invalidateArtwork();
    });
  }

  Future<String?> _replace(String path, Uint8List bytes) async {
    final index = path.lastIndexOf('/');
    final directory = path.substring(0, index);
    final name = path.substring(index + 1);
    final number = DateTime.now().microsecondsSinceEpoch;
    final staged = '$directory/.arcaea-manager-edit-$number-$name';
    final backup = '$directory/.arcaea-manager-original-$number-$name';
    var backedUp = false;
    try {
      await root.write(staged, bytes);
      if (await root.kind(path) != null) {
        await root.rename(path, backup);
        backedUp = true;
      }
      await root.rename(staged, path);
    } catch (_) {
      if (backedUp && await root.kind(path) == null) {
        await root.rename(backup, path);
      }
      rethrow;
    } finally {
      try {
        await root.removeFile(staged);
      } catch (_) {
        // Cleanup failure leaves the staged copy available for inspection.
      }
    }
    return backedUp ? backup : null;
  }
}

class _CharacterChange {
  const _CharacterChange(
    this.path,
    this.token,
    this.existed, {
    this.deleting = false,
  });
  final String path;
  final int token;
  final bool existed;
  final bool deleting;

  String get stage => _temporary('edit');
  String get backup => _temporary(deleting ? 'removed' : 'original');
  String _temporary(String type) {
    final separator = path.lastIndexOf('/');
    return '${path.substring(0, separator)}/.arcaea-manager-$type-$token-${path.substring(separator + 1)}';
  }
}
