import 'dart:async';
import 'dart:developer' show Timeline;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'chart_millisecond_input.dart';
import 'chart_perspective.dart';

const _beat = 500;
const _measure = _beat * 4;
const _drumBars = 8;
const _recording = _measure * (_drumBars + 1);
typedef ChartDelaySettings = ({int audio, int input});

double compensatedInputTime(double time, int inputDelay) => time - inputDelay;

double calibrationVisualTime(double mediaTime, int audioDelay) =>
    mediaTime - audioDelay;

double calibrationError(double time, int inputDelay) {
  final corrected = compensatedInputTime(time, inputDelay);
  final bar = (corrected / _measure).round().clamp(1, _drumBars);
  return bar * _measure - corrected;
}

double calibrationLineEnd(double time, int audioDelay) =>
    (((time + audioDelay) / _beat).floor() + 2) * _beat - audioDelay.toDouble();

/// A short kick on the downbeat and a lighter drum on the three following
/// beats. PCM gives the two native playback backends identical sample timing.
Uint8List calibrationDrums() {
  const sampleRate = 24000;
  const barBytes = sampleRate * _measure ~/ 1000 * 2;
  const frames = sampleRate * _recording ~/ 1000;
  final bytes = ByteData(44 + frames * 2);
  void tag(int at, String value) {
    for (final (index, unit) in value.codeUnits.indexed) {
      bytes.setUint8(at + index, unit);
    }
  }

  void i16(int at, int value) => bytes.setUint16(at, value, Endian.little);
  void i32(int at, int value) => bytes.setUint32(at, value, Endian.little);
  tag(0, 'RIFF');
  i32(4, bytes.lengthInBytes - 8);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  i32(16, 16);
  i16(20, 1);
  i16(22, 1);
  i32(24, sampleRate);
  i32(28, sampleRate * 2);
  i16(32, 2);
  i16(34, 16);
  tag(36, 'data');
  i32(40, frames * 2);
  for (var beat = 4; beat < 8; beat++) {
    final accent = beat == 4;
    final start = beat * sampleRate * _beat ~/ 1000;
    for (var i = 0; i < sampleRate ~/ 9; i++) {
      final t = i / sampleRate;
      final envelope = math.exp(-t * (accent ? 47 : 72));
      final tone = math.sin(2 * math.pi * (accent ? 90 : 175) * t);
      final attack = math.sin(2 * math.pi * 1000 * t) * math.exp(-380 * t);
      bytes.setInt16(
        44 + (start + i) * 2,
        ((tone * envelope + attack * .3) * (accent ? 19500 : 10100)).round(),
        Endian.little,
      );
    }
  }
  final wav = bytes.buffer.asUint8List();
  for (var bar = 2; bar <= _drumBars; bar++) {
    final start = 44 + bar * barBytes;
    wav.setRange(start, start + barBytes, wav, 44 + barBytes);
  }
  return wav;
}

class ChartDelayCalibration extends StatefulWidget {
  const ChartDelayCalibration({
    super.key,
    required this.initial,
    this.onEditTiming,
  });
  final ChartDelaySettings initial;
  final Future<void> Function()? onEditTiming;

  @override
  State<ChartDelayCalibration> createState() => _ChartDelayCalibrationState();
}

class _ChartDelayCalibrationState extends State<ChartDelayCalibration>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _audio = MethodChannel('arcaea_manager/chart_calibration_audio');
  final _clock = Stopwatch();
  final _position = ValueNotifier(0.0);
  late final Ticker _ticker;
  late int _audioDelay = widget.initial.audio;
  late int _inputDelay = widget.initial.input;
  List<double> _marks = const [];
  File? _file;
  bool _opened = false, _starting = false, _sampling = false;
  bool _foreground = true;
  bool _editingTiming = false;
  String? _audioError;
  int _round = 0;
  double _origin = 0, _rate = 1, _sampled = 0;

  double get _elapsed => _clock.elapsedMicroseconds / 1000;
  double get _mediaTime => _origin + _elapsed * _rate;
  double get _now => calibrationVisualTime(_mediaTime, _audioDelay);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ticker = createTicker(_tick);
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      final directory = await getTemporaryDirectory();
      if (!mounted) return;
      final file = File(
        '${directory.path}${Platform.pathSeparator}chart-calibration-'
        '${DateTime.now().microsecondsSinceEpoch}.wav',
      );
      _file = file;
      await file.writeAsBytes(calibrationDrums(), flush: true);
      if (!mounted) {
        await _delete(file);
        return;
      }
      final duration = await _audio.invokeMethod<int>('open', {
        'file': file.path,
      });
      if (!mounted) return;
      if (duration == null || duration <= 0) {
        throw const FormatException('鼓点音频为空');
      }
      _opened = true;
      await _audio.invokeMethod<void>('volume', {'gain': .75});
    } catch (_) {
      if (mounted) _useSilentClock('鼓点音频不可用，仍可用画面校准输入。');
    }
    if (mounted) await _startRound();
  }

  void _useSilentClock(String message) {
    _opened = false;
    setState(() => _audioError = message);
  }

  Future<void> _startRound() async {
    if (_starting || _editingTiming || !_foreground || !mounted) return;
    _starting = true;
    final round = ++_round;
    _ticker.stop();
    _clock
      ..stop()
      ..reset();
    _origin = _sampled = 0;
    _rate = 1;
    _sampling = false;
    setState(() => _marks = const []);
    _position.value = _now;
    var anchor = 0;
    try {
      if (_opened) {
        anchor = await _audio.invokeMethod<int>('seek', {'position': 0}) ?? 0;
        if (mounted && round == _round && _foreground) {
          await _audio.invokeMethod<void>('play');
        }
      }
    } catch (_) {
      if (mounted && round == _round) {
        _useSilentClock('鼓点音频中断，仍可用画面校准输入。');
      }
    } finally {
      _starting = false;
    }
    if (!mounted || !_foreground) return;
    if (round != _round) {
      unawaited(_startRound());
      return;
    }
    _origin = anchor.toDouble();
    _clock.start();
    _ticker.start();
  }

  void _tick(Duration _) {
    _position.value = _now;
    if (!_opened) {
      if (_mediaTime >= _recording) unawaited(_startRound());
      return;
    }
    if (_sampling || _elapsed - _sampled < 150) return;
    _sampled = _elapsed;
    unawaited(_sample());
  }

  Future<void> _sample() async {
    final round = _round;
    final before = _elapsed;
    _sampling = true;
    try {
      final sample = await _audio.invokeListMethod<Object>('position');
      if (!mounted || round != _round || sample == null) return;
      final media = sample[0] as int;
      if (sample[1] != true && media >= _recording - 100) {
        unawaited(_startRound());
        return;
      }
      final elapsed = _elapsed;
      if (sample[1] != true || elapsed - before > 80) return;
      final at = (before + elapsed) / 2;
      final error = media - (_origin + at * _rate);
      // Keep the playhead continuous, as in normal playback. Each round
      // gets its own origin and the native player never wraps its counter.
      final rate = error.abs() <= 8 ? 1.0 : 1 + (error / 500).clamp(-.15, .15);
      _origin = _mediaTime - elapsed * rate;
      _rate = rate;
    } catch (_) {
      if (mounted && round == _round) {
        _useSilentClock('鼓点音频中断，仍可用画面校准输入。');
      }
    } finally {
      if (round == _round) _sampling = false;
    }
  }

  Future<void> _command(String name) async {
    try {
      await _audio.invokeMethod<void>(name);
    } catch (_) {
      // A closing or unavailable calibration session has no active audio.
    }
  }

  Future<void> _editTiming() async {
    if (_editingTiming) return;
    setState(() => _editingTiming = true);
    _round++;
    _clock.stop();
    _ticker.stop();
    if (_opened) await _command('pause');
    if (!mounted) return;
    try {
      await widget.onEditTiming?.call();
    } finally {
      if (mounted) {
        setState(() => _editingTiming = false);
        if (_opened || _audioError != null) await _startRound();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      if (_opened || _audioError != null) unawaited(_startRound());
    } else {
      _round++;
      _clock.stop();
      _ticker.stop();
      if (_opened) unawaited(_command('pause'));
    }
  }

  void _capture(PointerDownEvent event) {
    if (!_clock.isRunning) return;
    final delivered = Timeline.now - event.timeStamp.inMicroseconds;
    final raw =
        _now -
        (delivered > 0 && delivered <= 125000 ? delivered / 1000 * _rate : 0);
    if (raw < _measure / 2 || raw > _recording) return;
    final recent = _marks.where((at) => raw - at <= 1500).toList();
    setState(
      () => _marks = [...recent.skip(math.max(0, recent.length - 15)), raw],
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _clock.stop();
    _position.dispose();
    final file = _file;
    unawaited(
      _command('close').whenComplete(() async {
        if (file != null) await _delete(file);
      }),
    );
    super.dispose();
  }

  static Future<void> _delete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // The regular operating system cache cleanup can remove it.
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('延迟校准'),
      actions: [
        if (widget.onEditTiming != null)
          IconButton(
            tooltip: '判定时间窗',
            onPressed: _editingTiming ? null : _editTiming,
            icon: const Icon(Icons.tune),
          ),
        TextButton(
          onPressed: () =>
              Navigator.pop(context, (audio: _audioDelay, input: _inputDelay)),
          child: const Text('应用'),
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 3,
                  child: ClipRect(
                    child: CustomPaint(
                      painter: _CalibrationTrack(
                        _position,
                        _marks,
                        _audioDelay,
                        _inputDelay,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Listener(
                    key: const ValueKey('calibration-input'),
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: _capture,
                    child: ColoredBox(
                      color: const Color(0xFF292640),
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                '重拍时点击此处',
                                style: TextStyle(color: Colors.white),
                              ),
                              if (_marks.lastOrNull case final raw?) ...[
                                const SizedBox(height: 10),
                                Text(
                                  _timingLabel(
                                    calibrationError(raw, _inputDelay),
                                  ),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontSize: 21,
                                    color: Color(0xFFB9E9FF),
                                  ),
                                ),
                              ],
                              if (_audioError != null)
                                Text(
                                  _audioError!,
                                  style: const TextStyle(
                                    color: Color(0xFFFFD78B),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          _slider('音频延迟（正值使画面延后）', _audioDelay, (value) {
            setState(() {
              _audioDelay = value;
              _marks = const [];
            });
            _position.value = _now;
          }),
          _slider(
            '输入延迟补偿（正值补回晚按）',
            _inputDelay,
            (value) => setState(() => _inputDelay = value),
          ),
        ],
      ),
    ),
  );

  Widget _slider(String label, int value, ValueChanged<int> update) => Row(
    children: [
      Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: ChartMillisecondInput(
            label: label,
            value: value,
            min: -500,
            max: 500,
            onChanged: update,
          ),
        ),
      ),
      Expanded(
        child: Slider(
          min: -500,
          max: 500,
          divisions: 1000,
          value: value.toDouble(),
          onChanged: (next) => update(next.round()),
        ),
      ),
    ],
  );
}

String _timingLabel(double offset) {
  final rounded = offset.round();
  if (rounded == 0) return 'PURE · 0 ms';
  return '${rounded > 0 ? 'EARLY' : 'LATE'} ${rounded.abs()} ms';
}

class _CalibrationTrack extends CustomPainter {
  _CalibrationTrack(this.position, this.marks, this.audioDelay, this.inputDelay)
    : super(repaint: position);
  final ValueNotifier<double> position;
  final List<double> marks;
  final int audioDelay, inputDelay;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final time = position.value;
    final g = PerspectiveGeometry(size, time, 1700, playbackLanes: 0);
    final paint = Paint();
    canvas.drawRect(Offset.zero & size, paint..color = const Color(0xFF151A2D));
    void band(
      double left,
      double right,
      double head,
      double tail,
      Color color,
    ) {
      canvas.drawPath(
        Path()..addPolygon([
          g.project(left, 0, head),
          g.project(right, 0, head),
          g.project(right, 0, tail),
          g.project(left, 0, tail),
        ], true),
        paint
          ..color = color
          ..style = PaintingStyle.fill,
      );
    }

    void line(double at, Color color, double width) {
      canvas.drawLine(
        g.project(0, .02, at),
        g.project(1, .02, at),
        paint
          ..color = color
          ..strokeWidth = width,
      );
    }

    band(0, 1, g.near, g.far, const Color(0xFF222E47));
    for (var lane = 0; lane <= 4; lane++) {
      canvas.drawLine(
        g.project(lane / 4, 0, g.near),
        g.project(lane / 4, 0, g.far),
        paint
          ..color = const Color(0xFF7182A5)
          ..strokeWidth = 1,
      );
    }
    final next = math.max(1, ((time - 150) / _measure).ceil());
    for (var bar = next; bar <= _drumBars && bar * _measure <= g.far; bar++) {
      final at = bar * _measure.toDouble();
      if (at >= g.near) {
        band(
          .395,
          .605,
          math.max(at - 24, g.near),
          at + 24,
          const Color(0xFF82ECD4),
        );
      }
    }
    line(time, const Color(0xFFFFD897), 3);
    for (final mark in marks) {
      final end = calibrationLineEnd(mark, audioDelay);
      if (time < mark || time >= end) continue;
      final opacity = (1 - (time - mark) / (end - mark)).clamp(0.0, 1.0);
      final offset = calibrationError(mark, inputDelay);
      line(
        time + offset,
        const Color(0xFFB9E9FF).withValues(alpha: opacity),
        2.5,
      );
    }
  }

  @override
  bool shouldRepaint(_CalibrationTrack oldDelegate) =>
      oldDelegate.marks != marks ||
      oldDelegate.audioDelay != audioDelay ||
      oldDelegate.inputDelay != inputDelay;
}
