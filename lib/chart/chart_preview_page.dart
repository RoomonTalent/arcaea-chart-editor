import 'dart:async';
import 'dart:developer' show Timeline;
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show ValueListenable, visibleForTesting;
import 'package:flutter/gestures.dart' show PointerDeviceKind, kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'aff_chart.dart';
import 'chart_appearance.dart';
import 'chart_beat_grid.dart';
import 'chart_delay_calibration.dart';
import 'chart_feedback.dart';
import 'chart_feedback_editor.dart';
import 'chart_hit_regions.dart';
import 'chart_hit_region_editor.dart';
import 'chart_perspective.dart';
import 'chart_playback_view.dart';
import 'chart_playback_view_editor.dart';
import 'chart_practice_overlay.dart';
import 'chart_practice_segment.dart';
import 'chart_skin.dart';
import 'chart_timeline.dart';
import 'chart_volume.dart';

const _maxPointerDelay = 125000;
const _pointerDeliveryGrace = _maxPointerDelay / 1000 * 1.15;
const _arcOwnershipGrace = 500;
const _arcJunctionGrace = 60.0;
const _holdLeadIn = 100.0;
const _arcJunctionDistance = .03;

class ChartPreviewPage extends StatefulWidget {
  const ChartPreviewPage({
    super.key,
    required this.chart,
    required this.timeline,
    required this.practice,
    required this.initial,
    this.audio,
    this.skin,
    this.laneMode = ChartLaneMode.automatic,
    this.onLaneModeChanged,
    this.onAppearanceChanged,
    this.debugElapsedMilliseconds,
  });

  final AffChart chart;
  final ChartTimeline timeline;
  final bool practice;
  final double initial;
  final Future<Map<String, String>?> Function()? audio;
  final ValueListenable<ChartSkin>? skin;
  final ChartLaneMode laneMode;
  final ValueChanged<ChartLaneMode>? onLaneModeChanged;
  final ValueChanged<ChartAppearance>? onAppearanceChanged;
  @visibleForTesting
  final double Function()? debugElapsedMilliseconds;

  @override
  State<ChartPreviewPage> createState() => _ChartPreviewPageState();
}

class _ChartPreviewPageState extends State<ChartPreviewPage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const _audio = MethodChannel('arcaea_manager/chart_audio');
  static const _windowChannel = MethodChannel('arcaea_manager/chart_window');
  static const _transitionKey = 'chart_practice_transition';
  static const _speedKey = 'chart_preview_scroll_speed';
  static const _jumpKey = 'chart_preview_jump_seconds';
  static const _delayKey = 'chart_preview_delay_ms';
  static const _inputDelayKey = 'chart_practice_input_delay_ms';
  static const _overlayKey = 'chart_preview_overlay';
  static const _viewKey = 'chart_playback_view';
  static const _hitAreasKey = 'chart_practice_hit_areas';
  static const _timingWindowsKey = 'chart_practice_timing_windows';
  static const _feedbackKey = 'chart_practice_feedback';
  static const _maxTargets = 100000;

  final _position = ValueNotifier(0.0);
  final _speedInput = TextEditingController();
  final _controlsPosition = ValueNotifier(0.0);
  final _score = ValueNotifier(0);
  final _results = PracticeJudgements();
  final _clock = Stopwatch();
  final _touches = <int, Offset>{};
  final _inputChangedAt = <Object, double>{};
  final _pressClaims =
      <Object, ({double inputAt, int targetAt, AffEvent? hold})>{};
  final _origins = <int, Offset>{};
  final _touchPresses =
      <({int pointer, Offset point, double time, double rawTime})>[];
  final _airOwners = <int, _Target>{};
  final _arcRegrabAt = <AffEvent, double>{};
  final _checkpointInputs = <int, Map<Object, _Target>>{};
  final _snakeInputs = <int, Map<Object, _Target>>{};
  final _keyboard = <LogicalKeyboardKey, double>{};
  final _practiceFocus = FocusNode();
  final _targets = <_Target>[];
  final _judgement = ChartJudgement();
  final _effectGrids = <int, ChartBeatGrid>{};
  double? _lastHoldSample;
  final _gestureFingers = <int, Offset>{};
  int _gestureStart = 0, _fingerCount = 0;
  bool _validGesture = false;
  int? _lastTwoFingerTap;
  Offset? _lastTapCenter;
  Offset _tapSum = Offset.zero;
  late ChartLaneMode _laneMode = widget.laneMode;
  late final Ticker _ticker;
  late final _shutters = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 720),
  );
  double _anchor = 0, _min = 0, _max = 1000;
  double _inputFloor = 0;
  double _clockRate = 1;
  double? _seekDraft;
  int _duration = 0, _sampledAt = 0, _next = 0;
  int _playbackSession = 0;
  int? _samplingSession;
  bool _audioEnded = false;
  bool _usingAudio = false, _busy = true, _playing = false;
  bool _foreground = true;
  bool _perspective = true;
  late bool _practice = widget.practice;
  bool _practiceStarted = false;
  bool _showTransition = true, _transitioning = false;
  double? _leadInEnd;
  double? _startupAt;
  double _startupRemaining = 3000;
  ChartPracticeSegment? _selectedSegment, _activeSegment;
  List<int> _density = const [];
  bool _overlay = false;
  ChartAppearance _appearance = defaultChartAppearance;
  ChartPlaybackView _playbackView = defaultChartPlaybackView;
  Map<bool, Map<ChartHitKind, ChartHitArea>> _hitProfiles = const {};
  Map<bool, Map<PracticeKey, PracticeWindows>> _timeProfiles = const {};
  Map<ChartHitKind, ChartHitArea> get _hitAreas =>
      _hitProfiles[_perspective] ?? const {};
  Map<PracticeKey, PracticeWindows> get _timingWindows =>
      _timeProfiles[_perspective] ?? const {};
  double _candidateWindow = PracticeGrade.inputWindow;
  double _latestCapture = PracticeGrade.inputWindow;
  double _lastDeadline = double.negativeInfinity;
  double _volume = 1;
  double? _loopStart, _loopEnd;
  double _speed = 1;
  double _frozenAt = 0;
  double _jumpSeconds = 5;
  int _delay = 0;
  int _inputDelay = 0;
  SharedPreferences? _preferences;
  String? _status;
  FeedbackSettings _feedback = const FeedbackSettings();
  Size _size = Size.zero;

  int get _offset => widget.chart.audioOffset + _delay;
  bool get _flatWide =>
      _laneMode.expansion(widget.timeline, _position.value) > 0;
  double get _lookahead => _speed == 0
      ? 2100
      // Keep the visible depth representable when added to AFF timestamps.
      : (2100 / _speed.abs()).clamp(1e-4, 1e12);
  bool get _supportsAudio => Platform.isWindows || Platform.isAndroid;
  double get _elapsed => _clock.isRunning
      ? widget.debugElapsedMilliseconds?.call() ??
            _clock.elapsedMicroseconds / 1000
      : 0;
  double _timeAt(double elapsed) => _anchor + elapsed * _clockRate;
  double get _now => _timeAt(_elapsed);
  double get _playEnd => _activeSegment?.end ?? _max;
  double get _inputEnd =>
      _activeSegment?.end ??
      (_practice && _next < _targets.length
          ? math.max(_max, _lastDeadline + _inputDelay + _pointerDeliveryGrace)
          : _max);
  double get _inputNow => _now.clamp(_min, _inputEnd);
  bool get _canJudge =>
      _practice && _playing && _leadInEnd == null && _startupAt == null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ticker = createTicker(_tick);
    _position.addListener(_updateControls);
    _prepare();
  }

  void _updateControls() {
    final time = _position.value;
    if (!_playing ||
        time < _controlsPosition.value ||
        time - _controlsPosition.value >= 50 ||
        time >= _max) {
      _controlsPosition.value = time;
    }
  }

  void _updateScore() => _score.value++;

  Future<void> _prepare() async {
    try {
      _preferences = await SharedPreferences.getInstance();
      _showTransition = _preferences?.getBool(_transitionKey) ?? true;
      final speed = _preferences?.getDouble(_speedKey) ?? 1;
      _speed = speed.isFinite ? speed : 1;
      _delay = (_preferences?.getInt(_delayKey) ?? 0).clamp(-500, 500);
      _inputDelay = (_preferences?.getInt(_inputDelayKey) ?? 0).clamp(
        -500,
        500,
      );
      final jump = _preferences?.getDouble(_jumpKey) ?? 5.0;
      if (jump.isFinite && jump >= 0.1 && jump <= 3600) _jumpSeconds = jump;
      _volume = savedChartVolume(_preferences);
      _overlay = _preferences?.getBool(_overlayKey) ?? false;
      _playbackView = decodeChartPlaybackView(
        _preferences?.getString(_viewKey),
      );
      _hitProfiles = {
        for (final mode in [false, true])
          mode: decodeChartHitAreas(_profilePreference(_hitAreasKey, mode)),
      };
      _timeProfiles = {
        for (final mode in [false, true])
          mode: decodePracticeWindows(
            _profilePreference(_timingWindowsKey, mode),
          ),
      };
      _appearance = savedChartAppearance(_preferences);
      _feedback = FeedbackSettings.decode(
        _preferences?.getString(_feedbackKey),
      );
    } catch (_) {
      // A playback session also works without persisted settings.
    }
    if (!mounted) return;
    _min = math.min(widget.chart.firstTime, -_offset).toDouble();
    _max = math.max(1000, widget.chart.lastTime + 600).toDouble();
    try {
      if (_supportsAudio && widget.audio != null) {
        final source = await widget.audio?.call();
        if (!mounted) return;
        if (source != null) {
          _duration = (await _audio.invokeMethod<int>('open', source))!;
          _usingAudio = _duration > 0;
          if (!mounted) return;
          if (_usingAudio) unawaited(_applyVolume());
        }
      }
      if (_usingAudio) {
        _min = -_offset.toDouble();
        _max = _duration - _offset.toDouble();
      } else {
        _status = '未选择可用音频 · 静音模式';
      }
    } catch (_) {
      if (!mounted) return;
      _status = '音频无法打开 · 静音模式';
    }
    _position.value = widget.initial.clamp(_min, _max);
    _frozenAt = _position.value;
    _anchor = _position.value;
    _buildPracticeTargets();
    if (mounted) setState(() => _busy = false);
  }

  void _buildPracticeTargets() {
    if (!_practice) return;
    final segment = _activeSegment;
    final density = List<int>.filled(96, 0);
    final duration = math.max(1.0, _max - _min);
    Iterable<_Target> valid(ChartPracticeSegment? range) =>
        _practiceTargets(range)
            .where(
              (target) => _laneMode.showsAt(
                widget.timeline,
                target.note,
                target.time.toDouble(),
              ),
            )
            .take(_maxTargets + 1);
    final all = valid(null).toList();
    for (final target in all) {
      final index = ((target.time - _min) * density.length / duration)
          .floor()
          .clamp(0, density.length - 1);
      density[index]++;
    }
    _density = density;
    _targets
      ..clear()
      ..addAll(segment == null ? all : valid(segment));
    if (_targets.length > _maxTargets) {
      _targets.clear();
      _status = '谱面判定点过多 · 本次仅播放预览';
    } else {
      _targets.sort((a, b) => a.time.compareTo(b.time));
    }
    _applyTimingWindows();
    _resetJudgement(_position.value);
  }

  void _applyTimingWindows() {
    _candidateWindow = PracticeGrade.inputWindow;
    _latestCapture = PracticeGrade.inputWindow;
    _lastDeadline = double.negativeInfinity;
    for (final target in _targets) {
      target.customTiming = _timingWindows[_keyType(target)];
      _candidateWindow = math.max(_candidateWindow, target.earlyWindow);
      _latestCapture = math.max(_latestCapture, target.lateWindow);
      _lastDeadline = math.max(_lastDeadline, target.deadline);
    }
  }

  Iterable<_Target> _practiceTargets(ChartPracticeSegment? segment) sync* {
    final first = segment?.start ?? _min;
    final last = segment?.end ?? _max;
    bool includes(int time) =>
        first <= time && (segment == null ? time <= last : time < last);
    for (final note in widget.timeline.notes) {
      if (note.noInput ||
          !_laneMode.shows(note) ||
          note.designant ||
          note.lastTime < first ||
          note.firstTime > last ||
          (segment != null && !segment.shows(note))) {
        continue;
      }
      switch (note.kind) {
        case AffKind.tap:
          if (includes(note.start)) {
            yield _Target(note, note.start, note.laneX, false);
          }
        case AffKind.hold:
          if ((note.sustainJudgements?.contains(note.start) ??
                  (note.end == note.start)) &&
              includes(note.start)) {
            yield _Target(note, note.start, note.laneX, false, sustained: true);
          }
          for (final (time: t, :early) in _sustainCheckpoints(
            note,
            first,
            last,
          )) {
            if (t == note.start || !includes(t)) continue;
            yield _Target(
              note,
              t,
              note.laneX,
              false,
              sustained: true,
              autoEarly: early,
            );
          }
        case AffKind.arc:
          if (note.variableArcTap && includes(note.start)) {
            final first = note.arcPoint(0), last = note.arcPoint(1);
            yield _Target(
              note,
              note.start,
              first.x,
              true,
              height: first.height,
              tip: last,
            );
          } else if (!note.trace && note.end > note.start) {
            for (final (time: t, :early) in _sustainCheckpoints(
              note,
              first,
              last,
            )) {
              if (!includes(t)) continue;
              final point = note.point(t.toDouble());
              yield _Target(
                note,
                t,
                point.x,
                true,
                sustained: true,
                height: point.height,
                autoEarly: early,
              );
            }
          }
          for (final t in note.arcTaps) {
            if (includes(t)) {
              final point = note.point(t.toDouble());
              yield _Target(
                note,
                t,
                point.x,
                true,
                height: point.height,
                arcTap: t,
              );
            }
          }
        case AffKind.flick:
          if (!includes(note.start)) continue;
          final point = note.point(note.start.toDouble());
          yield _Target(
            note,
            note.start,
            point.x,
            true,
            height: point.height,
            direction: Offset(note.number(3), note.number(4)),
          );
        case AffKind.timing:
        case AffKind.camera:
        case AffKind.scene:
        case AffKind.other:
          break;
      }
    }
  }

  Iterable<({int time, double? early})> _sustainCheckpoints(
    AffEvent note,
    double first,
    double last,
  ) =>
      note.sustainJudgements
          ?.where((time) => time >= first && time <= last)
          .map((time) => (time: time, early: null)) ??
      widget.timeline.sustainTicks(note, minimum: first, maximum: last);

  void _resetJudgement(double time) {
    for (final target in _targets) {
      target.done = false;
      target.judgementIndex = null;
    }
    _next = 0;
    final inputTime = compensatedInputTime(time, _inputDelay);
    for (final target in _targets) {
      if (target.time >= time) break;
      target.done = target.deadline < inputTime;
    }
    _advanceTargets();
    _results.clear();
    _updateScore();
    _judgement.clear();
    _checkpointInputs.clear();
    _snakeInputs.clear();
    _resetHoldTracking();
    _touches.clear();
    _origins.clear();
    _keyboard.clear();
  }

  Future<void> _toggle() => _change(() async {
    if (_playing) {
      await _pause();
      return;
    }
    final atEnd = _position.value >= _max - 5;
    if (!_practice) {
      if (atEnd) await _seek(_min);
      if (mounted) await _start();
    } else if (_selectedSegment != null) {
      await _beginPractice(restart: true);
    } else if (_activeSegment != null) {
      await _beginPractice(restart: atEnd);
    } else if (_startupAt case final start?) {
      await _preparePracticeStart(start, duration: _startupRemaining);
    } else if (_practiceStarted && !atEnd) {
      await _continuePractice();
    } else {
      await _beginPractice(restart: atEnd);
    }
  });

  Future<void> _setImmersive(bool enabled) async {
    if (!Platform.isAndroid) return;
    try {
      await _windowChannel.invokeMethod<void>('immersive', enabled);
    } on MissingPluginException {
      // The playfield still fills the Flutter viewport.
    } on PlatformException {
      // Keep the practice session usable if system bars cannot be hidden.
    }
  }

  Future<void> _beginPractice({bool restart = false}) async {
    setState(() {
      _practiceStarted = true;
      _transitioning = _showTransition;
    });
    await _setImmersive(true);
    if (!mounted) return;
    _practiceFocus.requestFocus();
    try {
      if (_transitioning) {
        _shutters.value = 0;
        if (restart) {
          await _shutters.animateTo(.45).orCancel;
        }
      }
      final segment = _selectedSegment;
      final changed = _activeSegment != segment;
      _activeSegment = segment;
      if (segment != null || restart || changed) {
        await _seek(segment?.start ?? (restart ? _min : _position.value));
        if (!mounted) return;
        _buildPracticeTargets();
      }
      if (!mounted) return;
      if (_transitioning) await _shutters.forward().orCancel;
      if (mounted && _foreground) await _preparePracticeStart(_position.value);
    } on TickerCanceled {
      return;
    } finally {
      if (mounted) setState(() => _transitioning = false);
    }
  }

  Future<void> _continuePractice() async {
    final resumeAt = _leadInEnd ?? _position.value;
    final start = math.max(_min, resumeAt - 3000);
    setState(() {
      _leadInEnd = start < resumeAt ? resumeAt : null;
      _anchor = start;
      _position.value = start;
      _judgement.hitEffects.clear();
    });
    _practiceFocus.requestFocus();
    await _setImmersive(true);
    if (mounted) await _start();
  }

  Future<void> _restartPractice() =>
      _change(() => _beginPractice(restart: true));

  Future<void> _preparePracticeStart(
    double start, {
    double duration = 3000,
  }) async {
    if (_usingAudio) {
      final actual = await _audio.invokeMethod<int>('seek', {
        'position': (start + _offset).round(),
      });
      if (_activeSegment == null) {
        start = (actual! - _offset).clamp(_min, _max).toDouble();
      }
    }
    if (!mounted) return;
    _startupAt = start;
    _startupRemaining = duration;
    _position.value = start - duration;
    if (!_foreground) return;
    _playing = true;
    _ticker.start();
  }

  Future<void> _switchPracticeMode() => _change(() async {
    final wasPlaying = _playing;
    await _pause();
    if (!mounted) return;
    final leaveImmersive = _practiceStarted;
    setState(() {
      _practice = !_practice;
      _practiceStarted = false;
      _leadInEnd = null;
      _startupAt = null;
      _resetPreviewGesture();
      if (_practice) {
        _buildPracticeTargets();
      } else {
        _activeSegment = null;
        _resetJudgement(_position.value);
        _loopStart = _loopEnd = null;
      }
    });
    if (leaveImmersive) await _setImmersive(false);
    if (!mounted || !wasPlaying) return;
    if (_practice) {
      await _beginPractice();
    } else {
      await _start();
    }
  });

  Future<void> _start({bool audioReady = false}) async {
    var position = _position.value;
    if (_usingAudio) {
      if (!audioReady) {
        final actual = await _audio.invokeMethod<int>('seek', {
          'position': (position + _offset).round(),
        });
        position = (actual! - _offset).clamp(_min, _max).toDouble();
      }
      if (!mounted) return;
      if (!_foreground) {
        if (_playing) await _pause();
        return;
      }
      await _audio.invokeMethod<void>('play');
    }
    if (!mounted) return;
    if (!_foreground) {
      if (_playing) {
        await _pause();
      } else if (_usingAudio) {
        await _audio.invokeMethod<void>('pause');
      }
      return;
    }
    _startupAt = null;
    _anchor = position;
    _inputFloor = position;
    _position.value = position;
    _clockRate = 1;
    _playbackSession++;
    _audioEnded = false;
    _sampledAt = 0;
    _clock
      ..reset()
      ..start();
    _playing = true;
    _ticker.start();
  }

  Future<void> _pause() async {
    if (!_playing) return;
    final startup = _startupAt;
    final position = startup == null
        ? _now.clamp(_min, _playEnd)
        : _position.value;
    if (startup != null) _startupRemaining = math.max(0, startup - position);
    _playbackSession++;
    if (_canJudge) {
      _flushTouchPresses();
      _judgeHeld(_inputNow);
    }
    _playing = false;
    _ticker.stop();
    _clock
      ..stop()
      ..reset();
    _touches.clear();
    _origins.clear();
    _keyboard.clear();
    _resetHoldTracking();
    _anchor = position;
    _clockRate = 1;
    _position.value = position;
    _updateControls();
    if (_usingAudio) await _audio.invokeMethod<void>('pause');
  }

  Future<void> _seek(double time) async {
    final resume = _playing;
    final range = resume ? _activeSegment : null;
    if (resume) await _pause();
    if (mounted) {
      _leadInEnd = null;
      _startupAt = null;
      _anchor = time.clamp(range?.start ?? _min, range?.end ?? _max);
      _position.value = _anchor;
      _frozenAt = _anchor;
      _resetJudgement(_anchor);
      if (resume && _anchor < (range?.end ?? _max) - 5) await _start();
    }
  }

  Future<void> _change(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await operation();
    } catch (_) {
      if (!mounted) return;
      _usingAudio = false;
      await _pause();
      _status = '音频播放中断 · 可继续静音试玩';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _tick(Duration elapsed) {
    if (_startupAt case final start?) {
      final remaining = math.max(
        0.0,
        _startupRemaining - elapsed.inMicroseconds / 1000,
      );
      _position.value = start - remaining;
      if (remaining == 0 && !_busy) {
        _ticker.stop();
        _change(() => _start(audioReady: true));
      }
      return;
    }
    final clockTime = _now;
    final time = clockTime.clamp(_min, _playEnd);
    _position.value = time;
    _finishLeadIn(time);
    if (_canJudge) {
      _flushTouchPresses();
      _judgeHeld(clockTime.clamp(_min, _inputEnd));
    }
    if (_loopEnd case final end?
        when _activeSegment == null && time >= end && !_busy && _canJudge) {
      _change(() => _seek(_loopStart!));
      return;
    }
    // Give the audio backend time to finish when the chart clock leads.
    if (clockTime >= _inputEnd &&
        (_activeSegment != null ||
            !_usingAudio ||
            _audioEnded ||
            clockTime >= _max + 500)) {
      if (_practice) {
        for (final target in _targets.skip(_next)) {
          if (!target.done) _miss(target);
        }
        _next = _targets.length;
        _updateScore();
      }
      _change(() async {
        await _pause();
        if (mounted && _practice) await showPracticeResults(context, _results);
      });
    } else if (_usingAudio &&
        !_audioEnded &&
        !_busy &&
        _samplingSession != _playbackSession &&
        elapsed.inMilliseconds - _sampledAt >= 170) {
      _sampledAt = elapsed.inMilliseconds;
      _sampleAudio();
    }
  }

  void _finishLeadIn(double time) {
    if (_leadInEnd case final end? when time >= end) {
      _inputFloor = end;
      _resetHoldTracking();
      for (final input in [..._touches.keys, ..._keyboard.keys]) {
        _inputChangedAt[input] = end;
      }
      setState(() => _leadInEnd = null);
    }
  }

  Future<void> _sampleAudio() async {
    final session = _playbackSession;
    final requestedAt = _elapsed;
    _samplingSession = session;
    bool active() =>
        mounted &&
        _playing &&
        !_busy &&
        _usingAudio &&
        _playbackSession == session;
    try {
      final sample = (await _audio.invokeListMethod<Object>('position'))!;
      if (!active()) return;
      final elapsed = _elapsed;
      if (elapsed - requestedAt > 80) return;
      final sampledAt = (requestedAt + elapsed) / 2;
      final mediaPosition = sample[0] as int;
      final playing = sample[1] == true;
      _audioEnded = !playing && mediaPosition >= _duration - 20;
      final error = mediaPosition - _offset - _timeAt(sampledAt);
      final rate = playing && error.abs() > 12
          ? 1 + (error / 500).clamp(-0.15, 0.15)
          : 1.0;
      // Keep chart time continuous while changing the slope of the clock.
      _anchor = _timeAt(elapsed) - elapsed * rate;
      _clockRate = rate;
    } catch (_) {
      if (active()) {
        final elapsed = _elapsed;
        _anchor = _timeAt(elapsed) - elapsed;
        _clockRate = 1;
        setState(() {
          _usingAudio = false;
          _status = '音频播放中断 · 静音模式';
        });
      }
    } finally {
      if (_samplingSession == session) _samplingSession = null;
    }
  }

  _PracticeView _practiceView(double time) => (
    time: time,
    frames: <_Target, ChartHitFrame?>{},
    space: _perspective && !_size.isEmpty
        ? PerspectiveGeometry.forPlayback(
            _size,
            time,
            _lookahead,
            widget.timeline,
            _laneMode,
            view: _playbackView,
          )
        : null,
    flat: !_perspective && !_size.isEmpty
        ? TimelineGeometry(
            _size,
            time,
            _lookahead,
            wideLanes: _laneMode.expansion(widget.timeline, time) > 0,
            overlay: _overlay,
          )
        : null,
  );

  double? _distance(_Target target, Offset point, _PracticeView view) {
    if (!_laneMode.showsAt(widget.timeline, target.note, view.time)) {
      return null;
    }
    if (target.note.kind == AffKind.flick) {
      return _flickDistance(target, point, view);
    }
    final kind = switch (target.note.kind) {
      AffKind.hold => ChartHitKind.hold,
      AffKind.tap => ChartHitKind.tap,
      _ when target.sustained => ChartHitKind.arc,
      _ => ChartHitKind.sky,
    };
    final frame = view.frames.putIfAbsent(
      target,
      () => target.air
          ? ChartHitFrame.air(
              (x: target.x, height: target.height),
              skyTap: target.arcTap != null || target.tip != null,
              tip: target.tip,
              angles: widget.timeline.groupOptions[target.note.group],
              space: view.space,
              flat: view.flat,
            )
          : ChartHitFrame.ground(
              target.x,
              space: view.space,
              flat: view.flat,
              widening: _laneMode.expansion(widget.timeline, view.time),
              free:
                  target.note.groundPosition != null ||
                  target.note.inlineGroundPosition != null,
            ),
    );
    return frame?.distance(
      _hitAreas[kind] ?? ChartHitArea.defaults(kind),
      point,
    );
  }

  double? _flickDistance(_Target target, Offset point, _PracticeView view) {
    if (view.space case final g?) {
      final angles = widget.timeline.groupOptions[target.note.group];
      Offset project(double x) => g.baseHorizontal(
        g.projectAir(x, target.height, g.time, angles: angles),
      );
      const half = PerspectiveGeometry.flickHalfWidth;
      final axis = project(target.x + half) - project(target.x - half);
      final length = axis.distance;
      if (length < 1e-3) return null;
      final offset = g.baseHorizontal(point) - project(target.x);
      final x =
          (offset.dx * axis.dx + offset.dy * axis.dy) / (length * length / 2);
      final y =
          (offset.dy * axis.dx - offset.dx * axis.dy) /
          length /
          math.min(48, _size.height * .11);
      return x.abs() <= 1 && y.abs() <= 1 ? x * x + y * y : null;
    }
    final g = view.flat;
    if (g == null) return null;
    final x = (point.dx - g.x(target.x, airborne: true)) / (g.skySpan * .14);
    final y = (point.dy - g.judgement) / math.min(54, _size.height * .17);
    return x.abs() <= 1 && y.abs() <= 1 ? x * x + y * y : null;
  }

  Future<void> _applyVolume() async {
    try {
      await _audio.invokeMethod<void>('volume', {'gain': _volume});
    } on MissingPluginException {
      // The preview can also run without a native audio session.
    } on PlatformException {
      if (mounted && _usingAudio) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法调节当前音频的音量')));
      }
    }
  }

  void _setVolume(double gain) {
    setState(() => _volume = gain);
    if (_usingAudio) unawaited(_applyVolume());
  }

  Future<void> _volumeSettings() async {
    await showChartVolume(
      context,
      initial: _volume,
      onChanged: _setVolume,
      preferences: _preferences,
    );
  }

  Future<void> _appearanceSettings() async {
    final value = await showChartAppearance(
      context,
      initial: _appearance,
      preferences: _preferences,
    );
    if (!mounted || value == null) return;
    setState(() => _appearance = value);
    widget.onAppearanceChanged?.call(value);
    _practiceFocus.requestFocus();
  }

  void _setLoop() {
    final now = (_seekDraft ?? _position.value).clamp(_min, _max);
    setState(() {
      if (_loopEnd != null) {
        _loopStart = _loopEnd = null;
      } else if (_loopStart == null || now < _loopStart! + 250) {
        _loopStart = now;
      } else {
        _loopEnd = now;
      }
    });
  }

  Future<void> _previewSettings() async {
    double? speed = _speed;
    _speedInput.text = _speed.toString();
    var delay = _delay.toDouble();
    final settings = await showDialog<({double speed, int delay})>(
      context: context,
      builder: (_) {
        return StatefulBuilder(
          builder: (context, setDraft) => AlertDialog(
            title: const Text('预览流速与延迟'),
            scrollable: true,
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Slider(
                  value: (speed ?? _speed).clamp(-1.0, 10.0),
                  min: -1,
                  max: 10,
                  divisions: 110,
                  label:
                      '${(speed ?? _speed).clamp(-1.0, 10.0).toStringAsFixed(1)}×',
                  onChanged: (value) => setDraft(() {
                    speed = (value * 10).round() / 10;
                    _speedInput.text = speed.toString();
                  }),
                ),
                TextField(
                  controller: _speedInput,
                  keyboardType: const TextInputType.numberWithOptions(
                    signed: true,
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: '流速倍率',
                    suffixText: '×',
                    helperText: '负值倒流，0 停止滚动',
                    errorText: speed == null ? '请输入有限数值' : null,
                  ),
                  onChanged: (text) => setDraft(() {
                    final value = double.tryParse(text.trim());
                    speed = value?.isFinite == true ? value : null;
                  }),
                ),
                Text('音画校准  ${delay.round()} ms'),
                Slider(
                  value: delay,
                  min: -500,
                  max: 500,
                  divisions: 1000,
                  label: '${delay.round()} ms',
                  onChanged: (value) => setDraft(() => delay = value),
                ),
                const Text('正值让画面和试玩判定相对音乐延后。'),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => setDraft(() {
                  speed = 1;
                  _speedInput.text = '1.0';
                  delay = 0;
                }),
                child: const Text('重置'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: speed == null
                    ? null
                    : () => Navigator.pop(context, (
                        speed: speed!,
                        delay: delay.round(),
                      )),
                child: const Text('应用'),
              ),
            ],
          ),
        );
      },
    );
    if (settings == null || !mounted) return;
    setState(() {
      if (settings.speed == 0 && _speed != 0) _frozenAt = _position.value;
      _speed = settings.speed;
      _setAudioDelay(settings.delay);
    });
    try {
      await _preferences?.setDouble(_speedKey, _speed);
      await _preferences?.setInt(_delayKey, _delay);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('校准已应用到当前预览，保存偏好失败')));
      }
    }
  }

  void _setAudioDelay(int value) {
    final difference = _delay - value;
    _delay = value;
    if (!_usingAudio || difference == 0) return;
    _min = -_offset.toDouble();
    _max = _duration - _offset.toDouble();
    ChartPracticeSegment? clampSegment(ChartPracticeSegment? segment) {
      if (segment == null) return null;
      final start = segment.start.clamp(_min, _max);
      final end = segment.end.clamp(_min, _max);
      return start < end ? (start: start, end: end) : null;
    }

    _selectedSegment = clampSegment(_selectedSegment);
    _activeSegment = clampSegment(_activeSegment);
    _anchor += difference;
    _position.value = (_position.value + difference).clamp(_min, _max);
    _frozenAt = _position.value;
    if (_startupAt case final at?) {
      _startupAt = (at + difference).clamp(_min, _max);
      _position.value = _startupAt! - _startupRemaining;
    }
    _leadInEnd = null;
    _buildPracticeTargets();
    _loopStart = _loopEnd = null;
  }

  Future<void> _configureJump() async {
    var text = _jumpSeconds.toStringAsFixed(_jumpSeconds % 1 == 0 ? 0 : 2);
    final form = GlobalKey<FormState>();
    final value = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('自定义跳转步长'),
        content: Form(
          key: form,
          child: TextFormField(
            initialValue: text,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: '秒数',
              helperText: '0.1 到 3600 秒',
            ),
            onChanged: (value) => text = value,
            validator: (text) {
              final seconds = double.tryParse((text ?? '').trim());
              return seconds == null ||
                      !seconds.isFinite ||
                      seconds < 0.1 ||
                      seconds > 3600
                  ? '请输入范围内的秒数'
                  : null;
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState?.validate() == true) {
                Navigator.pop(context, double.parse(text.trim()));
              }
            },
            child: const Text('应用'),
          ),
        ],
      ),
    );
    if (!mounted || value == null) return;
    setState(() => _jumpSeconds = value);
    await _preferences?.setDouble(_jumpKey, value);
  }

  void _jumpBy(double seconds) {
    _practiceFocus.requestFocus();
    _change(() {
      final destination = (_position.value + seconds * 1000).clamp(_min, _max);
      setState(() {
        _seekDraft = null;
        if (_loopEnd != null &&
            (destination < _loopStart! || destination > _loopEnd!)) {
          _loopStart = _loopEnd = null;
        }
      });
      return _seek(destination);
    });
  }

  void _judgeHeld(double time) {
    final view = _touches.isEmpty && _keyboard.isEmpty
        ? null
        : _practiceView(time);
    _consumeHeldNotes(time, view: view);
    final settled = <_Settlement>[];
    if (view != null) {
      final inputTime = compensatedInputTime(time, _inputDelay);
      final chord = <_Target>[];
      for (var index = _next; index < _targets.length; index++) {
        final target = _targets[index];
        if (target.time > inputTime + _candidateWindow) break;
        if (!target.sustained ||
            target.done ||
            inputTime < target.inputStartsAt ||
            !_laneMode.showsAt(widget.timeline, target.note, time)) {
          continue;
        }
        if (chord.isNotEmpty && chord.first.time != target.time) {
          _judgeSustained(chord, view, settled);
          chord.clear();
        }
        chord.add(target);
      }
      if (chord.isNotEmpty) _judgeSustained(chord, view, settled);
    }
    for (var index = _next; index < _targets.length; index++) {
      final target = _targets[index];
      if (target.time > time) break;
      if (!target.done &&
          target.expiry + math.max(0, _inputDelay) < time &&
          (_touchPresses.isEmpty ||
              _touchPresses.first.time > target.deadline)) {
        settled.add((
          target: target,
          at: target.deadline,
          input: false,
          point: null,
        ));
      }
    }
    settled.sort((a, b) => a.at.compareTo(b.at));
    for (final item in settled) {
      if (item.input) {
        _hit(item.target, item.at, point: item.point);
      } else {
        _miss(item.target);
      }
    }
    final oldest =
        time -
        _latestCapture -
        _pointerDeliveryGrace -
        math.max(0, _inputDelay);
    for (final checkpoints in [_checkpointInputs, _snakeInputs]) {
      checkpoints.removeWhere((at, _) => at < oldest);
    }
    _advanceTargets();
    _arcRegrabAt.removeWhere(
      (_, resumeAt) =>
          resumeAt +
              _latestCapture +
              _pointerDeliveryGrace +
              math.max(0, _inputDelay) <
          time,
    );
    _updateHoldLeads(time, view);
    if (settled.isNotEmpty) _updateScore();
  }

  void _advanceTargets() {
    while (_next < _targets.length && _targets[_next].done) {
      _next++;
    }
  }

  void _judgeSustained(
    List<_Target> chord,
    _PracticeView view,
    List<_Settlement> settled,
  ) {
    _judgeSustainKind(
      chord.where((target) => !target.air),
      _checkpointInputs,
      view,
      settled,
    );
    _judgeSustainKind(
      chord.where((target) => target.air),
      _snakeInputs,
      view,
      settled,
    );
  }

  void _judgeSustainKind(
    Iterable<_Target> chord,
    Map<int, Map<Object, _Target>> checkpoints,
    _PracticeView view,
    List<_Settlement> settled,
  ) {
    if (chord.isEmpty) return;
    final time = chord.first.time;
    final previous = checkpoints[time] ?? const <Object, _Target>{};
    final assigned = _assignTargets(
      chord,
      view,
      previous: previous,
      checkpoint: true,
    );
    if (assigned.isNotEmpty) checkpoints[time] = assigned;
    for (final entry in assigned.entries) {
      if (previous[entry.key] == entry.value) continue;
      final target = entry.value;
      final at = _sustainInputTime(entry.key, target, view.time);
      final point = _touches[entry.key];
      if (!target.done) {
        target.done = true;
        settled.add((target: target, at: at, input: true, point: point));
      } else if (target.judgementIndex case final index?) {
        _results.reviseSustain(index, target.time - at, point);
      }
      if (entry.key case final int finger) {
        if (target.air) {
          _rememberArcContact(finger, target, view.time);
        }
      }
    }
  }

  double _sustainInputTime(Object input, _Target target, double chartTime) {
    final claimed = _pressClaims[input];
    final now = compensatedInputTime(chartTime, _inputDelay);
    if (_touchPresses.any((press) => press.pointer == input)) {
      return double.infinity;
    }
    if (!target.air && claimed != null) {
      final sameWindow =
          target.inputStartsAt <= claimed.inputAt &&
          claimed.inputAt <= target.deadline;
      final continued =
          claimed.hold != null &&
          (target.usesAutomaticTiming
              ? claimed.hold == target.note
              : claimed.inputAt < target.time && now >= target.time);
      if (!continued && (target.time == claimed.targetAt || sameWindow)) {
        return double.infinity;
      }
    }
    final changedAt = _inputChangedAt[input] ?? double.infinity;
    if (target.autoEarly != null) {
      // A contact can already be down when the judgement interval opens.
      // If a frame arrives late, only an unchanged contact can cover the deadline.
      final sample = math.min(now, target.deadline);
      return changedAt <= sample ? sample : double.infinity;
    }
    if (now < target.time) {
      return changedAt >= target.inputStartsAt ? changedAt : double.infinity;
    }
    return math.max(target.time.toDouble(), changedAt);
  }

  Map<Object, _Target> _assignTargets(
    Iterable<_Target> targets,
    _PracticeView view, {
    Map<Object, _Target> previous = const {},
    bool checkpoint = false,
    bool unusedPress = false,
  }) {
    final choices = <_Target, List<({Object input, double distance})>>{};
    // A later finger can take over a checkpoint while its original finger
    // is still following that checkpoint, without changing the score so far.
    final movable = {
      for (final entry in previous.entries)
        if (_inputChangedAt.containsKey(entry.key)) entry.key: entry.value,
    };
    for (final target in [...targets, ...movable.values]) {
      final inputs = <({Object input, double distance})>[];
      final now = compensatedInputTime(view.time, _inputDelay);
      double sample(Object input) =>
          checkpoint ? _sustainInputTime(input, target, view.time) : now;
      bool inWindow(double at) =>
          !checkpoint || (target.accepts(at) && at <= now);
      double delay(double at) => checkpoint ? (at - target.time).abs() : 0;
      final pastDeadline = checkpoint && now > target.deadline;

      for (final entry in _touches.entries) {
        if (unusedPress && _pressClaims.containsKey(entry.key)) continue;
        final canMove = movable.containsKey(entry.key);
        if (previous.containsKey(entry.key) && !canMove) continue;
        final at = sample(entry.key);
        if (!inWindow(at)) continue;
        final contact = checkpoint && target.air && target.autoEarly != null
            ? _arcTarget(target.note, at + _inputDelay)
            : target;
        final sampleView = pastDeadline
            ? _practiceView(at + _inputDelay)
            : view;
        final distance = _distance(contact, entry.value, sampleView);
        if (distance == null ||
            (target.air &&
                (!canMove || target.note.sustainJudgements == null) &&
                _holdsOtherArc(
                  entry.key,
                  target.note,
                  contact.time,
                  entry.value,
                  sampleView,
                  checkpointTime: checkpoint ? target.time : null,
                ))) {
          continue;
        }
        inputs.add((input: entry.key, distance: delay(at) + distance * .00001));
      }
      if (!target.air) {
        for (final entry in _keyboard.entries) {
          if (unusedPress && _pressClaims.containsKey(entry.key)) continue;
          final at = sample(entry.key);
          if (inWindow(at) &&
              (!previous.containsKey(entry.key) ||
                  movable.containsKey(entry.key)) &&
              (entry.value - target.note.standardLaneX).abs() < 0.02) {
            inputs.add((input: entry.key, distance: delay(at)));
          }
        }
      }
      if (inputs.isNotEmpty) {
        choices[target] = inputs;
      }
    }
    return _matchInputs(choices, previous);
  }

  Map<Object, _Target> _matchInputs(
    Map<_Target, List<({Object input, double distance})>> choices, [
    Map<Object, _Target> previous = const {},
  ]) {
    for (final inputs in choices.values) {
      inputs.sort((a, b) => a.distance.compareTo(b.distance));
    }
    // An overlapping touch can be reassigned to keep a more constrained touch
    // available. Every input and checkpoint participates at most once.
    final assigned = {...previous};
    bool assign(_Target target, Set<Object> used) {
      for (final choice in choices[target] ?? const []) {
        if (!used.add(choice.input)) continue;
        final previous = assigned[choice.input];
        if (previous == null || assign(previous, used)) {
          assigned[choice.input] = target;
          return true;
        }
      }
      return false;
    }

    final ordered = choices.keys.toList()
      ..sort((a, b) {
        final first = choices[a]!, second = choices[b]!;
        final options = first.length.compareTo(second.length);
        if (options != 0) return options;
        final distance = first.first.distance.compareTo(second.first.distance);
        return distance == 0
            ? a.note.sourceStart.compareTo(b.note.sourceStart)
            : distance;
      });
    final alreadyMatched = previous.values.toSet();
    for (final target in ordered) {
      if (alreadyMatched.contains(target)) continue;
      assign(target, <Object>{});
    }
    return assigned;
  }

  bool _holdsOtherArc(
    int finger,
    AffEvent note,
    num time,
    Offset point,
    _PracticeView view, {
    int? checkpointTime,
  }) {
    final owner = _airOwners[finger]?.note;
    if (note.kind == AffKind.arc &&
        note.isSustain &&
        note.sustainJudgements == null) {
      final resumeAt = _arcRegrabAt[note] ?? double.negativeInfinity;
      if (time < resumeAt ||
          (checkpointTime != null && checkpointTime + _inputDelay < resumeAt)) {
        return true;
      }
      final exchanging =
          owner != null && owner != note && _canExchangeArcs(owner, note, time);
      if (!exchanging) {
        final current = _arcTarget(note, time);
        for (final entry in _airOwners.entries) {
          final other = _touches[entry.key];
          if (entry.key != finger &&
              entry.value.note == note &&
              time - entry.value.time <= _arcOwnershipGrace &&
              other != null &&
              _distance(current, other, view) != null) {
            return true;
          }
        }
      }
      if (exchanging) return false;
    }
    if (owner == null ||
        owner == note ||
        time < owner.firstTime ||
        time >= owner.lastTime) {
      return false;
    }
    if (note.kind == AffKind.arc &&
        note.sustainJudgements == null &&
        owner.number(7) != note.number(7)) {
      return true;
    }
    return _distance(_arcTarget(owner, time), point, view) != null;
  }

  _Target _arcTarget(AffEvent note, num time) {
    final center = note.point(time.toDouble());
    return _Target(
      note,
      time.round(),
      center.x,
      true,
      height: center.height,
      sustained: true,
    );
  }

  void _rememberArcContact(int finger, _Target target, double time) {
    if (target.autoEarly == null) {
      _airOwners[finger] = target;
    } else if (target.note.start <= time && time < target.note.end) {
      _airOwners[finger] = _arcTarget(target.note, time);
    }
  }

  void _updateHoldLeads(double time, _PracticeView? view) {
    _judgement.earlyHolds.clear();
    if (view == null) return;
    final candidates = widget.timeline
        .visible(time, time + _holdLeadIn)
        .where(
          (note) =>
              note.kind == AffKind.hold &&
              note.isSustain &&
              !note.noInput &&
              note.start > time &&
              note.start <= time + _holdLeadIn &&
              (_activeSegment?.includes(note.start) ?? true) &&
              _laneMode.showsAt(widget.timeline, note, time),
        )
        .map((note) => _Target(note, note.start, note.laneX, false));
    _judgement.earlyHolds.addAll(
      _assignTargets(
        candidates,
        view,
        unusedPress: true,
      ).values.map((target) => target.note),
    );
  }

  bool _canExchangeArcs(AffEvent first, AffEvent second, num at) {
    if (first == second ||
        second.kind != AffKind.arc ||
        !second.isSustain ||
        second.noInput) {
      return false;
    }
    final overlapStart = math.max(first.start, second.start).toDouble();
    final overlapEnd = math.min(first.end, second.end).toDouble();
    Offset separation(double time) {
      final a = first.point(time), b = second.point(time);
      return Offset(a.x - b.x, a.height - b.height);
    }

    bool crosses(Offset a, Offset b) {
      var from = 0.0, to = 1.0;
      for (final (start, end) in [(a.dx, b.dx), (a.dy, b.dy)]) {
        final delta = end - start;
        if (delta == 0) {
          if (start.abs() > _arcJunctionDistance) return false;
          continue;
        }
        final low = (-_arcJunctionDistance - start) / delta;
        final high = (_arcJunctionDistance - start) / delta;
        from = math.max(from, math.min(low, high));
        to = math.min(to, math.max(low, high));
        if (from > to) return false;
      }
      return true;
    }

    if (overlapStart > overlapEnd) {
      final between = (overlapStart + overlapEnd) / 2;
      return overlapStart - overlapEnd <= 20 &&
          (at - between).abs() <= _arcJunctionGrace &&
          crosses(separation(between), separation(between));
    }
    final low = math.max(overlapStart, at.toDouble() - _arcJunctionGrace);
    final high = math.min(overlapEnd, at.toDouble() + _arcJunctionGrace);
    if (low > high) return false;
    // Test between samples as well, so even steep linear snakes can cross
    // entirely between rendered frames.
    final sections = first.arguments[4] == 's' && second.arguments[4] == 's'
        ? 1
        : 6;
    var previous = separation(low);
    for (var step = 1; step <= sections; step++) {
      final next = separation(low + (high - low) * step / sections);
      if (crosses(previous, next)) return true;
      previous = next;
    }
    return false;
  }

  bool _handoffArc(AffEvent note, double at) {
    if (_touches.isEmpty) return false;
    final view = _practiceView(at);
    final target = _arcTarget(note, at);
    int? next;
    var closest = double.infinity;
    for (final entry in _touches.entries) {
      final distance = _distance(target, entry.value, view);
      if (distance != null &&
          distance < closest &&
          !_holdsOtherArc(entry.key, note, at, entry.value, view)) {
        next = entry.key;
        closest = distance;
      }
    }
    if (next == null) return false;
    _airOwners[next] = target;
    return true;
  }

  void _resetHoldTracking() {
    _lastHoldSample = null;
    _airOwners.clear();
    _arcRegrabAt.clear();
    _inputChangedAt.clear();
    _pressClaims.clear();
    _touchPresses.clear();
    _judgement.earlyHolds.clear();
  }

  void _consumeHeldNotes(double time, {_PracticeView? view}) {
    final previous = _lastHoldSample;
    if (previous != null && time <= previous) return;
    _lastHoldSample = time;
    if (previous == null || (_touches.isEmpty && _keyboard.isEmpty)) return;
    final segment = _activeSegment;
    final sustained = widget.timeline
        .visible(previous, time)
        .where(
          (note) =>
              note.isSustain &&
              (segment == null || segment.showsBody(note)) &&
              (note.kind == AffKind.hold || _touches.isNotEmpty) &&
              note.start < time &&
              note.end > previous &&
              !note.noInput &&
              _laneMode.showsAt(widget.timeline, note, time),
        )
        .toList();
    if (sustained.isEmpty) return;
    final geometry = view ?? _practiceView(time);
    final parts = sustained.any((note) => note.isAir)
        ? ((time - previous) / 16).ceil().clamp(1, 64)
        : 1;
    final boundaries = <double>{
      previous,
      time,
      for (var i = 1; i < parts; i++) previous + (time - previous) * i / parts,
      for (final note in sustained) ...[
        if (note.start > previous) note.start.toDouble(),
        if (note.end < time) note.end.toDouble(),
      ],
    }.toList()..sort();
    for (var i = 1; i < boundaries.length; i++) {
      final start = boundaries[i - 1], end = boundaries[i];
      final at = (start + (end - start) / 2).round();
      final active = sustained.where(
        (note) => note.start < end && note.end > start,
      );
      final ground = active
          .where((note) => !note.isAir)
          .map((note) => _Target(note, at, note.laneX, false));
      final arcs = active.where((note) => note.isAir).map((note) {
        final point = note.point((start + end) / 2);
        return _Target(
          note,
          at,
          point.x,
          true,
          sustained: true,
          height: point.height,
        );
      });
      for (final entry in [
        ..._assignTargets(ground, geometry).entries,
        ..._assignTargets(arcs, geometry).entries,
      ]) {
        final target = entry.value;
        if (target.air &&
            target.note.sustainJudgements == null &&
            entry.key is int) {
          _airOwners[entry.key as int] = target;
        }
        _judgement.consumeSustain(target.note, start, end);
        _emitSustainEffects(target.note, start, end);
      }
    }
  }

  void _emitSustainEffects(AffEvent note, double from, double to) {
    final start = math.max(note.start.toDouble(), from);
    final end = math.min(note.end.toDouble(), to);
    final grid = _effectGrids.putIfAbsent(
      note.group,
      () => ChartBeatGrid(
        widget.timeline.groupTempos(note.group),
        subdivision: 32,
        bpmBase: 120,
      ),
    );
    final recent = math.max(start, _position.value - ChartJudgement.duration);
    for (
      var at = grid.next(recent, forward: true);
      at <= end;
      at = grid.next(at.toDouble(), forward: true)
    ) {
      final point = note.isAir
          ? note.point(at.toDouble())
          : (x: note.laneX, height: 0.0);
      _addHitEffect(
        at.toDouble(),
        point.x,
        point.height,
        air: note.isAir,
        group: note.group,
      );
    }
  }

  void _press(PointerDownEvent event) {
    if (!_practice && event.kind == PointerDeviceKind.touch) {
      final now = event.timeStamp.inMilliseconds;
      if (_gestureFingers.isEmpty) {
        _gestureStart = now;
        _fingerCount = 0;
        _tapSum = Offset.zero;
        _validGesture = true;
      }
      if (_fingerCount > 0 && _gestureFingers.length != _fingerCount) {
        _validGesture = false;
      }
      _gestureFingers[event.pointer] = event.localPosition;
      _fingerCount++;
      _tapSum += event.localPosition;
      if (_fingerCount > 2 || now - _gestureStart > 130) _validGesture = false;
    }
    if (!_playing || !_practice || _startupAt != null) return;
    if (event.kind == PointerDeviceKind.mouse &&
        (event.buttons & kPrimaryButton) == 0) {
      return;
    }
    final time = _inputNow;
    _finishLeadIn(time);
    final rawTime = _pointerTime(event, _now);
    if (_activeSegment case final segment? when rawTime >= segment.end) return;
    final inputTime = compensatedInputTime(rawTime, _inputDelay);
    if (!_canJudge || rawTime < _inputFloor) {
      _touches[event.pointer] = event.localPosition;
      if (_canJudge) _inputChangedAt[event.pointer] = _inputFloor;
      return;
    }
    _consumeHeldNotes(rawTime);
    _touches[event.pointer] = event.localPosition;
    _inputChangedAt[event.pointer] = inputTime;
    _origins[event.pointer] = event.localPosition;
    if (event.kind == PointerDeviceKind.touch) {
      _touchPresses.add((
        pointer: event.pointer,
        point: event.localPosition,
        time: inputTime,
        rawTime: rawTime,
      ));
    } else {
      _judgePress(
        event.localPosition,
        input: event.pointer,
        inputTime: inputTime,
        rawTime: rawTime,
      );
    }
  }

  double _pointerTime(PointerEvent event, double deliveredAt) {
    // Android's Flutter embedder uses MotionEvent uptime for pointer packets.
    // Only compensate timestamps that line up with the VM's monotonic clock.
    final delay = Timeline.now - event.timeStamp.inMicroseconds;
    return delay > 0 && delay <= _maxPointerDelay
        ? deliveredAt - delay / 1000 * _clockRate
        : deliveredAt;
  }

  void _move(PointerMoveEvent event) {
    final start = _gestureFingers[event.pointer];
    if (start != null && (event.localPosition - start).distance > 18) {
      _validGesture = false;
    }
    if (!_touches.containsKey(event.pointer)) return;
    final time = _inputNow;
    _finishLeadIn(time);
    if (!_canJudge) {
      _touches[event.pointer] = event.localPosition;
      return;
    }
    final rawTime = math.max(_inputFloor, _pointerTime(event, _now));
    if (_activeSegment case final segment? when rawTime >= segment.end) return;
    final inputTime = compensatedInputTime(rawTime, _inputDelay);
    if (_touchPresses.isNotEmpty &&
        _touchPresses.first.rawTime < rawTime - PracticeGrade.shinyWindow) {
      _flushTouchPresses();
    }
    _judgeHeld(rawTime);
    _touches[event.pointer] = event.localPosition;
    _inputChangedAt[event.pointer] = inputTime;
    final origin = _origins[event.pointer];
    if (origin != null && (event.localPosition - origin).distance >= 16) {
      if (_judgePress(
        origin,
        swipe: event.localPosition - origin,
        inputTime: inputTime,
        rawTime: rawTime,
      )) {
        _origins.remove(event.pointer);
      }
    }
    _judgeHeld(rawTime);
  }

  void _release(PointerEvent event) {
    if (event is PointerCancelEvent) {
      _touchPresses.removeWhere((press) => press.pointer == event.pointer);
    }
    if (_canJudge && _touches.containsKey(event.pointer)) {
      final inputTime = _pointerTime(event, _now).clamp(_inputFloor, _inputEnd);
      if (event is PointerCancelEvent) {
        _consumeHeldNotes(inputTime);
      } else {
        _flushTouchPresses();
        _judgeHeld(inputTime);
      }
    }
    _touches.remove(event.pointer);
    _inputChangedAt.remove(event.pointer);
    _pressClaims.remove(event.pointer);
    _origins.remove(event.pointer);
    final owner = _airOwners.remove(event.pointer);
    if (owner != null &&
        owner.note.sustainJudgements == null &&
        _canJudge &&
        event is PointerUpEvent) {
      final at = _pointerTime(event, _inputNow);
      final note = owner.note;
      if (note.start < at &&
          at < note.end &&
          at - owner.time <= _arcOwnershipGrace &&
          !_airOwners.values.any(
            (other) => other.note == note && other.time > owner.time,
          ) &&
          !_handoffArc(note, at) &&
          !widget.timeline
              .visible(at - _arcJunctionGrace, at + _arcJunctionGrace)
              .any((other) => _canExchangeArcs(note, other, at))) {
        _arcRegrabAt[note] = math.min(
          note.end.toDouble(),
          at + _arcOwnershipGrace,
        );
      }
    }
    if (_practice) return;
    final original = _gestureFingers.remove(event.pointer);
    if (original == null) return;
    if (event is PointerCancelEvent ||
        (event.localPosition - original).distance > 18) {
      _validGesture = false;
    }
    if (_gestureFingers.isNotEmpty) return;
    final now = event.timeStamp.inMilliseconds;
    if (!_validGesture || _fingerCount != 2 || now - _gestureStart > 240) {
      _lastTwoFingerTap = null;
      return;
    }
    final center = _tapSum / 2;
    final last = _lastTwoFingerTap;
    if (last != null &&
        now - last <= 450 &&
        (_lastTapCenter! - center).distance <= 96) {
      _lastTwoFingerTap = null;
      unawaited(_toggle());
    } else {
      _lastTwoFingerTap = now;
      _lastTapCenter = center;
    }
  }

  void _resetPreviewGesture() {
    _gestureFingers.clear();
    _lastTwoFingerTap = null;
    _lastTapCenter = null;
  }

  PracticeKey _keyType(_Target target) => switch (target.note.kind) {
    AffKind.hold => PracticeKey.hold,
    AffKind.arc => target.sustained ? PracticeKey.snake : PracticeKey.air,
    AffKind.flick => PracticeKey.flick,
    _ => PracticeKey.ground,
  };

  void _miss(_Target target) {
    target.done = true;
    _results.record(
      _keyType(target),
      null,
      _position.value,
      null,
      windows: target.windows,
      sustainWindow: target.automaticWindow,
    );
  }

  Offset? _feedbackAnchor(_Target target, double time) {
    final view = _practiceView(time);
    if (view.space case final g?) {
      final angles = widget.timeline.groupOptions[target.note.group];
      if (target.arcTap != null || target.tip != null) {
        return g.projectArcTap(target.x, target.height, time, angles: angles);
      }
      return target.air
          ? g.projectAir(target.x, target.height, time, angles: angles)
          : g.project(target.x, 0, time);
    }
    final g = view.flat;
    return g == null
        ? null
        : Offset(g.x(target.x, airborne: target.air), g.judgement);
  }

  void _hit(_Target target, double inputTime, {Offset? point}) {
    target.done = true;
    final visualTime = _position.value;
    if (target.sustained) target.judgementIndex = _results.history.length;
    final grade = _results.record(
      _keyType(target),
      target.time - inputTime,
      visualTime,
      point ?? _feedbackAnchor(target, visualTime),
      windows: target.windows,
      sustainWindow: target.automaticWindow,
    );
    if (target.sustained) return;
    if (grade != PracticeGrade.lost) {
      _addHitEffect(
        visualTime,
        target.tip == null ? target.x : (target.x + target.tip!.x) / 2,
        target.tip == null
            ? target.height
            : (target.height + target.tip!.height) / 2,
        air: target.air,
        arcTap: target.arcTap != null || target.tip != null,
        group: target.note.group,
        targetTime: target.time,
      );
    }
    if (target.arcTap case final tap?) {
      _judgement.hitTap(target.note, tap, visualTime);
    } else if (target.note.kind == AffKind.tap || target.tip != null) {
      _judgement.hide(target.note, visualTime, immediately: true);
    } else if (target.note.kind == AffKind.flick) {
      _judgement.hide(target.note, visualTime);
    }
  }

  void _addHitEffect(
    double at,
    double x,
    double height, {
    required bool air,
    bool arcTap = false,
    int group = 0,
    int? targetTime,
  }) {
    _judgement.hitEffects.removeWhere(
      (hit) => _position.value - hit.at >= ChartJudgement.duration,
    );
    final effects = _judgement.hitEffects;
    final existing = effects.lastIndexWhere(
      (hit) =>
          (targetTime == null
              ? hit.targetTime == null && hit.at == at
              : hit.targetTime == targetTime) &&
          hit.x == x &&
          hit.height == height &&
          hit.air == air &&
          hit.arcTap == arcTap &&
          hit.group == group,
    );
    final count = existing < 0 ? 1 : effects.removeAt(existing).count + 1;
    effects.add((
      at: at,
      x: x,
      height: height,
      air: air,
      arcTap: arcTap,
      group: group,
      count: count,
      targetTime: targetTime,
    ));
  }

  Iterable<_PressCandidate> _pressCandidates(
    Offset point,
    double time, {
    Offset? swipe,
    double? lane,
    Object? input,
    double? rawTime,
    bool snake = false,
  }) sync* {
    final view = _practiceView(rawTime ?? time);
    for (var index = _next; index < _targets.length; index++) {
      final target = _targets[index];
      if (target.time > time + _candidateWindow) break;
      final delta = (target.time - time).abs();
      final isSnake = target.sustained && target.air;
      final checkpoints = isSnake ? _snakeInputs : _checkpointInputs;
      if (target.done ||
          isSnake != snake ||
          !target.accepts(time) ||
          (target.sustained &&
              (input == null ||
                  checkpoints[target.time]?.containsKey(input) == true))) {
        continue;
      }
      final vector = target.direction;
      if ((vector == null) != (swipe == null)) continue;
      final direction = vector == null
          ? null
          : view.space?.flickDirection(
                  target.x,
                  target.height,
                  view.time,
                  vector,
                  angles: widget.timeline.groupOptions[target.note.group],
                ) ??
                Offset(vector.dx, -vector.dy);
      if (direction != null &&
          swipe != null &&
          direction.distance > 0.01 &&
          (direction.dx * swipe.dx + direction.dy * swipe.dy) <
              direction.distance * swipe.distance * 0.4) {
        continue;
      }
      final contact = isSnake && target.autoEarly != null
          ? _arcTarget(target.note, view.time)
          : target;
      final spatial = lane == null
          ? _distance(contact, point, view)
          : !target.air &&
                (lane - target.note.standardLaneX).abs() < 0.02 &&
                _laneMode.showsAt(widget.timeline, target.note, view.time)
          ? 0.0
          : null;
      if (spatial == null ||
          (isSnake &&
              input is int &&
              _holdsOtherArc(
                input,
                target.note,
                target.autoEarly != null ? contact.time : time + _inputDelay,
                point,
                view,
                checkpointTime: target.time,
              ))) {
        continue;
      }
      yield (
        target: target,
        cost:
            (delta * 1000).round() * 4096 +
            (spatial * 64).round() +
            (target.sustained && !isSnake ? 1 << 34 : 0),
        scores:
            practiceGradeAt(
              target.windows,
              target.time - time,
              sustainWindow: target.automaticWindow,
            ) !=
            PracticeGrade.lost,
      );
    }
  }

  void _flushTouchPresses() {
    if (_touchPresses.isEmpty) return;
    final presses = List.of(_touchPresses);
    _judgeHeld(presses.first.rawTime);
    final choices = [
      for (final press in presses)
        _pressCandidates(
          press.point,
          press.time,
          input: press.pointer,
          rawTime: press.rawTime,
        ).toList(),
    ];
    final hits = _matchPresses({
      for (var i = 0; i < choices.length; i++)
        i: choices[i].where((candidate) => candidate.scores).toList(),
    });
    final hitTargets = hits.values.map((candidate) => candidate.target).toSet();
    final remaining = {
      for (var i = 0; i < choices.length; i++)
        if (!hits.containsKey(i))
          i: choices[i]
              .where(
                (candidate) =>
                    !candidate.scores && !hitTargets.contains(candidate.target),
              )
              .toList(),
    };
    final matched = [...hits.entries, ..._matchPresses(remaining).entries]
      ..sort((a, b) => a.key.compareTo(b.key));
    for (final entry in matched) {
      final press = presses[entry.key];
      if (!entry.value.target.sustained) {
        _pressClaims[press.pointer] = (
          inputAt: press.time,
          targetAt: entry.value.target.time,
          hold: null,
        );
      }
    }
    final reserved = matched.map((entry) => entry.value.target).toSet();
    for (final entry in matched) {
      final press = presses[entry.key];
      _judgeHeld(press.rawTime);
      final original = entry.value;
      reserved.remove(original.target);
      final candidate = original.target.done
          ? _bestPress(
              choices[entry.key].where(
                (item) => !item.target.done && !reserved.contains(item.target),
              ),
            )
          : original;
      if (candidate != null) {
        _hitPress(candidate, press.time, press.pointer, press.point);
      } else {
        _pressClaims.remove(press.pointer);
      }
    }
    final snakes = _matchPresses({
      for (final (index, press) in presses.indexed)
        index: _pressCandidates(
          press.point,
          press.time,
          input: press.pointer,
          rawTime: press.rawTime,
          snake: true,
        ).toList(),
    });
    for (final entry in snakes.entries) {
      final press = presses[entry.key];
      _hitPress(entry.value, press.time, press.pointer, press.point);
    }
    _touchPresses.clear();
    _advanceTargets();
    if (matched.isNotEmpty || snakes.isNotEmpty) _updateScore();
  }

  void _hitPress(
    _PressCandidate candidate,
    double time,
    Object? input,
    Offset? point,
  ) {
    final target = candidate.target;
    if (input != null) {
      if (target.sustained) {
        final checkpoints = target.air ? _snakeInputs : _checkpointInputs;
        (checkpoints[target.time] ??= {})[input] = target;
        if (input is int && target.air) {
          _rememberArcContact(input, target, time + _inputDelay);
        }
      }
      if (!target.sustained || !target.air) {
        _pressClaims[input] = (
          inputAt: time,
          targetAt: target.time,
          hold: target.sustained ? target.note : null,
        );
      }
    }
    _hit(target, time, point: point);
  }

  bool _judgePress(
    Offset point, {
    Offset? swipe,
    double? lane,
    Object? input,
    double? inputTime,
    double? rawTime,
  }) {
    _flushTouchPresses();
    final actual = rawTime ?? _inputNow;
    final time = inputTime ?? compensatedInputTime(actual, _inputDelay);
    final choices = _pressCandidates(
      point,
      time,
      swipe: swipe,
      lane: lane,
      input: input,
      rawTime: actual,
    ).toList();
    var best = _bestPress(choices);
    if (best != null && !best.target.sustained && input != null) {
      _pressClaims[input] = (
        inputAt: time,
        targetAt: best.target.time,
        hold: null,
      );
    }
    // Settle the held contacts before consuming this new press. A quick
    // press must not be processed as a held contact and then matched again.
    final changedAt = _inputChangedAt.remove(input);
    _judgeHeld(actual);
    if (input != null && changedAt != null) _inputChangedAt[input] = changedAt;
    if (best?.target.done == true) {
      best = _bestPress(choices.where((candidate) => !candidate.target.done));
      if (input != null) _pressClaims.remove(input);
    }
    if (best != null) {
      _hitPress(best, time, input, lane == null ? point : null);
    }
    final snake = input is int && swipe == null
        ? _bestPress(
            _pressCandidates(
              point,
              time,
              input: input,
              rawTime: actual,
              snake: true,
            ),
          )
        : null;
    if (snake != null) _hitPress(snake, time, input, point);
    _advanceTargets();
    if (best != null || snake != null) _updateScore();
    return best != null && best.scores;
  }

  Future<void> _editFeedback() async {
    if (_playing) await _change(_pause);
    if (!mounted) return;
    final settings = await Navigator.of(context).push<FeedbackSettings>(
      MaterialPageRoute(
        builder: (_) => ChartFeedbackEditor(
          initial: _feedback,
          skin: widget.skin,
          perspective: _perspective,
          overlay: _overlay,
          laneMode: _laneMode,
          playbackView: _playbackView,
          timing: _timingWindows[PracticeKey.air],
        ),
      ),
    );
    if (!mounted || settings == null) return;
    setState(() => _feedback = settings);
    try {
      await _preferences?.setString(_feedbackKey, settings.encode());
    } on PlatformException {
      // The current practice session still uses the selected settings.
    }
  }

  Future<void> _editPlaybackView() async {
    final settings = await Navigator.of(context).push<ChartPlaybackView>(
      MaterialPageRoute(
        builder: (_) => ChartPlaybackViewEditor(
          initial: _playbackView,
          lanes: _flatWide ? ChartLaneMode.six : ChartLaneMode.four,
          skin: widget.skin,
          appearance: _appearance,
        ),
      ),
    );
    if (!mounted || settings == null) return;
    setState(() => _playbackView = settings);
    try {
      await _preferences?.setString(
        _viewKey,
        encodeChartPlaybackView(settings),
      );
    } on PlatformException {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('视角已应用，保存偏好失败')));
      }
    }
  }

  String? _profilePreference(String key, bool perspective) =>
      _preferences?.getString(_profileKey(key, perspective)) ??
      _preferences?.getString(key);

  static String _profileKey(String key, bool perspective) =>
      '${key}_${perspective ? '3d' : '2d'}';

  Future<void> _editHitAreas({bool showTiming = false}) async {
    final settings = await Navigator.of(context).push<ChartHitEditorResult>(
      MaterialPageRoute(
        builder: (_) => ChartHitRegionEditor(
          initial: _hitProfiles,
          timing: _timeProfiles,
          playbackView: _playbackView,
          perspective: _perspective,
          lanes: _flatWide ? ChartLaneMode.six : ChartLaneMode.four,
          overlay: _overlay,
          appearance: _appearance,
          skin: widget.skin,
          showTiming: showTiming,
        ),
      ),
    );
    if (!mounted || settings == null) return;
    setState(() {
      _hitProfiles = settings.areas;
      _timeProfiles = settings.timing;
      _applyTimingWindows();
    });
    try {
      for (final mode in [false, true]) {
        await _preferences?.setString(
          _profileKey(_hitAreasKey, mode),
          encodeChartHitAreas(_hitProfiles[mode] ?? const {}),
        );
        await _preferences?.setString(
          _profileKey(_timingWindowsKey, mode),
          encodePracticeWindows(_timeProfiles[mode] ?? const {}),
        );
      }
    } on PlatformException {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('判定范围已应用，保存偏好失败')));
      }
    }
  }

  Future<void> _editCalibration() async {
    final values = await Navigator.of(context).push<ChartDelaySettings>(
      MaterialPageRoute(
        builder: (_) => ChartDelayCalibration(
          initial: (audio: _delay, input: _inputDelay),
          onEditTiming: () => _editHitAreas(showTiming: true),
        ),
      ),
    );
    if (!mounted || values == null) return;
    setState(() {
      _inputDelay = values.input;
      _setAudioDelay(values.audio);
    });
    try {
      await _preferences?.setInt(_delayKey, _delay);
      await _preferences?.setInt(_inputDelayKey, _inputDelay);
    } on PlatformException {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('延迟校准已应用，保存偏好失败')));
      }
    }
  }

  KeyEventResult _key(FocusNode _, KeyEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.space ||
        (_practiceStarted && event.logicalKey == LogicalKeyboardKey.escape)) {
      if (event is KeyDownEvent) unawaited(_toggle());
      return KeyEventResult.handled;
    }
    if (!_practice) return KeyEventResult.ignored;
    if (event is KeyUpEvent && _keyboard.containsKey(event.logicalKey)) {
      if (_canJudge) {
        _flushTouchPresses();
        _judgeHeld(_inputNow);
      }
      _keyboard.remove(event.logicalKey);
      _inputChangedAt.remove(event.logicalKey);
      _pressClaims.remove(event.logicalKey);
      return KeyEventResult.handled;
    }
    final index = const [
      LogicalKeyboardKey.keyS,
      LogicalKeyboardKey.keyD,
      LogicalKeyboardKey.keyF,
      LogicalKeyboardKey.keyJ,
      LogicalKeyboardKey.keyK,
      LogicalKeyboardKey.keyL,
    ].indexOf(event.logicalKey);
    if (index == -1 ||
        (!(_perspective
                ? _laneMode.expansion(widget.timeline, _position.value) > 0
                : _flatWide) &&
            (index == 0 || index == 5))) {
      return KeyEventResult.ignored;
    }
    if (_playing && _startupAt == null && event is KeyDownEvent) {
      if (_activeSegment case final segment? when _now >= segment.end) {
        return KeyEventResult.handled;
      }
      final lane = (index - 0.5) / 4;
      final time = _inputNow;
      _finishLeadIn(time);
      if (!_canJudge) {
        _keyboard[event.logicalKey] = lane;
        return KeyEventResult.handled;
      }
      _consumeHeldNotes(time);
      _keyboard[event.logicalKey] = lane;
      _inputChangedAt[event.logicalKey] = compensatedInputTime(
        time,
        _inputDelay,
      );
      _judgePress(Offset.zero, lane: lane, input: event.logicalKey);
    }
    return KeyEventResult.handled;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _resetPreviewGesture();
      if (_playing) _change(_pause);
    } else if (_practiceStarted) {
      unawaited(_setImmersive(true));
    }
  }

  @override
  void dispose() {
    _speedInput.dispose();
    WidgetsBinding.instance.removeObserver(this);
    if (_practiceStarted) unawaited(_setImmersive(false));
    _shutters.dispose();
    _ticker.dispose();
    _practiceFocus.dispose();
    _position.dispose();
    _controlsPosition.dispose();
    _score.dispose();
    if (_supportsAudio && widget.audio != null) {
      _audio.invokeMethod<void>('close').catchError((Object _) {});
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_practiceStarted || (!_busy && !_playing),
    onPopInvokedWithResult: (popped, _) {
      if (!popped && _playing && _practiceStarted) unawaited(_toggle());
    },
    child: Scaffold(
      appBar: _practiceStarted
          ? null
          : AppBar(title: Text(_practice ? '谱面试玩' : '播放预览')),
      body: Focus(
        focusNode: _practiceFocus,
        autofocus: true,
        onKeyEvent: _key,
        onFocusChange: (focused) {
          if (focused || _keyboard.isEmpty) return;
          if (_canJudge) {
            _flushTouchPresses();
            _judgeHeld(_inputNow);
          }
          _inputChangedAt.removeWhere((key, _) => key is LogicalKeyboardKey);
          _pressClaims.removeWhere((key, _) => key is LogicalKeyboardKey);
          _keyboard.clear();
        },
        child: ValueListenableBuilder(
          valueListenable:
              widget.skin ?? const AlwaysStoppedAnimation(ChartSkin.defaults),
          builder: (context, skin, _) =>
              _practiceStarted ? _playScreen(skin) : _setupScreen(skin),
        ),
      ),
    ),
  );

  Widget _setupScreen(ChartSkin skin) => SafeArea(
    child: Column(
      children: [
        if (_status != null)
          Padding(padding: const EdgeInsets.all(6), child: Text(_status!)),
        if (!_practice && Platform.isAndroid) const Text('双指双击可暂停或继续'),
        _options(),
        _transport(showPlay: true),
        _jumpControls(),
        Expanded(child: _playfield(skin)),
      ],
    ),
  );

  Widget _playScreen(ChartSkin skin) => Stack(
    fit: StackFit.expand,
    children: [
      _playfield(skin),
      if (_playing)
        if (_startupAt case final start?)
          IgnorePointer(
            child: Center(
              child: ValueListenableBuilder(
                key: const ValueKey('practice-preparation'),
                valueListenable: _position,
                builder: (context, time, _) => Text(
                  '${math.max(1, ((start - time) / 1000).ceil())}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 42,
                    fontWeight: FontWeight.bold,
                    shadows: [Shadow(color: Colors.black, blurRadius: 9)],
                  ),
                ),
              ),
            ),
          ),
      Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: SafeArea(
          bottom: false,
          minimum: const EdgeInsets.fromLTRB(10, 8, 10, 0),
          child: ChartPracticeHud(
            skin: skin,
            results: _results,
            scores: _score,
            onPause: _playing && !_busy ? _toggle : null,
          ),
        ),
      ),
      if (!_playing && !_transitioning) _pauseMenu(),
      if (_transitioning)
        ChartPracticeTransition(
          key: const ValueKey('practice-transition'),
          progress: _shutters,
          skin: skin,
        ),
    ],
  );

  Widget _pauseMenu() => ColoredBox(
    color: const Color(0xA610101D),
    child: SafeArea(
      minimum: const EdgeInsets.all(12),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Material(
            key: const ValueKey('practice-pause-menu'),
            color: const Color(0xFF202132),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: const BorderSide(color: Color(0xFF737087)),
            ),
            clipBehavior: Clip.antiAlias,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '已暂停',
                    style: TextStyle(color: Colors.white, fontSize: 20),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    alignment: WrapAlignment.center,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: _busy ? null : _restartPractice,
                        icon: const Icon(Icons.restart_alt),
                        label: const Text('重开'),
                      ),
                      FilledButton.icon(
                        onPressed: _busy ? null : _toggle,
                        icon: const Icon(Icons.play_arrow),
                        label: Text(_selectedSegment == null ? '继续' : '返回游戏'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _busy
                            ? null
                            : () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.arrow_back),
                        label: const Text('返回'),
                      ),
                    ],
                  ),
                  const Divider(),
                  SwitchListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                    title: const Text('开场过渡动画'),
                    value: _showTransition,
                    onChanged: _busy
                        ? null
                        : (value) {
                            setState(() => _showTransition = value);
                            unawaited(
                              _preferences?.setBool(_transitionKey, value),
                            );
                          },
                  ),
                  if (_status != null) Text(_status!),
                  _options(),
                  SwitchListTile(
                    key: const ValueKey('practice-segment-toggle'),
                    dense: true,
                    title: const Text('段落练习'),
                    value: _selectedSegment != null,
                    onChanged: _busy || _max <= _min
                        ? null
                        : (enabled) {
                            setState(() {
                              _selectedSegment = enabled
                                  ? (start: _min, end: _max)
                                  : null;
                              if (enabled) _loopStart = _loopEnd = null;
                            });
                          },
                  ),
                  if (_selectedSegment case final segment?)
                    Text(
                      'A ${(segment.start / 1000).toStringAsFixed(2)} s  ·  B ${(segment.end / 1000).toStringAsFixed(2)} s',
                    ),
                  ValueListenableBuilder<double>(
                    valueListenable: _controlsPosition,
                    builder: (context, time, _) => PracticeDensityTrack(
                      min: _min,
                      max: _max,
                      position: time,
                      density: _density,
                      segment: _selectedSegment,
                      onSeek: _busy ? null : (at) => _change(() => _seek(at)),
                      onSegment: (segment) =>
                          setState(() => _selectedSegment = segment),
                    ),
                  ),
                  _jumpControls(),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _options() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.center,
        children: [
          ChartLaneMenu(
            mode: _laneMode,
            onChanged: _busy
                ? null
                : (mode) {
                    setState(() {
                      _laneMode = mode;
                      _leadInEnd = null;
                      _buildPracticeTargets();
                    });
                    widget.onLaneModeChanged?.call(mode);
                    _practiceFocus.requestFocus();
                  },
          ),
          IconButton(
            tooltip: '音乐音量',
            onPressed: _busy ? null : _volumeSettings,
            icon: Icon(
              _volume == 0
                  ? Icons.volume_off_outlined
                  : Icons.volume_up_outlined,
            ),
          ),
          IconButton(
            tooltip: '预览流速与延迟',
            onPressed: _busy ? null : _previewSettings,
            icon: const Icon(Icons.tune),
          ),
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: false, label: Text('2D')),
              ButtonSegment(value: true, label: Text('3D')),
            ],
            selected: {_perspective},
            onSelectionChanged: _busy
                ? null
                : (selection) => setState(() {
                    _perspective = selection.single;
                    _applyTimingWindows();
                    _touches.clear();
                    _keyboard.clear();
                    _resetHoldTracking();
                    _origins.clear();
                  }),
          ),
          ChartAppearanceButton(onPressed: _busy ? null : _appearanceSettings),
          if (_practice)
            IconButton(
              tooltip: '游玩判定显示',
              onPressed: _busy ? null : _editFeedback,
              icon: const Icon(Icons.speed_outlined),
            ),
          if (_practice && _practiceStarted)
            IconButton(
              tooltip: '3D 游玩视角',
              onPressed: _busy ? null : _editPlaybackView,
              icon: const Icon(Icons.view_in_ar_outlined),
            ),
          if (_practice && _practiceStarted)
            IconButton(
              tooltip: '判定范围',
              onPressed: _busy ? null : _editHitAreas,
              icon: const Icon(Icons.crop_free),
            ),
          if (_practice && _practiceStarted)
            IconButton(
              tooltip: '延迟校准',
              onPressed: _busy ? null : _editCalibration,
              icon: const Icon(Icons.timer_outlined),
            ),
          if (!_perspective)
            FilterChip(
              label: const Text('叠加地键和空键'),
              selected: _overlay,
              onSelected: _busy
                  ? null
                  : (value) {
                      setState(() {
                        _overlay = value;
                        _touches.clear();
                        _origins.clear();
                        _keyboard.clear();
                        _resetHoldTracking();
                      });
                      unawaited(_preferences?.setBool(_overlayKey, value));
                    },
            ),
          TextButton.icon(
            onPressed: _busy ? null : _switchPracticeMode,
            icon: Icon(
              _practice ? Icons.visibility_outlined : Icons.gamepad_outlined,
            ),
            label: Text(_practice ? '仅预览' : '开始练习'),
          ),
          if (_practice)
            IconButton(
              tooltip: _loopEnd != null
                  ? '清除循环'
                  : _loopStart == null
                  ? '设为循环起点'
                  : '设为循环终点',
              isSelected: _loopStart != null,
              onPressed: _busy ? null : _setLoop,
              icon: const Icon(Icons.repeat),
            ),
        ],
      ),
      if (_practice && _loopStart != null)
        Text(
          '${(_loopStart! / 1000).toStringAsFixed(2)} s'
          '${_loopEnd == null ? ' · 定位到终点后再点循环按钮' : ' – ${(_loopEnd! / 1000).toStringAsFixed(2)} s'}',
        ),
    ],
  );

  Widget _transport({required bool showPlay}) => ValueListenableBuilder<double>(
    valueListenable: _controlsPosition,
    builder: (context, time, _) => Row(
      children: [
        if (showPlay)
          IconButton(
            tooltip: _playing ? '暂停' : '播放',
            onPressed: _busy
                ? null
                : () {
                    _practiceFocus.requestFocus();
                    _toggle();
                  },
            icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
          ),
        Expanded(
          child: Slider(
            min: _min,
            max: _max,
            value: (_seekDraft ?? time).clamp(_min, _max),
            onChanged: _busy
                ? null
                : (value) => setState(() => _seekDraft = value),
            onChangeEnd: (value) {
              _seekDraft = null;
              _change(() => _seek(value));
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Text('${((_seekDraft ?? time) / 1000).toStringAsFixed(2)} s'),
        ),
      ],
    ),
  );

  Widget _jumpControls() => Wrap(
    alignment: WrapAlignment.center,
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 2,
    children: [
      for (final (seconds, label, tooltip) in [
        (-15.0, '−15 s', '后退 15 秒'),
        (-_jumpSeconds, '−$_jumpLabel s', '后退自定义秒数'),
        (_jumpSeconds, '+$_jumpLabel s', '前进自定义秒数'),
        (15.0, '+15 s', '前进 15 秒'),
      ])
        Tooltip(
          message: tooltip,
          child: TextButton(
            onPressed: _busy ? null : () => _jumpBy(seconds),
            child: Text(label),
          ),
        ),
      IconButton(
        tooltip: '设置自定义跳转秒数',
        onPressed: _busy ? null : _configureJump,
        icon: const Icon(Icons.more_time),
      ),
    ],
  );

  String get _jumpLabel =>
      _jumpSeconds.toStringAsFixed(_jumpSeconds % 1 == 0 ? 0 : 2);

  Widget _playfield(ChartSkin skin) {
    final leadIn = _leadInEnd != null;
    final judgement = _practice && !leadIn ? _judgement : null;
    final startup = _startupAt;
    final visibleSegment =
        _activeSegment ??
        (startup == null ? null : (start: startup, end: double.infinity));
    return LayoutBuilder(
      builder: (context, constraints) {
        _size = constraints.biggest;
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _press,
          onPointerMove: _move,
          onPointerUp: _release,
          onPointerCancel: _release,
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _perspective
                  ? ChartPerspectivePainter(
                      widget.timeline,
                      _position,
                      _lookahead,
                      reverse: _speed < 0,
                      frozenAt: _speed == 0 ? _frozenAt : null,
                      playbackView: _playbackView,
                      practiceSegment: visibleSegment,
                      appearance: _appearance,
                      skin: skin,
                      laneMode: _laneMode,
                      playbackFraming: true,
                      judgement: judgement,
                      noteOpacity: leadIn ? .5 : 1,
                    )
                  : ChartTimelinePainter(
                      widget.timeline,
                      _position,
                      _lookahead,
                      reverse: _speed < 0,
                      frozenAt: _speed == 0 ? _frozenAt : null,
                      appearance: _appearance,
                      skin: skin,
                      preview: true,
                      overlay: _overlay,
                      practiceSegment: visibleSegment,
                      laneMode: _laneMode,
                      judgement: judgement,
                      noteOpacity: leadIn ? .5 : 1,
                    ),
              size: Size.infinite,
              foregroundPainter: _practice && !leadIn
                  ? PracticeFeedbackPainter(
                      _position,
                      _results,
                      _feedback,
                      skin,
                      _score,
                      defaultWindows: _timingWindows[PracticeKey.ground],
                    )
                  : null,
            ),
          ),
        );
      },
    );
  }
}

typedef _PracticeView = ({
  double time,
  Map<_Target, ChartHitFrame?> frames,
  PerspectiveGeometry? space,
  TimelineGeometry? flat,
});

typedef _Settlement = ({_Target target, double at, bool input, Offset? point});

typedef _PressCandidate = ({_Target target, int cost, bool scores});

_PressCandidate? _bestPress(Iterable<_PressCandidate> candidates) {
  _PressCandidate? best;
  for (final candidate in candidates) {
    if (best == null || candidate.cost < best.cost) best = candidate;
  }
  return best;
}

// Re-route overlapping touches until the batch has the maximum number of
// matches. Each augmenting path minimizes total absolute timing error.
Map<int, _PressCandidate> _matchPresses(
  Map<int, List<_PressCandidate>> choices,
) {
  final matched = <int, _PressCandidate>{};
  final owners = <_Target, int>{};
  while (matched.length < choices.length) {
    final inputCost = {
      for (final input in choices.keys)
        if (!matched.containsKey(input)) input: 0,
    };
    final targetCost = <_Target, int>{};
    final via = <_Target, ({int input, _PressCandidate candidate})>{};
    for (var pass = 0; pass < choices.length; pass++) {
      var changed = false;
      for (final entry in choices.entries) {
        final cost = inputCost[entry.key];
        if (cost == null) continue;
        for (final candidate in entry.value) {
          final target = candidate.target;
          final next = cost + candidate.cost;
          final current = targetCost[target];
          if (matched[entry.key]?.target == target ||
              (current != null && current <= next)) {
            continue;
          }
          targetCost[target] = next;
          via[target] = (input: entry.key, candidate: candidate);
          changed = true;
          final owner = owners[target];
          if (owner != null) {
            inputCost[owner] = next - matched[owner]!.cost;
          }
        }
      }
      if (!changed) break;
    }
    _Target? end;
    for (final entry in targetCost.entries) {
      if (!owners.containsKey(entry.key) &&
          (end == null || entry.value < targetCost[end]!)) {
        end = entry.key;
      }
    }
    if (end == null) break;
    while (end != null) {
      final step = via[end]!;
      final previous = matched[step.input]?.target;
      matched[step.input] = step.candidate;
      owners[end] = step.input;
      end = previous;
    }
  }
  return matched;
}

class _Target {
  _Target(
    this.note,
    this.time,
    this.x,
    this.air, {
    this.sustained = false,
    this.height = 0,
    this.tip,
    this.direction,
    this.arcTap,
    this.autoEarly,
  });
  final int time;
  final AffEvent note;
  final int? arcTap;
  final double x, height;
  final ({double x, double height})? tip;
  final Offset? direction;
  final bool air, sustained;
  final double? autoEarly;
  PracticeWindows? customTiming;
  bool get usesAutomaticTiming => autoEarly != null && customTiming == null;
  bool get usesShinyWindow => sustained || note.kind == AffKind.hold;
  PracticeWindows get windows =>
      customTiming ??
      (usesShinyWindow
          ? sustainPracticeWindows(PracticeGrade.shinyWindow)
          : defaultPracticeWindows(PracticeKey.ground));
  double get earlyWindow =>
      usesAutomaticTiming ? autoEarly! : windows.early.capture;
  double get lateWindow =>
      usesAutomaticTiming ? automaticSustainLateWindow : windows.after.capture;
  double get inputStartsAt => time - earlyWindow;
  double get deadline => time + lateWindow;
  PracticeSustainWindow? get automaticWindow => usesAutomaticTiming
      ? (early: earlyWindow, late: automaticSustainLateWindow)
      : null;
  bool accepts(double input) => inputStartsAt <= input && input <= deadline;
  double get expiry => deadline + _pointerDeliveryGrace;
  bool done = false;
  int? judgementIndex;
}
