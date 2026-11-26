import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../services/arc_storage.dart';
import '../services/character_library.dart';
import '../services/gettext_catalog.dart';
import '../services/transfer_bundle.dart';
import 'arc_image.dart';
import 'catalog_action.dart';

class CharacterManagementPage extends StatefulWidget {
  const CharacterManagementPage({super.key});

  @override
  State<CharacterManagementPage> createState() =>
      _CharacterManagementPageState();
}

typedef _LibraryData = ({
  CharacterLibrary library,
  List<CharacterAsset> assets,
  Map<String, String> names,
  bool hasNameError,
});

class _CharacterManagementPageState extends State<CharacterManagementPage> {
  ArcStorage? _songRoot;
  Future<_LibraryData>? _data;
  String _query = '';
  bool _selecting = false, _busy = false;
  final _selected = <int>{};

  Future<void> _exportSelected(_LibraryData data) async {
    final ids = _selected.toSet();
    final root = _songRoot;
    setState(() => _busy = true);
    try {
      await catalogAction(context, () async {
        final location = await ArcStorage.pickExportDirectory('选择人物分享包保存位置');
        if (!mounted || location == null || !identical(root, _songRoot)) return;
        final path = await data.library.exportCharacters(ids, location);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已导出 ${ids.length} 位人物到 $path')),
          );
        }
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteSelected(_LibraryData data) async {
    final ids = _selected.toSet();
    final root = _songRoot;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除 ${ids.length} 位人物？'),
        content: const Text('同编号变体的立绘和语音会移出启用资源并保留文件备份，人物档案会移除。共享译文会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true || !identical(root, _songRoot)) return;
    setState(() => _busy = true);
    try {
      final done = await catalogAction(
        context,
        () => data.library.removeCharacters(ids),
        success: '已删除 ${ids.length} 位人物',
      );
      if (done && mounted && identical(root, _songRoot)) {
        _selected.removeAll(ids);
        _refresh(data.library.root);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<_LibraryData> _load(ArcStorage root) async {
    final library = await CharacterLibrary.open(root);
    final assets = await library.list();
    GettextCatalog? names;
    var hasNameError = false;
    try {
      names = await library.loadTranslations('zh-Hans');
    } on FormatException {
      hasNameError = true;
    }
    return (
      library: library,
      assets: assets,
      hasNameError: hasNameError,
      names:
          names?.messages.map(
            (key, value) => MapEntry(key.toLowerCase(), value),
          ) ??
          {},
    );
  }

  void _refresh(ArcStorage root) {
    if (!mounted) return;
    setState(() {
      _data = _load(root);
    });
  }

  String _name(CharacterAsset asset, _LibraryData data) {
    final profile = data.library.profile(asset.id);
    final alias = profile['alias'] as String?;
    if (alias != null && alias.isNotEmpty) return alias;
    final key =
        profile['translationKey'] as String? ??
        data.library.referenceName(asset.number);
    return key == null
        ? '人物 ${asset.id}'
        : data.names[key.toLowerCase()] ?? key;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final songRoot = state.hasPath ? state.fileService.storage : null;
    if (!identical(songRoot, _songRoot)) {
      _songRoot = songRoot;
      _selected.clear();
      _selecting = false;
      final root = state.fileService.arcExtRoot();
      _data = root == null ? null : _load(root);
    }

    return FutureBuilder<_LibraryData>(
      key: ObjectKey(songRoot),
      future: _data,
      builder: (context, snapshot) {
        final data = snapshot.data;
        return Scaffold(
          appBar: AppBar(
            title: Text(_selecting ? '已选 ${_selected.length} 位人物' : '人物管理'),
            actions: [
              if (data != null) ...[
                IconButton(
                  tooltip: _selecting ? '退出选择' : '批量选择人物',
                  icon: Icon(_selecting ? Icons.close : Icons.checklist),
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _selecting = !_selecting;
                          _selected.clear();
                        }),
                ),
                if (_selecting) ...[
                  IconButton(
                    tooltip: '全选人物',
                    icon: const Icon(Icons.select_all),
                    onPressed: _busy || data.assets.isEmpty
                        ? null
                        : () => setState(() {
                            final ids = data.assets
                                .map((asset) => asset.number)
                                .toSet();
                            if (ids.every(_selected.contains)) {
                              _selected.removeAll(ids);
                            } else {
                              _selected.addAll(ids);
                            }
                          }),
                  ),
                  IconButton(
                    tooltip: '导出选中人物包',
                    icon: const Icon(Icons.file_upload_outlined),
                    onPressed: _busy || _selected.isEmpty
                        ? null
                        : () => _exportSelected(data),
                  ),
                  IconButton(
                    tooltip: '删除选中人物',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: _busy || _selected.isEmpty
                        ? null
                        : () => _deleteSelected(data),
                  ),
                ] else ...[
                  IconButton(
                    icon: const Icon(Icons.drive_folder_upload_outlined),
                    tooltip: '导入人物包',
                    onPressed: _busy ? null : () => _importBundle(data),
                  ),
                  IconButton(
                    icon: const Icon(Icons.upload_file),
                    tooltip: '导入人物资料（characters.json）',
                    onPressed: _busy
                        ? null
                        : () => _importReference(data.library),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: '刷新人物资源',
                    onPressed: () => catalogAction(context, () async {
                      await data.library.root.invalidateArtwork();
                      _refresh(data.library.root);
                    }),
                  ),
                ],
              ],
            ],
          ),
          body: switch (snapshot.connectionState) {
            ConnectionState.none => const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('请在设置中选择完整的 Arc4 或 ArcExt 目录，以读取人物和译文。'),
              ),
            ),
            ConnectionState.waiting || ConnectionState.active =>
              data == null
                  ? const Center(child: CircularProgressIndicator())
                  : _list(data),
            ConnectionState.done =>
              data == null
                  ? Center(child: Text('${snapshot.error}'))
                  : _list(data),
          },
        );
      },
    );
  }

  Widget _list(_LibraryData data) {
    final needle = _query.trim().toLowerCase();
    final shown = data.assets
        .where(
          (asset) =>
              asset.id.contains(needle) ||
              _name(asset, data).toLowerCase().contains(needle),
        )
        .toList();
    return Column(
      children: [
        if (data.hasNameError)
          const ListTile(
            leading: Icon(Icons.warning_amber),
            title: Text('简体中文译文无法读取。可以在编辑游戏译文中恢复备份。'),
          ),

        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: '搜索人物名称或编号',
            ),
            onChanged: (value) => setState(() => _query = value),
          ),
        ),
        Expanded(
          child: shown.isEmpty
              ? const Center(child: Text('找不到人物立绘'))
              : ListView.builder(
                  itemCount: shown.length,
                  itemBuilder: (context, index) {
                    final asset = shown[index];
                    final name = _name(asset, data);
                    return ListTile(
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox.square(
                          dimension: 48,
                          child: ArcImage(
                            storage: data.library.root,
                            candidates: asset.previewPaths,
                            cacheWidth: 112,
                            fallback: const Icon(Icons.person),
                          ),
                        ),
                      ),
                      title: Text(name),
                      subtitle: Text(
                        'ID ${asset.id} · ${asset.paths.length} 个资源',
                      ),
                      selected: _selecting && _selected.contains(asset.number),
                      trailing: _selecting
                          ? Icon(
                              _selected.contains(asset.number)
                                  ? Icons.check_box
                                  : Icons.check_box_outline_blank,
                            )
                          : const Icon(Icons.chevron_right),
                      onTap: () async {
                        if (_busy) return;
                        if (_selecting) {
                          setState(() {
                            if (!_selected.add(asset.number)) {
                              _selected.remove(asset.number);
                            }
                          });
                          return;
                        }
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => _CharacterDetail(
                              library: data.library,
                              asset: asset,
                              title: name,
                            ),
                          ),
                        );
                        _refresh(data.library.root);
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _importReference(CharacterLibrary library) async {
    await catalogAction(context, () async {
      final bytes = await _pick('json');
      if (bytes == null) return;
      final count = await library.importReference(bytes);
      if (!mounted) return;
      _refresh(library.root);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已导入 $count 条人物资料')));
    });
  }

  Future<void> _importBundle(_LibraryData data) async {
    final root = _songRoot;
    setState(() => _busy = true);
    try {
      await catalogAction(context, () async {
        final location = await ArcStorage.pick('选择导出的人物包文件夹', persist: false);
        if (location == null || !mounted || !identical(root, _songRoot)) return;
        final bundle = ArcStorage(location);
        final manifest = await TransferBundle.read(
          bundle,
          'character',
          alternateType: 'characters',
        );
        final single = manifest['type'] == 'character';
        final ids = single
            ? [manifest['id'] as int]
            : (manifest['ids'] as List).cast<int>();
        if (ids.isEmpty || ids.toSet().length != ids.length) {
          throw const FormatException('人物包的 ID 清单无效');
        }
        final existing = (await data.library.list())
            .map((asset) => asset.number)
            .toSet();
        final conflicts = ids.where(existing.contains).toList();
        if (!mounted) return;
        if (conflicts.isNotEmpty) {
          final apply = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text('更新 ${conflicts.length} 位已有的人物？'),
              content: const Text('将应用包内的立绘、语音和档案。现有立绘和译文会保留备份。'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('导入'),
                ),
              ],
            ),
          );
          if (apply != true || !mounted) return;
        }
        if (!identical(root, _songRoot)) return;
        final imported = await data.library.importCharacters({
          for (final id in ids) id: single ? bundle : bundle.child('$id'),
        }, replaceExisting: conflicts.toSet());
        if (!mounted) return;
        _refresh(data.library.root);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已导入 $imported 位人物')));
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

Future<Uint8List?> _pick(String suffix) async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: [suffix],
  );
  if (result == null) return null;
  final file = result.files.single;
  final limit = suffix == 'png' ? 32 : 2;
  if (file.size > limit * 1024 * 1024 || file.path == null) {
    throw FormatException('文件无法读取或超过 $limit MB');
  }
  return File(file.path!).readAsBytes();
}

Future<void> _restoreBackup(
  BuildContext context,
  CharacterLibrary library,
  String path,
) async {
  final versions = await library.backups(path);
  if (!context.mounted) return;
  if (versions.isEmpty) throw StateError('此文件没有备份');
  final selection = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('选择要恢复的备份'),
      children: [
        for (final backup in versions)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, backup),
            child: Text(_backupTime(backup)),
          ),
      ],
    ),
  );
  if (selection != null) await library.restore(path, backup: selection);
}

String _backupTime(String path) {
  final match = RegExp(r'original-(\d+)-').firstMatch(path);
  if (match == null) return path;
  return DateTime.fromMicrosecondsSinceEpoch(
    int.parse(match.group(1)!),
  ).toLocal().toString().split('.').first;
}

class _CharacterDetail extends StatefulWidget {
  final CharacterLibrary library;
  final CharacterAsset asset;
  final String title;

  const _CharacterDetail({
    required this.library,
    required this.asset,
    required this.title,
  });

  @override
  State<_CharacterDetail> createState() => _CharacterDetailState();
}

class _CharacterDetailState extends State<_CharacterDetail> {
  late final TextEditingController _alias;
  late String? _skill;
  late bool? _offline;
  late String? _translationKey;
  late Future<Set<String>> _recoverable;
  bool _busy = false;

  CharacterLibrary get _library => widget.library;
  CharacterAsset get _asset => widget.asset;

  @override
  void initState() {
    super.initState();
    final profile = _library.profile(_asset.id);
    _alias = TextEditingController(text: profile['alias'] as String?);
    _skill =
        (profile['skill'] as String?) ?? _library.defaultSkill(_asset.number);
    _offline = profile['offline'] as bool?;
    _translationKey =
        (profile['translationKey'] as String?) ??
        _library.referenceName(_asset.number);
    _recoverable = _hasBackups();
  }

  Future<Set<String>> _hasBackups() async {
    final paths = <String>{};
    for (final path in _asset.paths) {
      if ((await _library.backups(path)).isNotEmpty) paths.add(path);
    }
    return paths;
  }

  @override
  void dispose() {
    _alias.dispose();
    super.dispose();
  }

  Future<void> _apply(
    Future<void> Function() action, {
    String? success,
    bool artwork = false,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    final saved = await catalogAction(context, action, success: success);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (saved && artwork) {
        _recoverable = _hasBackups();
      }
    });
  }

  Future<void> _saveProfile() => _apply(
    () => _library.updateProfile(_asset.id, {
      'alias': _alias.text.trim(),
      'skill': _skill,
      'offline': _offline,
      'translationKey': _translationKey,
    }),
    success: '人物档案已保存',
  );

  Future<void> _export() => _apply(() async {
    final location = await ArcStorage.pickExportDirectory('选择人物包的保存位置');
    if (location == null || !mounted) return;
    final path = await _library.exportCharacter(_asset, location);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('人物包已保存到 $path')));
    }
  });

  @override
  Widget build(BuildContext context) {
    final skills = {'', ..._library.skills, ?_skill};
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.ios_share),
            tooltip: '导出人物包',
            onPressed: _busy ? null : _export,
          ),
          IconButton(
            icon: const Icon(Icons.save_outlined),
            tooltip: '保存人物档案',
            onPressed: _busy ? null : _saveProfile,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '人物 ID ${_asset.id}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _alias,
            enabled: !_busy,
            decoration: const InputDecoration(labelText: '管理器内的显示名称'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _skill,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: '档案技能偏好',
              helperText: '可导入人物资料以扩充技能选项',
            ),
            items: [
              for (final skill in skills)
                DropdownMenuItem(
                  value: skill,
                  child: Text(
                    skill.isEmpty ? '无技能' : skill,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: _busy ? null : (value) => setState(() => _skill = value),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _offline?.toString() ?? 'default',
            decoration: const InputDecoration(labelText: '档案离线偏好'),
            items: const [
              DropdownMenuItem(value: 'default', child: Text('未指定')),
              DropdownMenuItem(value: 'true', child: Text('设为可用')),
              DropdownMenuItem(value: 'false', child: Text('设为不可用')),
            ],
            onChanged: _busy
                ? null
                : (value) => setState(
                    () =>
                        _offline = value == 'default' ? null : value == 'true',
                  ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('技能和离线偏好只保存在管理器档案中，游戏使用自身的人物配置。'),
          ),
          OutlinedButton.icon(
            onPressed: _busy
                ? null
                : () async {
                    final key = await Navigator.of(context).push<String>(
                      MaterialPageRoute(
                        builder: (_) => _TranslationPage(
                          library: _library,
                          initialKey: _translationKey,
                        ),
                      ),
                    );
                    if (mounted && key != null) {
                      setState(() => _translationKey = key);
                      await _apply(
                        () => _library.updateProfile(_asset.id, {
                          ..._library.profile(_asset.id),
                          'translationKey': key,
                        }),
                      );
                    }
                  },
            icon: const Icon(Icons.translate),
            label: const Text('编辑游戏译文'),
          ),
          const Divider(height: 30),
          Text('图片资源', style: Theme.of(context).textTheme.titleMedium),
          FutureBuilder<Set<String>>(
            future: _recoverable,
            builder: (context, snapshot) => Column(
              children: [
                for (final path in _asset.paths)
                  Card(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(10),
                          child: SelectableText(path),
                        ),
                        SizedBox(
                          height: 200,
                          child: ArcImage(
                            storage: _library.root,
                            candidates: [path],
                            fit: BoxFit.contain,
                            cacheWidth: 640,
                            fallback: const Center(
                              child: Icon(Icons.image_not_supported),
                            ),
                          ),
                        ),
                        Wrap(
                          alignment: WrapAlignment.center,
                          children: [
                            TextButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => _apply(() async {
                                      final data = await _pick('png');
                                      if (data != null) {
                                        await _library.replacePortrait(
                                          path,
                                          data,
                                        );
                                      }
                                    }, artwork: true),
                              icon: const Icon(Icons.image_outlined),
                              label: const Text('替换 PNG'),
                            ),
                            if (snapshot.data?.contains(path) ?? false)
                              TextButton.icon(
                                onPressed: _busy
                                    ? null
                                    : () => _apply(
                                        () => _restoreBackup(
                                          context,
                                          _library,
                                          path,
                                        ),
                                        artwork: true,
                                      ),
                                icon: const Icon(Icons.restore),
                                label: const Text('恢复备份'),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TranslationPage extends StatefulWidget {
  final CharacterLibrary library;
  final String? initialKey;

  const _TranslationPage({required this.library, this.initialKey});

  @override
  State<_TranslationPage> createState() => _TranslationPageState();
}

class _TranslationPageState extends State<_TranslationPage> {
  late Future<GettextCatalog?> _catalog;
  late final TextEditingController _key;
  final TextEditingController _value = TextEditingController();
  String _language = 'zh-Hans';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _key = TextEditingController(text: widget.initialKey);
    _catalog = widget.library.loadTranslations(_language);
  }

  @override
  void dispose() {
    _key.dispose();
    _value.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('游戏译文')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DropdownButtonFormField<String>(
            initialValue: _language,
            decoration: const InputDecoration(labelText: '游戏语言'),
            items: [
              for (final language in CharacterLibrary.languages)
                DropdownMenuItem(value: language, child: Text(language)),
            ],
            onChanged: _busy
                ? null
                : (language) {
                    if (language != null) {
                      setState(() {
                        _language = language;
                        _value.clear();
                        _catalog = widget.library.loadTranslations(language);
                      });
                    }
                  },
          ),
          const SizedBox(height: 12),
          Text('tl/$_language.mo'),
          const Text('修改会写入该语言文件，并影响游戏里使用同一原文的文本。'),
          FutureBuilder<GettextCatalog?>(
            future: _catalog,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              final messages = snapshot.data?.messages;
              if (messages == null) {
                return Text('${snapshot.error ?? '未找到译文文件'}');
              }
              return _edit(messages);
            },
          ),
          OutlinedButton(
            onPressed: _busy
                ? null
                : () async {
                    setState(() => _busy = true);
                    final restored = await catalogAction(
                      context,
                      () => _restoreBackup(
                        context,
                        widget.library,
                        'tl/$_language.mo',
                      ),
                    );
                    if (!mounted) return;
                    setState(() {
                      _busy = false;
                      if (restored) {
                        _catalog = widget.library.loadTranslations(_language);
                      }
                    });
                  },
            child: const Text('恢复此语言的备份'),
          ),
        ],
      ),
    );
  }

  Widget _edit(Map<String, String> messages) {
    final key = _key.text.trim();
    final translated = messages[key];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          enabled: !_busy,
          controller: _key,
          onChanged: (_) => setState(_value.clear),
          decoration: const InputDecoration(labelText: '搜索名称原文或译文'),
        ),
        if (key.isNotEmpty && translated == null)
          ...messages.entries
              .where(
                (entry) =>
                    entry.key.isNotEmpty &&
                    !entry.key.contains(RegExp(r'[\n\x00\x04]')) &&
                    (entry.key.toLowerCase().contains(key.toLowerCase()) ||
                        entry.value.contains(key)),
              )
              .take(8)
              .map(
                (entry) => ListTile(
                  dense: true,
                  title: Text(entry.key),
                  subtitle: Text(
                    entry.value,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: _busy
                      ? null
                      : () => setState(() {
                          _key.text = entry.key;
                          _value.clear();
                        }),
                ),
              ),
        if (translated != null && key.isNotEmpty) ...[
          const SizedBox(height: 12),
          SelectableText('当前译文  $translated'),
          TextField(
            enabled: !_busy,
            controller: _value,
            decoration: const InputDecoration(labelText: '新译文'),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy
                ? null
                : () async {
                    setState(() => _busy = true);
                    final saved = await catalogAction(
                      context,
                      () => widget.library.updateTranslation(
                        _language,
                        key,
                        _value.text,
                      ),
                    );
                    if (!mounted) return;
                    if (saved) {
                      Navigator.pop(context, key);
                    } else {
                      setState(() => _busy = false);
                    }
                  },
            child: const Text('保存游戏译文'),
          ),
        ],
      ],
    );
  }
}
