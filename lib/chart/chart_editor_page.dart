import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/arc_storage.dart';
import 'aff_chart.dart';
import 'chart_appearance.dart';
import 'chart_arc_editor.dart';
import 'chart_backup_dialog.dart';
import 'chart_beat_grid.dart';
import 'chart_compatibility.dart';
import 'chart_editor_visibility.dart';
import 'chart_effect_panel.dart';
import 'chart_files.dart';
import 'chart_keyframes.dart';
import 'chart_perspective.dart';
import 'chart_preview_page.dart';
import 'chart_skin.dart';
import 'chart_timeline.dart';
import 'chart_timing_panel.dart';

enum _Tool {
  select('选择'),
  tap('地键'),
  hold('长按'),
  arc('蛇'),
  trace('弧线'),
  arctap('空键'),
  wideArctap('变宽空键'),
  flick('滑键'),
  timing('BPM');

  const _Tool(this.label);
  final String label;
}

enum _KeyframeDisplay { arcs, taps, both }

typedef _ProjectedKeyframe = ({ChartKeyframe key, Offset point, double depth});

class ChartEditorPage extends StatefulWidget {
  const ChartEditorPage({
    super.key,
    this.files,
    this.title = '谱面编辑器',
    this.onSetBpmBase,
    this.targetVersion,
  });

  final ChartFiles? files;
  final String title;
  final Future<void> Function(double)? onSetBpmBase;
  final ChartGameVersion? targetVersion;

  @override
  State<ChartEditorPage> createState() => _ChartEditorPageState();
}

enum _EditorTouchGesture { pan, zoom }

class _ChartEditorPageState extends State<ChartEditorPage> {
  static const _laneModeKey = 'chart_lane_mode';
  static const _maxBytes = 8 * 1024 * 1024;
  static const _minZoom = 0.25, _maxZoom = 8.0;
  static const _endpointSnapRadius = 12.0;
  final _source = TextEditingController(text: AffChart.blank);
  final _position = ValueNotifier(0.0);
  final _skin = ValueNotifier(ChartSkin.defaults);
  final _undo = <String>[];
  final _redo = <String>[];
  late var _chart = AffChart.parse(_source.text);
  late double? _bpmBase = widget.files?.bpmBase;
  late var _timeline = ChartTimeline(_chart, bpmBase: _baseFor(_chart));
  Uint8List? _original;
  Timer? _parseTimer;
  String? _manualAudio, _loadError;
  var _saved = AffChart.blank;
  var _fileName = 'chart.aff';
  var _backupSource = 'untitled';
  var _zoom = 1.0;
  var _subdivision = 16;
  double _gestureScroll = 0;
  double _wheelScroll = 0, _wheelStep = 100;
  var _activeGroup = 0;
  var _tool = _Tool.select;
  AffEvent? _selected;
  int? _selectedArcTap;
  ChartLaneMode _laneMode = ChartLaneMode.automatic;
  ChartAppearance _appearance = defaultChartAppearance;
  bool _laneModeTouched = false;
  final _selection = <AffEvent>{};
  final _points = <ArcPoint>[];
  List<AffEvent> _editingArc = const [];
  ArcDraft? _workingArc;
  int? _movingArcPoint;
  final _pointers = <int, Offset>{};
  (Offset, Offset)? _pairOrigin;
  _EditorTouchGesture? _pairGesture;
  double _pairZoom = 1, _pairPan = 0;
  Timer? _pairIdle;
  _EditorTouchGesture? _trackpadGesture;
  double _trackpadZoom = 1;
  List<AffEvent> _clipboard = const [];
  bool _edit3d = false, _selectMultiple = false, _hadTwoFingers = false;
  bool _onlySelected = false, _heightOnly = false, _didDrag = false;
  bool _allowOverflow = false;
  bool _showKeyframes = true, _snapEndpoints = true;
  final _displayItems = {...ChartDisplayItem.values};
  _KeyframeDisplay _keyframeDisplay = _KeyframeDisplay.both;
  final _stroke = <Offset>[];
  int? _dragPointer;
  Offset? _dragOrigin;
  _ProjectedKeyframe? _dragKey;
  List<ChartKeyframe> _dragLinked = const [];
  List<ChartKeyframe> _selectedJoint = const [];
  ChartKeyframe? _detachedEndpoint;
  bool _dragDetached = false;
  ArcPoint? _dragPosition;
  Offset? _snapPoint;
  final _editFocus = FocusNode();
  bool _busy = true, _showSource = false, _snap = true;
  int _skinRequest = 0;

  bool get _dirty => _source.text != _saved;
  ChartGameVersion? get _gameVersion {
    final files = widget.files;
    return files == null
        ? widget.targetVersion
        : files.isArc4
        ? ChartGameVersion.arc4
        : ChartGameVersion.arcExt;
  }

  ChartEditorVisibility get _visibility => ChartEditorVisibility(
    items: Set.unmodifiable(_displayItems),
    onlySelected: _onlySelected,
    selection: Set.unmodifiable(_selection),
    attachedTap: switch ((_selected, _selectedArcTap)) {
      (final note?, final tap?) => (note: note, tap: tap),
      _ => null,
    },
  );
  double get _lookahead => 2100 / _zoom;
  double get _min => math.min(-1000, _chart.firstTime).toDouble();
  double get _max => math.max(1000, _chart.lastTime + 30000).toDouble();

  double _baseFor(AffChart chart) {
    final configured = _bpmBase;
    if (configured != null && configured > 0 && configured.isFinite) {
      return configured;
    }
    final events =
        chart.events
            .where((event) => event.kind == AffKind.timing && event.group == 0)
            .toList()
          ..sort((a, b) => a.start.compareTo(b.start));
    final durations = <double, int>{};
    for (var i = 0; i < events.length; i++) {
      final bpm = events[i].number(1);
      if (bpm < 1) continue;
      final end = i + 1 < events.length ? events[i + 1].start : chart.lastTime;
      durations.update(
        bpm,
        (value) => value + end - events[i].start,
        ifAbsent: () => end - events[i].start,
      );
    }
    return durations.entries
            .fold<MapEntry<double, int>?>(
              null,
              (best, entry) =>
                  best == null || entry.value > best.value ? entry : best,
            )
            ?.key ??
        120;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_restoreLaneMode());
    if (Platform.isWindows) unawaited(_loadWheelStep());
    _load();
    if (widget.files case final files?) unawaited(_loadSkin(files.skin()));
  }

  Future<void> _loadWheelStep() async {
    try {
      const input = MethodChannel('arcaea_manager/chart_input');
      final step = await input.invokeMethod<double>('wheelStep');
      if (mounted && step != null && step.isFinite && step != 0) {
        _wheelStep = step;
      }
    } on PlatformException {
      // Fall back to the default Windows wheel increment.
    } on MissingPluginException {
      // The editor can also run outside the desktop runner.
    }
  }

  Future<void> _restoreLaneMode() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      if (mounted) {
        setState(() => _appearance = savedChartAppearance(preferences));
      }
      final saved = preferences.getString(_laneModeKey);
      if (!mounted || _laneModeTouched || saved == null) return;
      final mode = ChartLaneMode.values
          .where((mode) => mode.name == saved)
          .firstOrNull;
      if (mode != null) setState(() => _laneMode = mode);
    } on PlatformException {
      // The current editor and its preview can use an in-memory setting.
    } on MissingPluginException {
      // Preferences are optional when embedding the editor.
    }
  }

  Future<void> _loadSkin(Future<ChartSkin> pending) async {
    final request = ++_skinRequest;
    final skin = await pending;
    if (!mounted || request != _skinRequest) {
      skin.dispose();
      return;
    }
    final previous = _skin.value;
    if (previous == skin) return;
    setState(() => _skin.value = skin);
    WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
  }

  Future<void> _load() async {
    try {
      if (widget.files case final files?) {
        final original = await files.open();
        final text = _decode(original);
        if (!mounted) return;
        _original = original;
        _fileName = files.name;
        _setDocument(text);
        if (original.isEmpty) _setText(AffChart.blank);
      }
    } catch (error) {
      _loadError = error.toString();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _decode(Uint8List bytes) {
    if (bytes.length > _maxBytes) throw const FormatException('AFF 文件超过 8 MB');
    return ChartFiles.decode(bytes);
  }

  void _setDocument(String text) {
    _saved = text;
    _undo.clear();
    _redo.clear();
    _selection.clear();
    _selected = null;
    _selectedArcTap = null;
    _selectedJoint = const [];
    _detachedEndpoint = null;
    _position.value = 0;
    _setText(text);
  }

  void _setText(String text, {int? cursor, bool keepEventOrder = false}) {
    _source.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: cursor ?? text.length),
    );
    if (text == _chart.source) setState(() {});
    _parse(keepEventOrder: keepEventOrder);
  }

  void _parse({bool keepEventOrder = false}) {
    _parseTimer?.cancel();
    if (_source.text == _chart.source) return;
    setState(() {
      final previous = _chart;
      if (_source.text.length > _maxBytes) {
        _chart = AffChart.parse('');
      } else {
        _chart = AffChart.parse(_source.text);
      }
      _timeline = ChartTimeline(_chart, bpmBase: _baseFor(_chart));
      if (!_chart.groups.any((group) => group.id == _activeGroup)) {
        _activeGroup = 0;
      }
      _restoreSelection(previous, keepEventOrder: keepEventOrder);
      _selectedJoint = const [];
      _detachedEndpoint = null;
      _clearPoints();
      _clearDrag();
      _position.value = _position.value.clamp(_min, _max);
    });
  }

  void _restoreSelection(AffChart previous, {required bool keepEventOrder}) {
    if (_selection.isEmpty) return;
    final before = previous.source, after = _chart.source;
    final sameOrder =
        keepEventOrder && previous.events.length == _chart.events.length;
    var prefix = 0, suffix = 0;
    final minLength = math.min(before.length, after.length);
    while (!sameOrder &&
        prefix < minLength &&
        before.codeUnitAt(prefix) == after.codeUnitAt(prefix)) {
      prefix++;
    }
    while (!sameOrder &&
        prefix + suffix < minLength &&
        before.codeUnitAt(before.length - suffix - 1) ==
            after.codeUnitAt(after.length - suffix - 1)) {
      suffix++;
    }
    final oldEnd = before.length - suffix, newEnd = after.length - suffix;
    final atOffset = sameOrder
        ? {
            for (var i = 0; i < previous.events.length; i++)
              previous.events[i].sourceStart: _chart.events[i],
          }
        : {for (final event in _chart.events) event.sourceStart: event};
    final kept = <AffEvent>{};
    AffEvent? primary;
    for (final old in _selection) {
      final current = sameOrder || old.sourceEnd <= prefix
          ? atOffset[old.sourceStart]
          : old.sourceStart >= oldEnd
          ? atOffset[old.sourceStart + after.length - before.length]
          : atOffset[old.sourceStart];
      if (current == null ||
          old.kind != current.kind ||
          old.group != current.group) {
        continue;
      }
      if (!sameOrder) {
        final sameStatement =
            before.substring(old.sourceStart, old.sourceEnd) ==
            after.substring(current.sourceStart, current.sourceEnd);
        final singleEdit =
            old.sourceStart <= prefix &&
            old.sourceEnd >= oldEnd &&
            current.sourceEnd >= newEnd;
        if (!sameStatement && !singleEdit) continue;
      }
      if (identical(old, _selected)) {
        final tap = _selectedArcTap;
        if (tap != null && !current.arcTaps.contains(tap)) continue;
        primary = current;
      }
      kept.add(current);
    }
    if (primary == null) _selectedArcTap = null;
    _selection
      ..clear()
      ..addAll(kept);
    _selected = primary ?? _selection.lastOrNull;
  }

  void _record(List<String> history, String text) {
    if (history.isEmpty || history.last != text) history.add(text);
    if (history.length > 30) history.removeAt(0);
  }

  void _edit(String text, {int? cursor, bool keepEventOrder = false}) {
    _record(_undo, _source.text);
    _redo.clear();
    _setText(text, cursor: cursor, keepEventOrder: keepEventOrder);
  }

  void _undoEdit() {
    if (_undo.isEmpty) return;
    _record(_redo, _source.text);
    _setText(_undo.removeLast());
  }

  void _redoEdit() {
    if (_redo.isEmpty) return;
    _record(_undo, _source.text);
    _setText(_redo.removeLast());
  }

  void _changed(String text) {
    final grouped = _parseTimer?.isActive ?? false;
    _parseTimer?.cancel();
    if (!grouped) {
      _record(_undo, _chart.source);
      _redo.clear();
      setState(() {});
    }
    _parseTimer = Timer(const Duration(milliseconds: 250), _parse);
  }

  Future<void> _run(Future<void> Function() task) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await task();
    } catch (error) {
      if (mounted) _message(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _message(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _confirm(String title, String detail, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          scrollable: true,
          title: Text(title),
          content: Text(detail),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _open() => _run(() async {
    if (_dirty && !await _confirm('放弃当前修改？', '当前草稿尚未保存。', '继续打开')) return;
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: '打开 AFF',
      type: Platform.isAndroid ? FileType.any : FileType.custom,
      allowedExtensions: Platform.isAndroid ? null : ['aff'],
    );
    final file = result?.files.single;
    if (file?.path == null || !mounted) return;
    if (!file!.name.toLowerCase().endsWith('.aff')) {
      throw const FormatException('请选择扩展名为 .aff 的文件');
    }
    if (file.size > _maxBytes) throw const FormatException('AFF 文件超过 8 MB');
    final text = _decode(await File(file.path!).readAsBytes());
    if (!mounted) return;
    _fileName = file.name;
    final path = File(file.path!).absolute.path;
    _backupSource =
        file.identifier ??
        'file:${Platform.isWindows ? path.toLowerCase() : path}';
    _manualAudio = null;
    _setDocument(text);
    if (Platform.isWindows) {
      unawaited(
        _loadSkin(
          ChartSkin.load(
            folder: ArcStorage(File(file.path!).parent.path),
            chartKey: file.name.substring(0, file.name.length - 4),
          ),
        ),
      );
    } else {
      unawaited(_loadSkin(Future.value(ChartSkin.defaults)));
    }
  });

  Future<void> _newChart() => _run(() async {
    if (_dirty && !await _confirm('放弃当前修改？', '当前草稿尚未保存。', '新建谱面')) return;
    if (!mounted) return;
    _fileName = 'chart.aff';
    _backupSource = 'untitled';
    _manualAudio = null;
    _setDocument(AffChart.blank);
    unawaited(_loadSkin(Future.value(ChartSkin.defaults)));
  });

  Future<void> _chooseSkin() => _run(() async {
    final location = await ArcStorage.pick('选择预览素材目录', persist: false);
    if (!mounted || location == null) return;
    final directory = ArcStorage(location);
    await _loadSkin(
      ChartSkin.load(
        folder: widget.files?.folder ?? directory,
        root: directory,
        chartKey: _fileName.substring(0, _fileName.length - 4),
        side: widget.files?.song?.side ?? 0,
        backgrounds: widget.files?.backgrounds ?? const [],
      ),
    );
  });

  Future<void> _chooseAudio() => _run(() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.audio);
    final path = result?.files.single.path;
    if (path == null || !mounted) return;
    _manualAudio = path;
    _message('已选择 ${result!.files.single.name}');
  });

  Future<void> _editOffset() async {
    _parse();
    if (_chart.errors.isNotEmpty) {
      _message(_chart.errors.first);
      return;
    }
    final result = await showDialog<double>(
      context: context,
      builder: (_) => _EventDialog(
        '${_chart.audioOffset}',
        numberLabel: '音频偏移（毫秒）',
        integerOnly: true,
      ),
    );
    if (mounted && result != null && result != _chart.audioOffset) {
      _edit(_chart.changeAudioOffset(result.toInt()));
    }
  }

  Future<void> _editTiming() async {
    _parse();
    if (_chart.errors.isNotEmpty) {
      _message(_chart.errors.first);
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => ChartTimingPanel(
        chart: _chart,
        initialTime: _position.value.round(),
        bpmBase: _baseFor(_chart),
        canSaveBpmBase: widget.onSetBpmBase != null,
        onChart: _edit,
        onBpmBase: (value) async {
          await widget.onSetBpmBase?.call(value);
          if (!mounted) return;
          setState(() {
            _bpmBase = value;
            _timeline = ChartTimeline(_chart, bpmBase: value);
          });
        },
      ),
    );
  }

  Future<void> _save() {
    _parse();
    return _run(() async {
      final files = widget.files;
      if (files == null || _original == null) return;
      if (_chart.errors.isNotEmpty) throw FormatException(_chart.errors.first);
      final report = ChartCompatibility(_chart, _gameVersion!);
      if (!report.isCompatible &&
          !await _confirm(
            '${report.version.label} 有兼容风险',
            '${report.issues.take(4).map((issue) => issue.description).join('\n')}\n'
                '可在「谱面菜单 → AFF 兼容检查」查看完整列表和修复方案。',
            '仍然保存',
          )) {
        return;
      }
      if (!mounted) return;
      _original = await files.save(_original!, _source.text);
      if (!mounted) return;
      _saved = _source.text;
      _message('已写入 ${files.name}，并保留上一版本');
    });
  }

  Future<void> _export() => _run(() async {
    final bytes = Uint8List.fromList(utf8.encode(_source.text));
    final basename = _fileName.replaceFirst(
      RegExp(r'\.aff$', caseSensitive: false),
      '',
    );
    final path = await FilePicker.platform.saveFile(
      dialogTitle: '导出 AFF 副本',
      fileName: widget.files == null ? '$basename.aff' : '$basename-edited.aff',
      type: Platform.isAndroid ? FileType.any : FileType.custom,
      allowedExtensions: Platform.isAndroid ? null : ['aff'],
      bytes: bytes,
    );
    if (path == null) return;
    if (!Platform.isAndroid) await File(path).writeAsBytes(bytes, flush: true);
    if (!mounted) return;
    if (widget.files == null) _saved = _source.text;
    _message('AFF 已导出');
  });

  Future<void> _restore() => _run(() async {
    final files = widget.files;
    final history =
        await (files?.backupHistory() ??
            ChartBackupHistory.standalone(_backupSource));
    if (!mounted) return;
    final backup = await showDialog<String>(
      context: context,
      builder: (_) => ChartBackupDialog(
        history: history,
        current: _source.text,
        label: files == null ? _fileName : null,
      ),
    );
    if (mounted && backup != null && backup != _source.text) _edit(backup);
  });

  Future<void> _checkCompatibility() async {
    _parse();
    final active = _gameVersion;
    final reports = {
      for (final version in ChartGameVersion.values)
        version: ChartCompatibility(_chart, version),
    };
    var selected = active ?? ChartGameVersion.arcExt;
    final plan = await showDialog<ChartCompatibility>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) {
          final report = reports[selected]!;
          return AlertDialog(
            title: const Text('AFF 兼容检查'),
            content: SizedBox(
              width: 540,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final entry in reports.entries)
                      Text(
                        '${entry.key.label}${active == entry.key ? '（当前曲库）' : ''}'
                        ' · ${entry.value.isCompatible ? '通过样本规则' : '发现 ${entry.value.issues.length} 类风险'}',
                      ),
                    const SizedBox(height: 12),
                    DropdownButton<ChartGameVersion>(
                      isExpanded: true,
                      value: selected,
                      items: [
                        for (final version in ChartGameVersion.values)
                          DropdownMenuItem(
                            value: version,
                            child: Text('查看或转换至 ${version.label}'),
                          ),
                      ],
                      onChanged: (value) => update(() => selected = value!),
                    ),
                    for (final issue in report.issues)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          '${issue.description}${issue.count > 1 ? '（${issue.count} 处）' : ''}',
                        ),
                        subtitle: Text(
                          [
                            if (issue.firstTime != null)
                              '首次出现于 ${issue.firstTime} ms',
                            issue.repair ?? '请在 AFF 源码中手动修正',
                          ].join('\n'),
                        ),
                      ),
                    const Text('结果基于两套外置壳的 AFF 样本。游戏实际加载仍需验证。'),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: const Text('关闭'),
              ),
              FilledButton(
                onPressed: report.canRepair
                    ? () => Navigator.pop(dialog, report)
                    : null,
                child: const Text('修复…'),
              ),
            ],
          );
        },
      ),
    );
    if (!mounted || plan == null) return;
    final changes = [
      for (final issue in plan.issues)
        if (issue.repair case final repair?)
          '• ${issue.description}${issue.count > 1 ? '（${issue.count} 处）' : ''}\n  $repair',
    ];
    final repaired = plan.applyRepairs();
    if (AffChart.parse(repaired).errors.isNotEmpty) {
      _message('修复后的谱面语法检查未通过，当前草稿已保留。');
      return;
    }
    final accepted = await _confirm(
      '按 ${plan.version.label} 修复？',
      '${changes.join('\n\n')}\n\n修复会载入草稿，可撤销。',
      '应用到草稿',
    );
    if (mounted && accepted && _source.text == plan.chart.source) {
      _edit(repaired);
    }
  }

  Future<void> _preview(bool practice) async {
    _parse();
    if (_chart.errors.isNotEmpty) {
      _message(_chart.errors.first);
      return;
    }
    FocusScope.of(context).unfocus();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChartPreviewPage(
          chart: _chart,
          timeline: _timeline,
          practice: practice,
          initial: _position.value,
          laneMode: _laneMode,
          onLaneModeChanged: (mode) => setState(() => _setLaneMode(mode)),
          onAppearanceChanged: (appearance) {
            if (mounted) setState(() => _appearance = appearance);
          },
          skin: _skin,
          audio: () async {
            if (_manualAudio case final path?) return {'file': path};
            return widget.files?.audioSource();
          },
        ),
      ),
    );
  }

  Future<void> _editAppearance() async {
    final preferences = await SharedPreferences.getInstance();
    if (!mounted) return;
    final appearance = await showChartAppearance(
      context,
      initial: _appearance,
      preferences: preferences,
    );
    if (mounted && appearance != null) setState(() => _appearance = appearance);
  }

  int _snapped(double time, {int? group, bool force = false}) {
    if (!_snap && !force) return time.round();
    return _beatGrid(group ?? _activeGroup).nearest(time);
  }

  ChartBeatGrid _beatGrid(int group) => ChartBeatGrid(
    _timeline.groupTempos(group),
    subdivision: _subdivision,
    bpmBase: _baseFor(_chart),
  );

  void _place(TimelineGeometry geometry, Offset point) {
    _parse();
    if (_chart.errors.isNotEmpty || _busy) return;
    if (_tool == _Tool.select) {
      final hit = geometry.pick(
        _timeline,
        point,
        laneMode: _laneMode,
        visibility: _visibility,
      );
      _select(hit?.note, arcTap: hit?.tap);
      return;
    }
    final air = _airTool;
    if (_tool != _Tool.timing && air != (point.dx >= geometry.centerGap)) {
      return;
    }
    if (!air &&
        !_allowOverflow &&
        _tool != _Tool.timing &&
        (point.dx < geometry.x(geometry.groundStart) ||
            point.dx > geometry.x(geometry.groundEnd))) {
      return;
    }
    final time = _placementTime(geometry.time(point.dy));
    final lane = geometry.lane(point.dx);
    final x = geometry.trackX(
      point.dx,
      airborne: air,
      freeGround: _allowOverflow,
    );
    final target = _arcTool ? _flatSnap(geometry, point)?.position : null;
    _placeAt(time, x, 1, lane, endpoint: target);
  }

  bool get _airTool => const {
    _Tool.arc,
    _Tool.trace,
    _Tool.arctap,
    _Tool.wideArctap,
    _Tool.flick,
  }.contains(_tool);

  bool get _arcTool => _tool == _Tool.arc || _tool == _Tool.trace;

  bool get _arcTapTool => _tool == _Tool.arctap || _tool == _Tool.wideArctap;

  void _setLaneMode(ChartLaneMode mode) {
    _laneModeTouched = true;
    _laneMode = mode;
    unawaited(_saveLaneMode(mode));
    _selection.removeWhere((note) => !mode.shows(note));
    if (!_selection.contains(_selected)) {
      _selected = _selection.lastOrNull;
      _selectedArcTap = null;
    }
    if (_tool == _Tool.hold) _clearPoints();
  }

  Future<void> _saveLaneMode(ChartLaneMode mode) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      if (_laneMode == mode) {
        await preferences.setString(_laneModeKey, mode.name);
      }
    } on PlatformException {
      // Keep the selection for the current editing session.
    } on MissingPluginException {
      // Preferences are optional when embedding the editor.
    }
  }

  bool _isStandaloneSky(AffEvent note) => note.standaloneSky;

  bool _onWall(AffEvent note, int time) => _timeline.onJudgementPlane(
    note,
    _position.value,
    time,
    _lookahead * 2 / 2100,
  );

  void _select(AffEvent? event, {int? arcTap, ChartKeyframe? endpoint}) {
    if (event == null && _onlySelected) return;
    setState(() {
      final multiple =
          arcTap == null &&
          _selectedArcTap == null &&
          (_selectMultiple || HardwareKeyboard.instance.isControlPressed);
      _selectedArcTap = arcTap;
      if (!multiple) _selection.clear();
      if (event != null && !_selection.add(event)) _selection.remove(event);
      _selected = _selection.lastOrNull;
      _selectedJoint = endpoint == null || !_selection.contains(event)
          ? const []
          : chartJoinedEndpoints(_chart, endpoint).toList();
    });
  }

  void _place3d(Size size, Offset point) {
    _parse();
    if (_chart.errors.isNotEmpty || _busy) return;
    final time = _position.value;
    final g = _perspectiveGeometry(size);
    final wide = _laneMode.expansion(_timeline, time, editing: true) > 0;
    if (_tool == _Tool.select) {
      final visibility = _visibility;
      final keyHit = _nearestKey(g, point);
      if (keyHit != null) {
        final key = keyHit.key;
        _select(
          key.note,
          endpoint: key.arcEndpoint ? key : null,
          arcTap: key.kind == ChartKeyframeKind.tap && !key.note.standaloneSky
              ? key.time
              : null,
        );
        return;
      }
      AffEvent? closest;
      int? closestTap;
      var distance = 25.0;
      var tapDistance = 23.0;
      for (final (:note, :start, :end) in _timeline.visibleInPerspective(
        time,
        g.near - time,
        g.far - time,
      )) {
        if (!_laneMode.showsAt(_timeline, note, time)) {
          continue;
        }
        final scroll = _timeline.scroll(note.group);
        final standaloneSky = _isStandaloneSky(note);
        final angles = _timeline.groupOptions[note.group];
        for (final tap in note.arcTaps.where((tap) => _onWall(note, tap))) {
          if (!visibility.shows(note, tap: tap)) continue;
          final air = note.point(tap.toDouble());
          final candidate = g.arcTapDistance(
            point,
            air.x,
            air.height,
            angles: angles,
          );
          if (candidate < tapDistance) {
            closestTap = standaloneSky ? null : tap;
            tapDistance = distance = candidate;
            closest = note;
          }
        }
        if (!visibility.shows(note) ||
            (standaloneSky && !_onWall(note, note.start))) {
          continue;
        }
        final samples = <double>[
          for (var i = 0; i <= 12; i++) start + (end - start) * i / 12,
        ];
        Offset? previous;
        for (var index = 0; index < samples.length; index++) {
          final at = samples[index];
          final depth = time + scroll.at(at) - scroll.at(time);
          final position = note.variableArcTap
              ? note.arcPoint(index == 0 ? 0 : 1)
              : note.isAir
              ? note.point(at)
              : (x: note.laneX, height: 0.0);
          if (note.isAir &&
              g.viewDepth(
                    position.x,
                    position.height,
                    depth,
                    air: true,
                    angles: angles,
                  ) <
                  PerspectiveGeometry.nearCameraDepth) {
            previous = null;
            continue;
          }
          final projected = note.variableArcTap
              ? g.projectArcTap(
                  position.x,
                  position.height,
                  depth,
                  angles: angles,
                )
              : note.isAir
              ? g.projectAir(position.x, position.height, depth, angles: angles)
              : g.project(position.x, 0, depth);
          var candidate = (projected - point).distance;
          if (previous != null &&
              (projected - previous).distanceSquared > 0.001) {
            final delta = projected - previous;
            final from = point - previous;
            final t =
                ((from.dx * delta.dx + from.dy * delta.dy) /
                        delta.distanceSquared)
                    .clamp(0.0, 1.0);
            candidate = (point - previous - delta * t).distance;
          }
          if (closestTap == null && candidate < distance) {
            closest = note;
            distance = candidate;
          }
          previous = projected;
        }
      }
      _select(closest, arcTap: closestTap);
      return;
    }
    final pick = g.pick(
      point,
      air: _airTool,
      arcTap: _arcTapTool,
      allowOverflow: _allowOverflow,
    );
    if (pick == null ||
        (!_airTool && (pick.depth < g.near || pick.depth > g.far))) {
      return;
    }
    if (_airTool) {
      final projected = _arcTapTool
          ? g.projectArcTap(pick.x, pick.height, time)
          : g.projectAir(pick.x, pick.height, time);
      if ((point - projected).distance > 28) return;
    }
    if (!_airTool &&
        !_allowOverflow &&
        (pick.x < (wide ? -0.25 : 0.0) || pick.x > (wide ? 1.25 : 1.0))) {
      return;
    }
    final scroll = _timeline.scroll(_activeGroup);
    final depth = scroll.at(time) + pick.depth - time;
    double? hit = _airTool ? time : null;
    if (!_airTool) {
      for (final range in scroll.visible(
        depth - 0.1,
        depth + 0.1,
        _min,
        _max,
      )) {
        final candidate = time.clamp(range.start, range.end);
        if (hit == null || (candidate - time).abs() < (hit - time).abs()) {
          hit = candidate;
        }
      }
    }
    if (hit == null) return;
    final lane = (pick.x * 4).floor().clamp(wide ? -1 : 0, wide ? 4 : 3) + 1;
    final target = _arcTool
        ? _perspectiveSnap(
            g,
            point,
            valid: (key) =>
                key.note.group == _activeGroup &&
                key.time == time &&
                (_allowOverflow || key.position.height <= g.skyLineHeight) &&
                !_editingArc.contains(key.note),
          )?.key
        : null;
    _placeAt(
      _placementTime(hit),
      pick.x,
      pick.height,
      lane,
      endpoint: target == null
          ? null
          : (
              time: target.time,
              x: target.position.x,
              height: target.position.height,
            ),
    );
  }

  int _placementTime(double time) {
    final moving = _movingArcPoint;
    if (moving != null && (time - _points[moving].time).abs() < 0.5) {
      return _points[moving].time;
    }
    return _snapped(time);
  }

  void _placeAt(
    int at,
    double x,
    double height,
    int lane, {
    ArcPoint? endpoint,
  }) {
    final position =
        endpoint ??
        (
          time: at,
          x: double.parse(x.toStringAsFixed(3)),
          height: double.parse(height.toStringAsFixed(3)),
        );
    final time = position.time;
    if (_arcTool) {
      setState(() {
        final moving = _movingArcPoint;
        if (moving != null) {
          final current = _points[moving];
          if (_points.any((point) => point != current && point.time == time)) {
            return;
          }
          final curve = _workingArc?.segments.remove(current.time);
          if (curve != null) _workingArc!.segments[time] = curve;
          _workingArc?.moveTap(current.time, time);
          _points.removeAt(moving);
          _movingArcPoint = null;
        }
        _points.removeWhere((point) => point.time == time);
        _points.add(position);
        _points.sort((a, b) => a.time.compareTo(b.time));
      });
      return;
    }
    if (_tool == _Tool.hold && _edit3d) {
      if (_points.isEmpty) {
        setState(
          () => _points.add((
            time: time,
            x: _allowOverflow ? position.x : (lane - .5) / 4,
            height: 0,
          )),
        );
      } else {
        final first = _points.first;
        if (time == first.time) return;
        _points.clear();
        final wide = _laneMode.expansion(_timeline, first.time.toDouble()) > 0;
        final firstLane = (first.x * 4 + .5).round().clamp(
          wide ? 0 : 1,
          wide ? 5 : 4,
        );
        _edit(
          _chart.appendToGroup(
            _activeGroup,
            'hold(${math.min(first.time, time)},${math.max(first.time, time)},$firstLane);',
            groundPositions: [_allowOverflow ? first.x : null],
          ),
        );
      }
      return;
    }
    if (_tool == _Tool.flick && _edit3d) {
      if (_points.isEmpty) {
        setState(() => _points.add(position));
      } else {
        final start = _points.first;
        final dx = (position.x - start.x).toStringAsFixed(3);
        final dy = (position.height - start.height).toStringAsFixed(3);
        if (double.parse(dx) == 0 && double.parse(dy) == 0) return;
        _points.clear();
        _edit(
          _chart.appendToGroup(
            _activeGroup,
            'flick(${start.time},${start.x},${start.height},$dx,$dy);',
          ),
        );
      }
      return;
    }
    final right = (x + 0.25).clamp(-0.5, 1.5);
    final statement = switch (_tool) {
      _Tool.tap => '($time,$lane);',
      _Tool.hold => 'hold($time,${time + 500},$lane);',
      _Tool.arctap =>
        'arc($time,$time,${position.x},${position.x},s,${position.height},${position.height},0,none,true)[arctap($time)];',
      _Tool.wideArctap =>
        'arc($time,$time,${position.x},$right,s,${position.height},${position.height},3,none,false);',
      _Tool.flick => 'flick($time,${position.x},${position.height},1.00,0.00);',
      _Tool.timing => 'timing($time,${_baseFor(_chart)},4.00);',
      _Tool.select ||
      _Tool.arc ||
      _Tool.trace => throw StateError('当前工具需要单独处理'),
    };
    if (_edit3d && (_tool == _Tool.arctap || _tool == _Tool.wideArctap)) {
      _position.value = time.toDouble().clamp(_min, _max);
    }
    if (_tool == _Tool.tap || _tool == _Tool.arctap) {
      _edit(
        _chart.appendToGroup(
          _activeGroup,
          statement,
          groundPositions: [
            _allowOverflow && _tool == _Tool.tap ? position.x : null,
          ],
        ),
      );
    } else {
      _editEvent(
        statement: statement,
        groundPosition: _allowOverflow && _tool == _Tool.hold
            ? position.x
            : null,
      );
    }
  }

  Future<void> _arcPanel({AffEvent? event}) async {
    if (_edit3d &&
        event != null &&
        _isStandaloneSky(event) &&
        !_onWall(event, event.start)) {
      return;
    }
    if (_edit3d &&
        event != null &&
        ArcDraft.connected(_chart, event).any(
          (segment) => segment.arcTaps.any((tap) => !_onWall(segment, tap)),
        )) {
      _message('请在判定面上单独编辑空键，或切换到 2D 修改弧线关键点');
      return;
    }
    final related = event == null
        ? _editingArc
        : ArcDraft.connected(_chart, event);
    if (event != null && related.isEmpty) {
      await _editEvent(event: event);
      return;
    }
    final draft = event == null
        ? ArcDraft(
            points: _points.toList(),
            trace: _workingArc?.trace ?? (_tool == _Tool.trace),
            color: _workingArc?.color ?? 0,
            sound: _workingArc?.sound ?? 'none',
            segments: {...?_workingArc?.segments},
            taps: {...?_workingArc?.taps},
            originalTaps: {
              for (final entry
                  in _workingArc?.originalTaps.entries ??
                      const <MapEntry<int, List<int>>>[])
                entry.key: entry.value.toList(),
            },
          )
        : ArcDraft.fromEvents(related);
    final result = await showDialog<List<String>>(
      context: context,
      builder: (_) => ArcEditorPanel(draft: draft, editTaps: !_edit3d),
    );
    if (!mounted || result == null) return;
    if (related.isNotEmpty) {
      final previous = ArcDraft.fromEvents(related).encode();
      if (result.length == previous.length &&
          Iterable<int>.generate(
            result.length,
          ).every((i) => result[i] == previous[i])) {
        setState(_clearPoints);
        return;
      }
    }
    final next = related.isEmpty
        ? _chart.appendToGroup(_activeGroup, result.join(_chart.newline))
        : _chart.replaceEvents({
            for (final segment in related)
              segment: segment == related.first
                  ? result.join(_chart.newline)
                  : '',
          });
    _points.clear();
    _edit(next);
  }

  void _editArcInScene(AffEvent event) {
    final connected = ArcDraft.connected(_chart, event);
    if (connected.any((segment) => segment.arcTaps.isNotEmpty)) {
      _message('附着空键的弧线可在 2D 修改关键点');
      return;
    }
    if (connected.isEmpty) {
      _arcPanel(event: event);
      return;
    }
    setState(() {
      _edit3d = true;
      _tool = _Tool.arc;
      _activeGroup = event.group;
      _editingArc = connected;
      _workingArc = ArcDraft.fromEvents(connected);
      _points
        ..clear()
        ..addAll(_workingArc!.points);
      _position.value = _points.first.time.toDouble().clamp(_min, _max);
    });
  }

  void _clearPoints() {
    _points.clear();
    _editingArc = const [];
    _workingArc = null;
    _movingArcPoint = null;
  }

  PerspectiveGeometry _perspectiveGeometry(Size size) =>
      PerspectiveGeometry.forScene(
        size,
        _position.value,
        _lookahead,
        _timeline.scene,
        editing: true,
      );

  TimelineGeometry _flatGeometry(Size size) => TimelineGeometry(
    size,
    _position.value,
    _lookahead,
    wideLanes: _laneMode.expansion(_timeline, _position.value) > 0,
  );

  Offset _projectKey(
    PerspectiveGeometry geometry,
    ChartKeyframe key,
    double depth, {
    ({double x, double height})? moved,
  }) {
    final position = moved ?? key.position;
    final angles = _timeline.groupOptions[key.note.group];
    return key.airTap
        ? geometry.projectArcTap(
            position.x,
            position.height,
            depth,
            angles: angles,
          )
        : geometry.projectAir(
            position.x,
            position.height,
            depth,
            angles: angles,
          );
  }

  Iterable<_ProjectedKeyframe> _visibleKeys(
    PerspectiveGeometry geometry, {
    bool endpointsOnly = false,
  }) sync* {
    if (!_showKeyframes && !endpointsOnly) return;
    final time = geometry.time;
    final visibility = _visibility;
    final emitted = <ChartKeyframe>{};
    final bounds = (Offset.zero & geometry.size).inflate(10);
    for (final (:note, :start, :end) in _timeline.visibleInPerspective(
      time,
      geometry.near - time,
      geometry.far - time,
    )) {
      if (!_laneMode.showsAt(_timeline, note, time)) continue;
      final scroll = _timeline.scroll(note.group);
      final origin = scroll.at(time);
      for (final key in chartKeyframes(note)) {
        if ((endpointsOnly
                ? !key.arcEndpoint
                : key.airTap
                ? _keyframeDisplay == _KeyframeDisplay.arcs
                : _keyframeDisplay == _KeyframeDisplay.taps) ||
            !visibility.shows(
              note,
              tap: key.kind == ChartKeyframeKind.tap ? key.time : null,
            ) ||
            key.time < start - 0.001 ||
            key.time > end + 0.001 ||
            !emitted.add(key)) {
          continue;
        }
        final moved =
            !endpointsOnly &&
                (_dragKey?.key == key || _dragLinked.contains(key))
            ? _dragPosition
            : null;
        final depth =
            time + scroll.at((moved?.time ?? key.time).toDouble()) - origin;
        final position = moved == null
            ? key.position
            : (x: moved.x, height: moved.height);
        if (geometry.viewDepth(
              position.x,
              position.height,
              depth,
              air: true,
              angles: _timeline.groupOptions[note.group],
            ) <
            PerspectiveGeometry.nearCameraDepth) {
          continue;
        }
        final point = _projectKey(geometry, key, depth, moved: position);
        if (bounds.contains(point)) {
          yield (key: key, point: point, depth: depth);
        }
      }
    }
  }

  _ProjectedKeyframe? _nearestKey(PerspectiveGeometry geometry, Offset point) {
    _ProjectedKeyframe? closest;
    _ProjectedKeyframe? detached;
    const hitRadius = 16.0;
    var minimum = hitRadius;
    for (final handle in _visibleKeys(geometry)) {
      final distance = (handle.point - point).distance;
      if (distance >= hitRadius) continue;
      if (handle.key == _detachedEndpoint) detached = handle;
      if (distance >= minimum) continue;
      minimum = distance;
      closest = handle;
    }
    if (detached != null &&
        closest != null &&
        (detached.point - closest.point).distanceSquared < 1) {
      return detached;
    }
    return closest;
  }

  _ProjectedKeyframe? _perspectiveSnap(
    PerspectiveGeometry geometry,
    Offset point, {
    required bool Function(ChartKeyframe) valid,
  }) {
    if (!_snapEndpoints) return null;
    _ProjectedKeyframe? closest;
    var radius = _endpointSnapRadius;
    for (final candidate in _visibleKeys(geometry, endpointsOnly: true)) {
      if (!valid(candidate.key)) continue;
      final distance = (candidate.point - point).distance;
      if (distance >= radius) continue;
      radius = distance;
      closest = candidate;
    }
    return closest;
  }

  ({ArcPoint position, Offset point})? _flatSnap(
    TimelineGeometry geometry,
    Offset point, {
    bool Function(int)? valid,
  }) {
    if (!_snapEndpoints) return null;
    final visibility = _visibility;
    ({ArcPoint position, Offset point})? closest;
    var radius = _endpointSnapRadius;
    for (final note in _timeline.visible(
      geometry.time(point.dy + radius),
      geometry.time(point.dy - radius),
    )) {
      if (note.group != _activeGroup ||
          _editingArc.contains(note) ||
          !visibility.shows(note)) {
        continue;
      }
      for (final key in chartKeyframes(note)) {
        if (!key.arcEndpoint || valid?.call(key.time) == false) continue;
        final position = key.position;
        final at = Offset(
          geometry.x(position.x, airborne: true),
          geometry.y(key.time.toDouble()),
        );
        final distance = (at - point).distance;
        if (distance >= radius) continue;
        radius = distance;
        closest = (
          position: (time: key.time, x: position.x, height: position.height),
          point: at,
        );
      }
    }
    return closest;
  }

  Iterable<PerspectiveKeyframeMarker> _keyframeMarkers(
    PerspectiveGeometry geometry,
  ) sync* {
    for (final (:key, :point, :depth) in _visibleKeys(geometry)) {
      Rect? outline;
      if (key.kind == ChartKeyframeKind.tap) {
        final moved = _dragKey?.key == key ? _dragPosition : null;
        final position = moved == null
            ? key.position
            : (x: moved.x, height: moved.height);
        const halfWidth = PerspectiveGeometry.arcTapHalfWidth;
        final left = _projectKey(
          geometry,
          key,
          depth,
          moved: (x: position.x - halfWidth, height: position.height),
        );
        final right = _projectKey(
          geometry,
          key,
          depth,
          moved: (x: position.x + halfWidth, height: position.height),
        );
        outline = Rect.fromPoints(left, right).inflate(8);
      }
      yield (
        point: point,
        tap: key.airTap,
        outline: outline,
        detached: key == _detachedEndpoint,
      );
    }
  }

  void _beginDrag(PointerDownEvent event, Size size) {
    _dragPointer = event.pointer;
    _dragOrigin = event.localPosition;
    if (_edit3d) {
      final geometry = _perspectiveGeometry(size);
      _dragKey = _nearestKey(geometry, event.localPosition);
      if (_dragKey case final handle?) {
        final joint = chartJoinedEndpoints(_chart, handle.key).toList();
        final detached = _detachedEndpoint;
        _dragDetached =
            detached != null &&
            joint.any((key) => key == detached && key.note == handle.key.note);
        _dragLinked = joint.where((key) {
          return _dragDetached ? key == detached : key != detached;
        }).toList();
      }
      return;
    }
    final flat = _flatGeometry(size);
    final point = event.localPosition;
    if ((_arcTool && point.dx >= flat.centerGap) ||
        (_tool == _Tool.hold &&
            (_allowOverflow
                ? point.dx < flat.centerGap
                : point.dx >= flat.x(flat.groundStart) &&
                      point.dx <= flat.x(flat.groundEnd)))) {
      _stroke.add(point);
    }
  }

  void _moveDrag(PointerMoveEvent event, Size size) {
    final origin = _dragOrigin;
    if (_dragPointer != event.pointer ||
        origin == null ||
        (!_didDrag && (event.localPosition - origin).distance < 7)) {
      return;
    }
    if (_dragKey case final handle?) {
      final geometry = _perspectiveGeometry(size);
      final position = geometry.pickAirAt(
        handle.point + event.localPosition - origin,
        handle.depth,
        arcTap: handle.key.airTap,
        angles: _timeline.groupOptions[handle.key.note.group],
      );
      if (position == null) return;
      final original = handle.key.position;
      final x = _heightOnly
          ? original.x
          : _roundCoordinate(
              position.x.clamp(
                math.min(-0.5, original.x),
                math.max(1.5, original.x),
              ),
            );
      final height = event.localPosition.dy == origin.dy
          ? original.height
          : _roundCoordinate(
              position.height.clamp(
                math.min(0.0, original.height),
                math.max(
                  _allowOverflow ? 2.5 : geometry.skyLineHeight,
                  original.height,
                ),
              ),
            );
      final snap = handle.key.arcEndpoint && !_dragDetached
          ? _perspectiveSnap(
              geometry,
              _projectKey(
                geometry,
                handle.key,
                handle.depth,
                moved: (x: x, height: height),
              ),
              valid: (key) =>
                  key.note.group == handle.key.note.group &&
                  key != _detachedEndpoint &&
                  !_dragLinked.contains(key) &&
                  (_allowOverflow ||
                      key.position.height <=
                          math.max(geometry.skyLineHeight, original.height)) &&
                  (!_heightOnly ||
                      (key.time == handle.key.time &&
                          (key.position.x - original.x).abs() < 1e-6)) &&
                  canMoveChartEndpoints(_dragLinked, key.time),
            )
          : null;
      final target = snap?.key;
      _didDrag = true;
      setState(() {
        _dragPosition = (
          time: target?.time ?? handle.key.time,
          x: _heightOnly ? original.x : target?.position.x ?? x,
          height: target?.position.height ?? height,
        );
        _snapPoint = snap?.point;
      });
    } else if (_stroke.isNotEmpty &&
        (event.localPosition - _stroke.last).distance >= 3) {
      _didDrag = true;
      setState(() => _stroke.add(event.localPosition));
    }
  }

  double _roundCoordinate(double value) => (value * 1000).round() / 1000;

  void _clearDrag() {
    _dragPointer = null;
    _dragOrigin = null;
    _dragKey = null;
    _dragLinked = const [];
    _dragDetached = false;
    _dragPosition = null;
    _snapPoint = null;
    _stroke.clear();
  }

  void _finishDrag(PointerUpEvent event, Size size) {
    if (_dragPointer != event.pointer) return;
    final moved = _dragPosition;
    final key = _dragKey?.key;
    final linked = _dragLinked;
    final points = [..._stroke, event.localPosition];
    final create = _didDrag && _stroke.isNotEmpty;
    setState(_clearDrag);
    if (!_didDrag || _busy || _chart.errors.isNotEmpty) return;
    _editFocus.requestFocus();
    if (key != null && moved != null) {
      final ordinal = _chart.events.indexOf(key.note);
      if (ordinal < 0) return;
      final split =
          key.kind == ChartKeyframeKind.tap &&
          key.note.firstTime < key.time &&
          key.time < key.note.lastTime;
      final next = moveChartKeyframe(
        _chart,
        key,
        moved.x,
        moved.height,
        time: moved.time,
        linkedEndpoints: linked,
      );
      if (next == _chart.source || AffChart.parse(next).errors.isNotEmpty) {
        return;
      }
      _edit(next, keepEventOrder: !split);
      final updated = _chart.events[ordinal + (split ? 1 : 0)];
      setState(() {
        if (key.kind == ChartKeyframeKind.tap || _selectedArcTap != null) {
          _selection.clear();
        }
        _selection.add(updated);
        _selected = updated;
        _selectedArcTap =
            key.kind == ChartKeyframeKind.tap && !_isStandaloneSky(updated)
            ? key.time
            : null;
        if (key.arcEndpoint) {
          final updatedKey = chartKeyframes(
            updated,
          ).firstWhere((endpoint) => endpoint.kind == key.kind);
          _selectedJoint = chartJoinedEndpoints(_chart, updatedKey).toList();
        }
      });
    } else if (create) {
      _createStroke(_flatGeometry(size), points);
    }
  }

  Future<void> _disconnectEndpoint() async {
    final categories = ChartEditorVisibility(items: _displayItems);
    final eligible = _selectedJoint.where((key) => categories.shows(key.note));
    final chosen = await showDialog<ChartKeyframe>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('断开拼接'),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text('选择要单独拖动的端点。'),
          ),
          for (final key in eligible)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, key),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: key.note.trace
                    ? const Icon(Icons.timeline, size: 16)
                    : Icon(
                        Icons.circle,
                        size: 14,
                        color: ChartTimelinePainter.arcColor(key.note),
                      ),
                title: Text(
                  '${key.note.trace ? '弧线' : '蛇'} · ${key.kind == ChartKeyframeKind.start ? '起点' : '终点'}',
                ),
                subtitle: Text(
                  '${key.note.start} – ${key.note.end} ms · '
                  '另一端 X ${key.note.number(key.kind == ChartKeyframeKind.start ? 3 : 2).toStringAsFixed(3)}，'
                  'Y ${key.note.number(key.kind == ChartKeyframeKind.start ? 6 : 5).toStringAsFixed(3)}',
                ),
              ),
            ),
        ],
      ),
    );
    if (!mounted || chosen == null || !_chart.events.contains(chosen.note)) {
      return;
    }
    setState(() {
      _detachedEndpoint = chosen;
      _selection
        ..clear()
        ..add(chosen.note);
      _selected = chosen.note;
      _selectedArcTap = null;
    });
  }

  void _createStroke(TimelineGeometry geometry, List<Offset> stroke) {
    int timeAt(Offset point) => _placementTime(
      geometry.time(point.dy).clamp(_min, _max),
    ).clamp(_min.ceil(), _max.floor());
    final String statement;
    double? ground;
    if (_tool == _Tool.hold) {
      final from = timeAt(stroke.first), to = timeAt(stroke.last);
      if (from == to) return;
      final lane = geometry.lane(stroke.first.dx);
      statement = 'hold(${math.min(from, to)},${math.max(from, to)},$lane);';
      if (_allowOverflow) {
        ground = _roundCoordinate(
          geometry.trackX(stroke.first.dx, freeGround: true),
        );
      }
    } else if (_arcTool) {
      final first = _strokeArcPoint(geometry, stroke.first);
      final last = _strokeArcPoint(
        geometry,
        stroke.last,
        valid: (time) => time != first.time,
      );
      final byTime = <int, ArcPoint>{};
      for (final sample in stroke.skip(1).take(stroke.length - 2)) {
        final time = timeAt(sample);
        if (time <= math.min(first.time, last.time) ||
            time >= math.max(first.time, last.time)) {
          continue;
        }
        byTime[time] = (
          time: time,
          x: _roundCoordinate(geometry.trackX(sample.dx, airborne: true)),
          height: 1.0,
        );
      }
      byTime[first.time] = first;
      byTime[last.time] = last;
      if (byTime.length < 2) return;
      statement = ArcDraft(
        points: byTime.values.toList(),
        trace: _tool == _Tool.trace,
      ).encode().join(_chart.newline);
    } else {
      return;
    }
    final existing = _chart.events
        .where((event) => event.group == _activeGroup)
        .length;
    _edit(
      _chart.appendToGroup(_activeGroup, statement, groundPositions: [ground]),
    );
    if (_onlySelected) {
      setState(() {
        if (_selectedArcTap != null) _selection.clear();
        _selection.addAll(
          _chart.events
              .where((event) => event.group == _activeGroup)
              .skip(existing)
              .where((event) => event.isNote),
        );
        _selected = _selection.lastOrNull;
        _selectedArcTap = null;
      });
    }
  }

  ArcPoint _strokeArcPoint(
    TimelineGeometry geometry,
    Offset point, {
    bool Function(int)? valid,
  }) =>
      _flatSnap(geometry, point, valid: valid)?.position ??
      (
        time: _placementTime(geometry.time(point.dy).clamp(_min, _max)),
        x: _roundCoordinate(geometry.trackX(point.dx, airborne: true)),
        height: 1,
      );

  List<Offset> _strokePath(Size size) {
    if (!_didDrag || _stroke.isEmpty) return const [];
    final geometry = _flatGeometry(size);
    if (_arcTool) {
      final (first, last) = _strokeSnaps(geometry);
      return [
        first?.point ?? _stroke.first,
        ..._stroke.skip(1).take(math.max(0, _stroke.length - 2)),
        last?.point ?? _stroke.last,
      ];
    }
    final x = _allowOverflow
        ? _stroke.first.dx
        : geometry.x((geometry.lane(_stroke.first.dx) - 0.5) / 4);
    return [Offset(x, _stroke.first.dy), Offset(x, _stroke.last.dy)];
  }

  (({ArcPoint position, Offset point})?, ({ArcPoint position, Offset point})?)
  _strokeSnaps(TimelineGeometry geometry) {
    if (!_didDrag || !_arcTool || _stroke.length < 2) return (null, null);
    final first = _flatSnap(geometry, _stroke.first);
    final time =
        first?.position.time ?? _placementTime(geometry.time(_stroke.first.dy));
    final last = _flatSnap(
      geometry,
      _stroke.last,
      valid: (candidate) => candidate != time,
    );
    return (first, last);
  }

  void _stepGrid(int steps) {
    if (steps == 0 || _busy) return;
    _parse();
    final grid = _beatGrid(_activeGroup);
    var cursor = _position.value;
    for (var i = 0; i < steps.abs(); i++) {
      final next = grid
          .next(cursor, forward: steps > 0)
          .toDouble()
          .clamp(_min, _max);
      if (next == cursor) break;
      cursor = next;
    }
    _position.value = cursor;
  }

  void _scrollWheel(PointerScrollEvent event) {
    if (HardwareKeyboard.instance.isControlPressed) {
      final delta = Platform.isWindows && event.kind == PointerDeviceKind.mouse
          ? event.scrollDelta.dy *
                View.of(context).devicePixelRatio /
                _wheelStep
          : event.scrollDelta.dy / 100;
      _setZoom(_zoom * math.pow(1.2, -delta));
      return;
    }
    if (!Platform.isWindows || event.kind != PointerDeviceKind.mouse) {
      _stepGrid(event.scrollDelta.dy.sign.toInt());
      return;
    }
    _wheelScroll +=
        event.scrollDelta.dy * View.of(context).devicePixelRatio / _wheelStep;
    // Tolerate rounding when the engine converts through physical pixels.
    final steps = (_wheelScroll + _wheelScroll.sign * 0.00001).truncate();
    _wheelScroll -= steps;
    _stepGrid(steps);
  }

  void _scrollGrid(double pixels) {
    const pixelsPerStep = 24;
    _gestureScroll += pixels;
    final steps = (_gestureScroll / pixelsPerStep).truncate();
    _gestureScroll -= steps * pixelsPerStep;
    _stepGrid(steps);
  }

  void _setZoom(double value) {
    final zoom = value.clamp(_minZoom, _maxZoom);
    if (zoom != _zoom) setState(() => _zoom = zoom);
  }

  Future<void> _editZoom() async {
    final value = await showDialog<double>(
      context: context,
      builder: (_) => _EventDialog(
        _zoom.toStringAsFixed(2),
        numberLabel: '铺面缩放（0.25–8 倍）',
        numberRange: (_minZoom, _maxZoom),
      ),
    );
    if (mounted && value != null) _setZoom(value);
  }

  void _moveTouchPair({bool anchored = false}) {
    final origin = _pairOrigin;
    if (origin == null) return;
    final (a, b) = origin;
    final first = _pointers.values.first;
    final second = _pointers.values.last;
    final firstTravel = first - a, secondTravel = second - b;
    final pan = (firstTravel + secondTravel) / 2;
    final before = (b - a).distance;
    final after = (second - first).distance;
    final spanChange = (after - before).abs();
    if (_pairGesture == null) {
      final bothMoved = firstTravel.distance >= 3 && secondTravel.distance >= 3;
      final isPinch =
          before >= 10 && spanChange >= 8 && spanChange > pan.distance * 1.5;
      // A short grace period distinguishes a fixed finger from the first
      // reported movement of two fingers moving in parallel.
      if (!bothMoved && !anchored) {
        if (isPinch && spanChange >= 14) {
          _pairIdle ??= Timer(const Duration(milliseconds: 45), () {
            _pairIdle = null;
            if (mounted && !_busy) _moveTouchPair(anchored: true);
          });
        }
        return;
      }
      _pairIdle?.cancel();
      _pairIdle = null;
      if (isPinch) {
        _pairGesture = _EditorTouchGesture.zoom;
      } else if (bothMoved && pan.dy.abs() >= 8 && pan.dy.abs() >= spanChange) {
        _pairGesture = _EditorTouchGesture.pan;
      }
    }
    switch (_pairGesture) {
      case _EditorTouchGesture.zoom:
        _setZoom(_pairZoom * after / before);
      case _EditorTouchGesture.pan:
        final delta = pan.dy - _pairPan;
        _pairPan = pan.dy;
        _scrollGrid(delta);
      case null:
        break;
    }
  }

  void _endTouchPair() {
    _pairIdle?.cancel();
    _pairIdle = null;
    _pairOrigin = null;
  }

  Future<void> _showDisplayMenu() => showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, updateMenu) {
        void update(VoidCallback change) {
          setState(change);
          updateMenu(() {});
        }

        return AlertDialog(
          title: const Text('显示项'),
          scrollable: true,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                title: const Text('仅显示选中'),
                value: _onlySelected,
                onChanged: (value) => update(() => _onlySelected = value),
              ),
              const Divider(),
              for (final item in ChartDisplayItem.values)
                CheckboxListTile(
                  title: Text(item.label),
                  dense: true,
                  value: _displayItems.contains(item),
                  onChanged: (value) => update(() {
                    if (value == true) {
                      _displayItems.add(item);
                    } else {
                      _displayItems.remove(item);
                    }
                  }),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => update(() {
                _onlySelected = false;
                _displayItems.addAll(ChartDisplayItem.values);
              }),
              child: const Text('全部显示'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('完成'),
            ),
          ],
        );
      },
    ),
  );

  void _noteOperation(String action) {
    if (_selectedArcTap case final tap? when _selected != null) {
      if (action == 'delete') {
        if (!_edit3d || _onWall(_selected!, tap)) {
          _rewriteArcTap(_selected!, tap, null);
        }
        return;
      }
      if (const {
        'copy',
        'cut',
        'mirror',
        'snap',
        'moveGroup',
      }.contains(action)) {
        _message('请先选中弧线本体，再执行该操作');
        return;
      }
    }
    if (_edit3d &&
        action != 'range' &&
        action != 'paste' &&
        _selection.any(
          (note) => _isStandaloneSky(note)
              ? !_onWall(note, note.start)
              : note.arcTaps.isNotEmpty,
        )) {
      _message('请将空键移到判定面后单独编辑');
      return;
    }
    if (action == 'range') {
      _selectRange();
      return;
    }
    if (action == 'moveGroup') {
      _moveToGroup();
      return;
    }
    if (_selection.isEmpty && action != 'paste') return;
    if (action == 'copy' || action == 'cut') {
      _clipboard = _selection.where((event) => event.isNote).toList();
      if (action == 'copy') {
        setState(() {});
        return;
      }
    }
    if (action == 'delete' || action == 'cut') {
      final events = action == 'cut' ? _clipboard : _selection;
      final source = _chart.replaceEvents({
        for (final event in events) event: '',
      });
      final result = AffChart.parse(source);
      if (result.errors.isEmpty) {
        _edit(source);
      } else {
        _message(result.errors.first);
      }
      return;
    }
    if (action == 'paste' && _clipboard.isNotEmpty) {
      final first = _clipboard.map((event) => event.start).reduce(math.min);
      final offset = _snapped(_position.value) - first;
      if (_edit3d &&
          _clipboard.any(
            (event) =>
                (event.variableArcTap &&
                    (event.start + offset - _position.value).abs() > 1) ||
                event.arcTaps.any(
                  (tap) => (tap + offset - _position.value).abs() > 1,
                ),
          )) {
        _message('3D 只可将空键粘贴到判定面');
        return;
      }
      if (_clipboard.any((event) => !_laneMode.shows(event))) {
        _message('请切换到 6K 后粘贴外侧轨道的音符');
        return;
      }
      final text = _clipboard
          .map((event) => _transformNote(event, offset: offset))
          .join(_chart.newline);
      final source = _chart.appendToGroup(
        _activeGroup,
        text,
        sustainJudgements: [
          for (final note in _clipboard)
            note.sustainJudgements?.map((at) => at + offset).toList(),
        ],
        groundPositions: [for (final note in _clipboard) note.groundPosition],
      );
      if (AffChart.parse(source).errors.isEmpty) _edit(source);
    } else if (action == 'mirror' || action == 'snap') {
      final source = _chart.replaceEvents(
        {
          for (final event in _selection.where((event) => event.isNote))
            event: _transformNote(
              event,
              mirror: action == 'mirror',
              offset: action == 'snap'
                  ? _snapped(
                          event.start.toDouble(),
                          group: event.group,
                          force: true,
                        ) -
                        event.start
                  : 0,
            ),
        },
        groundPositions: {
          if (action == 'mirror')
            for (final event in _selection)
              if (event.groundPosition != null) event: 1 - event.laneX,
        },
      );
      if (source != _chart.source && AffChart.parse(source).errors.isEmpty) {
        _edit(source, keepEventOrder: true);
      }
    }
  }

  Future<void> _selectRange() async {
    var begin = '${_position.value.round()}';
    var end = '${_position.value.round() + 1000}';
    final range = await showDialog<({int start, int end})>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('按时间范围选择'),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              initialValue: begin,
              onChanged: (value) => begin = value,
              keyboardType: const TextInputType.numberWithOptions(signed: true),
              decoration: const InputDecoration(labelText: '起点（毫秒）'),
            ),
            TextFormField(
              initialValue: end,
              onChanged: (value) => end = value,
              keyboardType: const TextInputType.numberWithOptions(signed: true),
              decoration: const InputDecoration(labelText: '终点（毫秒）'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final a = int.tryParse(begin), b = int.tryParse(end);
              if (a != null && b != null && a <= b) {
                Navigator.pop(context, (start: a, end: b));
              }
            },
            child: const Text('选择'),
          ),
        ],
      ),
    );
    if (!mounted || range == null) return;
    final categories = ChartEditorVisibility(items: _displayItems);
    setState(() {
      _selectedArcTap = null;
      _selection
        ..clear()
        ..addAll(
          _timeline
              .visible(range.start.toDouble(), range.end.toDouble())
              .where(
                (note) =>
                    _laneMode.shows(note) &&
                    (categories.shows(note) ||
                        (note.standaloneSky &&
                            note.arcTaps.any(
                              (tap) => categories.shows(note, tap: tap),
                            ))) &&
                    (!_edit3d ||
                        (!_isStandaloneSky(note) && note.arcTaps.isEmpty)),
              ),
        );
      _selected = _selection.lastOrNull;
    });
  }

  Future<void> _moveToGroup() async {
    final notes = _selection.where((event) => event.isNote).toList();
    if (notes.isEmpty) return;
    final group = await showDialog<int>(
      context: context,
      builder: (_) => SimpleDialog(
        title: const Text('将选中音符移到分组'),
        children: [
          for (final group in _chart.groups)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, group.id),
              child: Text(
                group.id == 0 ? '主轨' : '分组 ${group.id} ${group.attributes}',
              ),
            ),
        ],
      ),
    );
    if (!mounted || group == null) return;
    final moving = notes.where((note) => note.group != group).toList();
    if (moving.isEmpty) return;
    final statements = moving
        .map(
          (note) => _chart.source.substring(note.sourceStart, note.sourceEnd),
        )
        .join(_chart.newline);
    final cleaned = AffChart.parse(
      _chart.replaceEvents({for (final note in moving) note: ''}),
    );
    _edit(
      cleaned.appendToGroup(
        group,
        statements,
        sustainJudgements: [for (final note in moving) note.sustainJudgements],
        groundPositions: [for (final note in moving) note.groundPosition],
      ),
    );
  }

  String _transformNote(AffEvent event, {int offset = 0, bool mirror = false}) {
    final a = event.arguments.toList();
    a[0] = '${event.start + offset}';
    if (event.kind == AffKind.arc || event.kind == AffKind.hold) {
      a[1] = '${event.end + offset}';
    }
    if (mirror) {
      switch (event.kind) {
        case AffKind.tap || AffKind.hold:
          final index = event.groundLaneIndex;
          final inline = event.inlineGroundPosition;
          a[index] = inline == null
              ? '${5 - int.parse(a[index])}'
              : (1 - inline).toStringAsFixed(6);
        case AffKind.arc:
          a[2] = '${1 - event.number(2)}';
          a[3] = '${1 - event.number(3)}';
        case AffKind.flick:
          a[1] = '${1 - event.number(1)}';
          a[3] = '${-event.number(3)}';
        default:
          break;
      }
    }
    final taps = event.arcTaps.isEmpty
        ? ''
        : '[${event.arcTaps.map((time) => 'arctap(${time + offset})').join(',')}]';
    return '${event.command}(${a.join(',')})$taps;';
  }

  Future<void> _editSustainJudgements(AffEvent note) async {
    final automatic = <int>[
      ..._timeline.automaticSustainCheckpoints(note).take(99999),
    ];
    final result = await showDialog<({List<int>? points})>(
      context: context,
      builder: (_) => _SustainJudgementDialog(
        note: note,
        automatic: automatic,
        cursor: _position.value.round(),
      ),
    );
    if (!mounted || result == null || !_chart.events.contains(note)) return;
    _edit(
      _chart.withSustainJudgements({note: result.points}),
      keepEventOrder: true,
    );
  }

  Future<void> _editEvent({
    AffEvent? event,
    String? statement,
    double? groundPosition,
  }) async {
    if (_selectedArcTap case final tap?
        when event != null && event == _selected) {
      if (!_edit3d || _onWall(event, tap)) await _editAttachedTap(event, tap);
      return;
    }
    if (_edit3d && event != null) {
      if (_isStandaloneSky(event) && !_onWall(event, event.start)) {
        _message('将时间游标移到空键的判定位置后再编辑');
        return;
      }
      if (!_isStandaloneSky(event) && event.arcTaps.isNotEmpty) {
        _message('请在判定面上单独编辑空键，或切换到 2D 修改弧线');
        return;
      }
    }
    final original = event == null
        ? statement!
        : _chart.source.substring(event.sourceStart, event.sourceEnd);
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _EventDialog(original, canDelete: event != null),
    );
    if (!mounted || result == null || (event != null && result == original)) {
      return;
    }
    final source = event == null
        ? _chart.appendToGroup(
            _activeGroup,
            result,
            groundPositions: [groundPosition],
          )
        : _chart.replace(event, result);
    final candidate = AffChart.parse(source);
    if (candidate.errors.isNotEmpty) {
      _message(candidate.errors.first);
      return;
    }
    _edit(source);
  }

  void _rewriteArcTap(AffEvent event, int tap, int? newTime) {
    final taps = event.arcTaps.toList();
    final index = taps.indexOf(tap);
    if (index == -1) return;
    if (newTime == null) {
      taps.removeAt(index);
    } else {
      taps[index] = newTime;
      taps.sort();
    }
    final suffix = taps.isEmpty
        ? ''
        : '[${taps.map((t) => 'arctap($t)').join(',')}]';
    final selected = _selected == event && _selectedArcTap == tap;
    if (selected && newTime != null) _selectedArcTap = newTime;
    _edit(_chart.replace(event, 'arc(${event.arguments.join(',')})$suffix;'));
  }

  Future<void> _editAttachedTap(AffEvent event, int tap) async {
    var text = '$tap';
    final result = await showDialog<({int? time})>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_edit3d ? '编辑判定面上的空键' : '编辑附着天键'),
        content: TextFormField(
          initialValue: text,
          onChanged: (value) => text = value,
          keyboardType: const TextInputType.numberWithOptions(signed: true),
          decoration: InputDecoration(
            labelText: '时间（毫秒）',
            helperText: '${event.firstTime} – ${event.lastTime} ms',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, (time: null)),
            child: const Text('删除空键'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final value = int.tryParse(text);
              if (value != null &&
                  value >= event.firstTime &&
                  value <= event.lastTime) {
                Navigator.pop(context, (time: value));
              }
            },
            child: const Text('应用'),
          ),
        ],
      ),
    );
    if (!mounted || result == null || result.time == tap) return;
    _rewriteArcTap(event, tap, result.time);
  }

  Future<void> _editEffects({bool laneSwitchesOnly = false}) async {
    _parse();
    if (_chart.errors.isNotEmpty) {
      _message(_chart.errors.first);
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => ChartEffectPanel(
        chart: _chart,
        initialTime: laneSwitchesOnly
            ? _position.value.round()
            : _snapped(_position.value),
        initialGroup: laneSwitchesOnly ? 0 : _activeGroup,
        laneSwitchesOnly: laneSwitchesOnly,
        onChart: _edit,
      ),
    );
  }

  Future<void> _leave() async {
    if (_busy) return;
    if (_dirty && !await _confirm('放弃当前修改？', '请先保存或导出需要保留的内容。', '放弃并返回')) {
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _endTouchPair();
    _editFocus.dispose();
    _parseTimer?.cancel();
    _source.dispose();
    _position.dispose();
    _skin.value.dispose();
    _skin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasChart =
        _loadError == null && (_original != null || widget.files == null);
    final available = hasChart && !_busy;
    return PopScope(
      canPop: !_dirty && !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.title, overflow: TextOverflow.ellipsis),
          actions: [
            if (widget.files != null)
              IconButton(
                tooltip: '保存到歌曲目录',
                onPressed: available && _dirty ? _save : null,
                icon: const Icon(Icons.save_outlined),
              ),
            PopupMenuButton<String>(
              tooltip: '谱面菜单',
              enabled: available,
              onSelected: (action) {
                switch (action) {
                  case 'open':
                    _open();
                  case 'new':
                    _newChart();
                  case 'audio':
                    _chooseAudio();
                  case 'skin':
                    _chooseSkin();
                  case 'offset':
                    _editOffset();
                  case 'timing':
                    _editTiming();
                  case 'effects':
                    _editEffects();
                  case 'appearance':
                    _editAppearance();
                  case 'export':
                    _export();
                  case 'backup':
                    _restore();
                  case 'compatibility':
                    _checkCompatibility();
                }
              },
              itemBuilder: (_) => [
                if (widget.files == null) ...[
                  const PopupMenuItem(value: 'new', child: Text('新建谱面')),
                  const PopupMenuItem(value: 'open', child: Text('打开 AFF')),
                ],
                const PopupMenuItem(value: 'skin', child: Text('选择预览素材目录')),
                if (Platform.isAndroid || Platform.isWindows)
                  const PopupMenuItem(value: 'audio', child: Text('选择音频')),
                const PopupMenuItem(value: 'timing', child: Text('BPM 与谱面流速')),
                const PopupMenuItem(value: 'effects', child: Text('镜头与场景控制')),
                const PopupMenuItem(value: 'appearance', child: Text('谱面不透明度')),
                PopupMenuItem(
                  value: 'offset',
                  child: Text('音频偏移 · ${_chart.audioOffset} ms'),
                ),
                const PopupMenuItem(value: 'export', child: Text('导出 AFF')),
                const PopupMenuItem(value: 'backup', child: Text('管理备份')),
                const PopupMenuItem(
                  value: 'compatibility',
                  child: Text('AFF 兼容检查'),
                ),
              ],
            ),
          ],
        ),
        body: !hasChart
            ? Center(
                child: _loadError == null
                    ? const CircularProgressIndicator()
                    : Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text('无法打开谱面\n$_loadError'),
                      ),
              )
            : SafeArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_busy) const LinearProgressIndicator(),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      child: Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 5,
                        children: [
                          ChoiceChip(
                            label: const Text('时间轴'),
                            selected: !_showSource,
                            onSelected: available
                                ? (_) => setState(() => _showSource = false)
                                : null,
                          ),
                          ChoiceChip(
                            label: const Text('AFF 源码'),
                            selected: _showSource,
                            onSelected: available
                                ? (_) => setState(() => _showSource = true)
                                : null,
                          ),
                          IconButton(
                            tooltip: '撤销',
                            onPressed: available && _undo.isNotEmpty
                                ? _undoEdit
                                : null,
                            icon: const Icon(Icons.undo),
                          ),
                          IconButton(
                            tooltip: '重做',
                            onPressed: available && _redo.isNotEmpty
                                ? _redoEdit
                                : null,
                            icon: const Icon(Icons.redo),
                          ),
                          TextButton.icon(
                            onPressed: available ? () => _preview(false) : null,
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('预览'),
                          ),
                          TextButton.icon(
                            onPressed: available ? () => _preview(true) : null,
                            icon: const Icon(Icons.gamepad_outlined),
                            label: const Text('试玩'),
                          ),
                          ChartAppearanceButton(
                            onPressed: available ? _editAppearance : null,
                          ),
                        ],
                      ),
                    ),
                    if (_chart.errors.isNotEmpty ||
                        _source.text.length > _maxBytes)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.error_outline),
                        title: Text(
                          _source.text.length > _maxBytes
                              ? 'AFF 内容超过大小限制'
                              : _chart.errors.first,
                        ),
                        trailing: _chart.errors.length > 1
                            ? Text('${_chart.errors.length} 处')
                            : null,
                      )
                    else if (_chart.unrendered.isNotEmpty ||
                        _chart.warnings.isNotEmpty ||
                        _dirty)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        child: Text(
                          [
                            ..._chart.warnings,
                            if (_dirty) '有未保存更改',
                            if (_chart.unrendered.isNotEmpty)
                              '仅保留源码：${_chart.unrendered.join('、')}',
                          ].join(' · '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    if (_showSource)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: TextField(
                            key: const ValueKey('aff-source'),
                            controller: _source,
                            readOnly: !available,
                            onChanged: _changed,
                            expands: true,
                            maxLines: null,
                            minLines: null,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 13,
                            ),
                            autocorrect: false,
                            enableSuggestions: false,
                            smartDashesType: SmartDashesType.disabled,
                            smartQuotesType: SmartQuotesType.disabled,
                            decoration: InputDecoration(
                              labelText: _fileName,
                              border: const OutlineInputBorder(),
                              alignLabelWithHint: true,
                            ),
                          ),
                        ),
                      )
                    else
                      ..._timelineWidgets(available),
                  ],
                ),
              ),
      ),
    );
  }

  List<Widget> _timelineWidgets(bool enabled) => [
    SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          ChoiceChip(
            label: Text(_edit3d ? '3D 编辑' : '2D 编辑'),
            selected: _edit3d,
            onSelected: enabled
                ? (_) => setState(() {
                    _edit3d = !_edit3d;
                    _clearDrag();
                  })
                : null,
          ),
          PopupMenuButton<int>(
            tooltip: '节拍细分与滚动步长',
            enabled: enabled,
            onSelected: (division) => setState(() {
              _snap = division != 0;
              if (_snap) _subdivision = division;
            }),
            itemBuilder: (_) => [
              const PopupMenuItem(value: 0, child: Text('关闭吸附')),
              for (final part in [4, 8, 12, 16, 24, 32, 48, 64])
                CheckedPopupMenuItem(
                  value: part,
                  checked: _snap && part == _subdivision,
                  child: Text('1/$part'),
                ),
            ],
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                _snap ? '1/$_subdivision 吸附 ▾' : '1/$_subdivision 滚动 ▾',
              ),
            ),
          ),
          ChartLaneMenu(
            mode: _laneMode,
            onChanged: enabled
                ? (mode) => setState(() => _setLaneMode(mode))
                : null,
          ),
          const SizedBox(width: 8),
          for (final tool in _Tool.values)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text(tool.label),
                selected: _tool == tool,
                onSelected: enabled
                    ? (_) => setState(() {
                        if (_tool != tool) _clearPoints();
                        _tool = tool;
                      })
                    : null,
              ),
            ),
          FilterChip(
            label: const Text('多选'),
            selected: _selectMultiple,
            onSelected: enabled
                ? (value) => setState(() => _selectMultiple = value)
                : null,
          ),
          PopupMenuButton<String>(
            tooltip: '编辑选中的音符',
            enabled: enabled,
            onSelected: _noteOperation,
            itemBuilder: (_) => [
              for (final (action, label) in [
                ('copy', '复制'),
                ('cut', '剪切'),
                ('paste', '粘贴到游标'),
                ('mirror', '水平镜像'),
                ('snap', '吸附选中音符'),
                ('range', '范围选择…'),
                ('moveGroup', '移动到分组…'),
                ('delete', '删除'),
              ])
                PopupMenuItem(
                  value: action,
                  enabled:
                      action == 'range' ||
                      (action == 'paste'
                          ? _clipboard.isNotEmpty
                          : _selection.isNotEmpty),
                  child: Text(label),
                ),
            ],
          ),
          if (_chart.groups.length > 1)
            PopupMenuButton<int>(
              tooltip: '选择放置事件的变速分组',
              enabled: enabled,
              onSelected: (id) => setState(() {
                _clearPoints();
                _activeGroup = id;
              }),
              itemBuilder: (_) => [
                for (final group in _chart.groups)
                  PopupMenuItem(
                    value: group.id,
                    child: Text(
                      group.id == 0
                          ? '主轨'
                          : '分组 ${group.id} ${group.attributes}',
                    ),
                  ),
              ],
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Text(_activeGroup == 0 ? '主轨 ▾' : '分组 $_activeGroup ▾'),
              ),
            ),
        ],
      ),
    ),
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          OutlinedButton.icon(
            icon: const Icon(Icons.view_week_outlined),
            label: const Text('4K／6K 事件'),
            onPressed: enabled
                ? () => _editEffects(laneSwitchesOnly: true)
                : null,
          ),
          OutlinedButton.icon(
            icon: Icon(
              _onlySelected ||
                      _displayItems.length != ChartDisplayItem.values.length
                  ? Icons.filter_alt
                  : Icons.visibility_outlined,
            ),
            label: const Text('显示项'),
            onPressed: enabled ? _showDisplayMenu : null,
          ),
          FilterChip(
            label: const Text('端点吸附'),
            selected: _snapEndpoints,
            onSelected: enabled
                ? (value) => setState(() => _snapEndpoints = value)
                : null,
          ),
          Tooltip(
            message: '地键可自由横移，3D 中可在天空判定线上方放置。地键精确位置写入 AFF 扩展标头。',
            child: FilterChip(
              label: const Text('允许越界'),
              selected: _allowOverflow,
              onSelected: enabled
                  ? (value) => setState(() {
                      _allowOverflow = value;
                      _clearPoints();
                      _clearDrag();
                    })
                  : null,
            ),
          ),
          if (_edit3d) ...[
            FilterChip(
              label: const Text('显示关键点'),
              selected: _showKeyframes,
              onSelected: enabled
                  ? (value) => setState(() {
                      _showKeyframes = value;
                      _clearDrag();
                    })
                  : null,
            ),
            PopupMenuButton<_KeyframeDisplay>(
              tooltip: '3D 关键点显示',
              enabled: enabled && _showKeyframes,
              initialValue: _keyframeDisplay,
              onSelected: (value) => setState(() => _keyframeDisplay = value),
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: _KeyframeDisplay.arcs,
                  child: Text('只显示蛇／弧线关键点'),
                ),
                PopupMenuItem(
                  value: _KeyframeDisplay.taps,
                  child: Text('只显示天键关键点'),
                ),
                PopupMenuItem(
                  value: _KeyframeDisplay.both,
                  child: Text('显示全部关键点'),
                ),
              ],
              icon: const Icon(Icons.scatter_plot_outlined),
            ),
            FilterChip(
              label: const Text('只调高度'),
              selected: _heightOnly,
              onSelected: enabled
                  ? (value) => setState(() => _heightOnly = value)
                  : null,
            ),
            if (_showKeyframes && _keyframeDisplay != _KeyframeDisplay.taps)
              OutlinedButton(
                onPressed: !enabled
                    ? null
                    : _detachedEndpoint != null
                    ? () => setState(() => _detachedEndpoint = null)
                    : _selectedJoint.length > 1
                    ? _disconnectEndpoint
                    : null,
                child: Text(_detachedEndpoint == null ? '断开拼接' : '取消断开'),
              ),
          ],
        ],
      ),
    ),
    if (_arcTool || (_edit3d && (_tool == _Tool.flick || _tool == _Tool.hold)))
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              _arcTool
                  ? '${_points.length} 个关键点 · ${_edit3d ? '滚动定位，再点空轨网格' : '点击空轨添加关键点'}'
                  : _tool == _Tool.hold
                  ? (_points.isEmpty ? '点选长按起点' : '点选长按终点')
                  : (_points.isEmpty ? '点选滑键起点' : '点选滑动方向'),
            ),
            if (_arcTool)
              TextButton(
                onPressed: enabled && _points.length >= 2
                    ? () => _arcPanel()
                    : null,
                child: Text(_editingArc.isEmpty ? '生成弧线' : '应用关键点'),
              ),
            if (_arcTool && _points.isNotEmpty)
              PopupMenuButton<int>(
                tooltip: '在画面中移动关键点',
                onSelected: (index) => setState(() {
                  _movingArcPoint = index;
                  _position.value = _points[index].time.toDouble().clamp(
                    _min,
                    _max,
                  );
                }),
                itemBuilder: (_) => [
                  for (var i = 0; i < _points.length; i++)
                    PopupMenuItem(
                      value: i,
                      child: Text('${_points[i].time} ms'),
                    ),
                ],
                child: Padding(
                  padding: const EdgeInsets.all(9),
                  child: Text(_movingArcPoint == null ? '移动关键点 ▾' : '点击目标位置'),
                ),
              ),
            if (_points.isNotEmpty)
              TextButton(
                onPressed: () => setState(_clearPoints),
                child: const Text('清除关键点'),
              ),
          ],
        ),
      ),
    Expanded(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          return Focus(
            focusNode: _editFocus,
            autofocus: true,
            onKeyEvent: (node, event) {
              if (!enabled || event is! KeyDownEvent) {
                return KeyEventResult.ignored;
              }
              final key = event.logicalKey;
              if (key == LogicalKeyboardKey.delete) {
                _noteOperation('delete');
              } else if (HardwareKeyboard.instance.isControlPressed) {
                if (key == LogicalKeyboardKey.keyZ) {
                  HardwareKeyboard.instance.isShiftPressed
                      ? _redoEdit()
                      : _undoEdit();
                } else if (key == LogicalKeyboardKey.keyY) {
                  _redoEdit();
                } else {
                  final action = {
                    LogicalKeyboardKey.keyC: 'copy',
                    LogicalKeyboardKey.keyX: 'cut',
                    LogicalKeyboardKey.keyV: 'paste',
                    LogicalKeyboardKey.keyM: 'mirror',
                    LogicalKeyboardKey.keyR: 'range',
                  }[key];
                  if (action == null) return KeyEventResult.ignored;
                  _noteOperation(action);
                }
              } else {
                return KeyEventResult.ignored;
              }
              return KeyEventResult.handled;
            },
            child: Listener(
              onPointerSignal: (event) {
                if (enabled &&
                    event is PointerScrollEvent &&
                    !(_didDrag && _pointers.isNotEmpty)) {
                  GestureBinding.instance.pointerSignalResolver.register(
                    event,
                    (_) => _scrollWheel(event),
                  );
                }
              },
              onPointerDown: (event) {
                if (_pointers.isEmpty) {
                  _hadTwoFingers = false;
                  _gestureScroll = 0;
                  _didDrag = false;
                  if (enabled && event.buttons == kPrimaryButton) {
                    _beginDrag(event, size);
                  }
                }
                _pointers[event.pointer] = event.localPosition;
                if (_pointers.length >= 2) {
                  _hadTwoFingers = true;
                  _endTouchPair();
                  _pairOrigin =
                      _pointers.length == 2 &&
                          event.kind == PointerDeviceKind.touch
                      ? (_pointers.values.first, _pointers.values.last)
                      : null;
                  _pairGesture = null;
                  _pairZoom = _zoom;
                  _pairPan = _gestureScroll = 0;
                  setState(_clearDrag);
                }
              },
              onPointerMove: (event) {
                final previous = _pointers[event.pointer];
                if (previous == null) return;
                _pointers[event.pointer] = event.localPosition;
                if (enabled &&
                    _pointers.length == 2 &&
                    event.kind == PointerDeviceKind.touch) {
                  _moveTouchPair();
                } else if (enabled && !_hadTwoFingers) {
                  _moveDrag(event, size);
                }
              },
              onPointerUp: (event) {
                if (enabled && !_hadTwoFingers) _finishDrag(event, size);
                _pointers.remove(event.pointer);
                _endTouchPair();
              },
              onPointerCancel: (event) {
                _pointers.remove(event.pointer);
                _endTouchPair();
                if (_dragPointer == event.pointer) setState(_clearDrag);
              },
              onPointerPanZoomStart: (_) {
                _gestureScroll = 0;
                _trackpadZoom = _zoom;
                _trackpadGesture = null;
              },
              onPointerPanZoomUpdate: (event) {
                if (!enabled) return;
                if (_trackpadGesture == null) {
                  if ((event.scale - 1).abs() >= 0.015) {
                    _trackpadGesture = _EditorTouchGesture.zoom;
                  } else if (event.pan.dy.abs() >= 8) {
                    _trackpadGesture = _EditorTouchGesture.pan;
                    _scrollGrid(-event.pan.dy);
                    return;
                  }
                }
                if (_trackpadGesture == _EditorTouchGesture.zoom) {
                  _setZoom(_trackpadZoom * event.scale);
                } else if (_trackpadGesture == _EditorTouchGesture.pan) {
                  _scrollGrid(-event.panDelta.dy);
                }
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: enabled && !size.isEmpty
                    ? (event) {
                        if (_hadTwoFingers || _didDrag) return;
                        _editFocus.requestFocus();
                        if (_edit3d) {
                          _place3d(size, event.localPosition);
                          return;
                        }
                        _place(_flatGeometry(size), event.localPosition);
                      }
                    : null,
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: _edit3d
                        ? ChartPerspectivePainter(
                            _timeline,
                            _position,
                            _lookahead,
                            skin: _skin.value,
                            editing: true,
                            appearance: _appearance,
                            wall: _airTool,
                            arcTapWall: _arcTapTool,
                            keyframes: _showKeyframes ? _keyframeMarkers : null,
                            handles:
                                !_showKeyframes ||
                                    _keyframeDisplay == _KeyframeDisplay.taps ||
                                    _tool == _Tool.hold
                                ? const []
                                : _points.toList(),
                            visibility: _visibility,
                            snapPoint: _snapPoint,
                            activeGroup: _activeGroup,
                            laneMode: _laneMode,
                          )
                        : ChartTimelinePainter(
                            _timeline,
                            _position,
                            _lookahead,
                            appearance: _appearance,
                            visibility: _visibility,
                            snapPoint: _strokeSnaps(
                              _flatGeometry(size),
                            ).$2?.point,
                            dragPath: _strokePath(size),
                            handles: _arcTool ? _points.toList() : const [],
                            skin: _skin.value,
                            laneMode: _laneMode,
                          ),
                    size: Size.infinite,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    ),
    if (_selected case final event?)
      ListTile(
        dense: true,
        title: Text(
          _selectedArcTap != null
              ? '空键'
              : event.command.isEmpty
              ? '地键'
              : event.command,
        ),
        subtitle: Text(
          '${_selectedArcTap ?? event.start} ms · ${event.group == 0 ? '主轨' : '分组 ${event.group}'}',
        ),
        trailing: Wrap(
          children: [
            if (_selectedArcTap == null && event.isSustain && !event.noInput)
              TextButton(
                onPressed: enabled ? () => _editSustainJudgements(event) : null,
                child: Text(
                  event.sustainJudgements == null
                      ? '持续判定'
                      : '判定点 ${event.sustainJudgements!.length}',
                ),
              ),
            if (event.kind == AffKind.arc &&
                _selectedArcTap == null &&
                !_isStandaloneSky(event))
              TextButton(
                onPressed: enabled ? () => _arcPanel(event: event) : null,
                child: const Text('关键点'),
              ),
            if (event.kind == AffKind.arc &&
                event.arcTaps.isEmpty &&
                !_isStandaloneSky(event))
              IconButton(
                tooltip: '在 3D 中编辑关键点',
                onPressed: enabled ? () => _editArcInScene(event) : null,
                icon: const Icon(Icons.control_camera),
              ),
            IconButton(
              onPressed: enabled ? () => _editEvent(event: event) : null,
              tooltip: '编辑或删除',
              icon: const Icon(Icons.edit_outlined),
            ),
          ],
        ),
      ),
    if (_edit3d)
      ValueListenableBuilder<double>(
        valueListenable: _position,
        builder: (context, time, _) => Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              tooltip: '上一个空键判定位置',
              onPressed: enabled ? () => _seekSkyTap(forward: false) : null,
              icon: const Icon(Icons.navigate_before),
            ),
            const Text('定位空键'),
            IconButton(
              tooltip: '下一个空键判定位置',
              onPressed: enabled ? () => _seekSkyTap(forward: true) : null,
              icon: const Icon(Icons.navigate_next),
            ),
          ],
        ),
      ),
    ValueListenableBuilder<double>(
      valueListenable: _position,
      builder: (context, time, _) => Row(
        children: [
          IconButton(
            tooltip: '缩小时间轴',
            icon: const Icon(Icons.zoom_out),
            onPressed: enabled && _zoom > _minZoom
                ? () => _setZoom(_zoom / 1.25)
                : null,
          ),
          IconButton(
            tooltip: '放大时间轴',
            icon: const Icon(Icons.zoom_in),
            onPressed: enabled && _zoom < _maxZoom
                ? () => _setZoom(_zoom * 1.25)
                : null,
          ),
          Tooltip(
            message: '设置铺面缩放',
            child: TextButton(
              onPressed: enabled ? _editZoom : null,
              child: Text('${_zoom.toStringAsFixed(2)}×'),
            ),
          ),
          Expanded(
            child: Slider(
              min: _min,
              max: _max,
              value: time.clamp(_min, _max),
              onChanged: enabled ? (value) => _position.value = value : null,
            ),
          ),
          TextButton(
            onPressed: enabled ? _jump : null,
            child: Text('${(time / 1000).toStringAsFixed(3)} s'),
          ),
        ],
      ),
    ),
  ];

  Future<void> _jump() async {
    final result = await showDialog<double>(
      context: context,
      builder: (_) => _EventDialog(
        (_position.value / 1000).toStringAsFixed(3),
        numberLabel: '跳转到时间（秒）',
      ),
    );
    if (mounted && result != null && result.isFinite) {
      _position.value = (result * 1000).clamp(_min, _max);
    }
  }

  void _seekSkyTap({required bool forward}) {
    final cursor = _position.value;
    int? closest;
    for (final note in _timeline.notes.where(
      (note) => note.kind == AffKind.arc,
    )) {
      for (final time in [
        if (note.variableArcTap) note.start,
        ...note.arcTaps,
      ]) {
        if (forward ? time <= cursor + 1 : time >= cursor - 1) continue;
        if (closest == null ||
            (time - cursor).abs() < (closest - cursor).abs()) {
          closest = time;
        }
      }
    }
    if (closest != null) _position.value = closest.toDouble().clamp(_min, _max);
  }
}

class _SustainJudgementDialog extends StatefulWidget {
  const _SustainJudgementDialog({
    required this.note,
    required this.automatic,
    required this.cursor,
  });

  final AffEvent note;
  final List<int> automatic;
  final int cursor;

  @override
  State<_SustainJudgementDialog> createState() =>
      _SustainJudgementDialogState();
}

class _SustainJudgementDialogState extends State<_SustainJudgementDialog> {
  late bool _automatic = widget.note.sustainJudgements == null;
  late final _points = (widget.note.sustainJudgements ?? widget.automatic)
      .toSet();
  late final _time = TextEditingController(
    text: '${widget.cursor.clamp(widget.note.start, widget.note.end)}',
  );
  String? _error;

  void _togglePoint(int at) => setState(() {
    if (!_points.add(at)) _points.remove(at);
  });

  void _addPoint() {
    final at = int.tryParse(_time.text.trim());
    setState(() {
      if (at == null || at < widget.note.start || at > widget.note.end) {
        _error = '请输入 ${widget.note.start}–${widget.note.end} ms 内的整数';
      } else {
        _points.add(at);
        _error = null;
      }
    });
  }

  @override
  void dispose() {
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final points = _points.toList()..sort();
    return AlertDialog(
      title: const Text('持续判定点'),
      scrollable: true,
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SwitchListTile(
              title: const Text('按节拍自动判定'),
              value: _automatic,
              onChanged: (value) => setState(() => _automatic = value),
            ),
            if (!_automatic) ...[
              const Text('只在勾选的时刻计入物量。其他位置可作为造型。'),
              Wrap(
                spacing: 8,
                children: [
                  for (final (at, label) in [
                    (widget.note.start, '起点'),
                    (widget.note.end, '终点'),
                  ])
                    FilterChip(
                      label: Text('$label $at ms'),
                      selected: _points.contains(at),
                      onSelected: (_) => _togglePoint(at),
                    ),
                ],
              ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _time,
                      keyboardType: const TextInputType.numberWithOptions(
                        signed: true,
                      ),
                      decoration: InputDecoration(
                        labelText: '判定点时间（毫秒）',
                        errorText: _error,
                      ),
                      onSubmitted: (_) => _addPoint(),
                    ),
                  ),
                  IconButton(
                    tooltip: '添加判定点',
                    onPressed: _addPoint,
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
              SizedBox(
                height: 152,
                child: ListView.builder(
                  itemCount: points.length,
                  itemBuilder: (_, index) => ListTile(
                    dense: true,
                    title: Text('${points[index]} ms'),
                    trailing: IconButton(
                      tooltip: '移除判定点',
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: () => _togglePoint(points[index]),
                    ),
                  ),
                ),
              ),
              TextButton(
                onPressed: points.isEmpty
                    ? null
                    : () => setState(_points.clear),
                child: const Text('清空判定点'),
              ),
              const Text('逐点设置保存在 AFF 标头，并在本软件试玩中生效。'),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, (
            points: _automatic ? null : (_points.toList()..sort()),
          )),
          child: const Text('应用'),
        ),
      ],
    );
  }
}

class _EventDialog extends StatefulWidget {
  const _EventDialog(
    this.initial, {
    this.canDelete = false,
    this.numberLabel,
    this.numberRange,
    this.integerOnly = false,
  });
  final String initial;
  final String? numberLabel;
  final (double, double)? numberRange;
  final bool canDelete, integerOnly;

  @override
  State<_EventDialog> createState() => _EventDialogState();
}

class _EventDialogState extends State<_EventDialog> {
  late final _controller = TextEditingController(text: widget.initial);
  String? _error;

  void _apply() {
    final text = _controller.text.trim();
    if (widget.numberLabel != null) {
      final number = widget.integerOnly
          ? int.tryParse(text)?.toDouble()
          : double.tryParse(text);
      if (number != null &&
          number.isFinite &&
          (!widget.integerOnly || number.abs() <= 0x7fffffff)) {
        if (widget.numberRange case (
          final lower,
          final upper,
        ) when number < lower || number > upper) {
          setState(() => _error = '请输入 $lower 到 $upper 之间的数值');
          return;
        }
        Navigator.pop(context, number);
        return;
      }
      setState(() => _error = widget.integerOnly ? '请输入有效的毫秒整数' : '请输入有效数值');
      return;
    }
    final chart = AffChart.parse('${AffChart.blank}$text');
    if (chart.errors.isEmpty &&
        chart.events.length == 2 &&
        chart.events.last.group == 0 &&
        chart.events.last.sourceEnd == chart.source.length) {
      Navigator.pop(context, text);
    } else {
      setState(() => _error = chart.errors.firstOrNull ?? '请输入一条完整的 AFF 指令');
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.numberLabel ?? '编辑 AFF 事件'),
    content: TextField(
      controller: _controller,
      autofocus: true,
      maxLines: widget.numberLabel != null ? 1 : 3,
      autocorrect: false,
      enableSuggestions: false,
      smartDashesType: SmartDashesType.disabled,
      smartQuotesType: SmartQuotesType.disabled,
      keyboardType: widget.numberLabel != null
          ? TextInputType.numberWithOptions(
              signed: true,
              decimal: !widget.integerOnly,
            )
          : TextInputType.multiline,
      decoration: InputDecoration(errorText: _error, errorMaxLines: 3),
    ),
    actions: [
      if (widget.canDelete)
        TextButton(
          onPressed: () => Navigator.pop(context, ''),
          child: const Text('删除'),
        ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _apply, child: const Text('应用')),
    ],
  );
}
