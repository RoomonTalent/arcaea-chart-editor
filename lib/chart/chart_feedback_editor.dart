import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import 'aff_chart.dart';
import 'chart_feedback.dart';
import 'chart_perspective.dart';
import 'chart_playback_view.dart';
import 'chart_skin.dart';
import 'chart_timeline.dart';

class ChartFeedbackEditor extends StatefulWidget {
  const ChartFeedbackEditor({
    super.key,
    required this.initial,
    required this.skin,
    required this.perspective,
    required this.overlay,
    required this.laneMode,
    this.playbackView = defaultChartPlaybackView,
    this.timing,
  });

  final FeedbackSettings initial;
  final ValueListenable<ChartSkin>? skin;
  final bool perspective, overlay;
  final ChartLaneMode laneMode;
  final ChartPlaybackView playbackView;
  final PracticeWindows? timing;

  @override
  State<ChartFeedbackEditor> createState() => _ChartFeedbackEditorState();
}

class _ChartFeedbackEditorState extends State<ChartFeedbackEditor> {
  static final _demo = ChartTimeline(
    AffChart.parse(
      '${AffChart.blank}arc(0,0,0.5,0.5,s,0.7,0.7,0,none,true)[arctap(0)];',
    ),
  );
  static const _samples = [16.0, -42.0, 76.0, -112.0];
  final _cursor = ValueNotifier(0.0);
  late FeedbackSettings _draft = widget.initial;
  FeedbackItem? _selected;
  bool _settingsOpen = false;
  int _sample = 0;

  @override
  void dispose() {
    _cursor.dispose();
    super.dispose();
  }

  void _change(
    FeedbackItem item, {
    double? x,
    double? y,
    double? size,
    double? width,
    int? mode,
    bool? show,
  }) {
    final value = _draft[item];
    setState(
      () => _draft = FeedbackSettings({
        ..._draft.values,
        item: (
          x: x ?? value.x,
          y: y ?? value.y,
          size: size ?? value.size,
          width: width ?? value.width,
          mode: mode ?? value.mode,
          show: show ?? value.show,
        ),
      }),
    );
  }

  void _select(FeedbackItem item, {bool open = false}) {
    setState(() {
      _selected = item;
      if (open) _settingsOpen = true;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: ValueListenableBuilder(
      valueListenable:
          widget.skin ?? const AlwaysStoppedAnimation(ChartSkin.defaults),
      builder: (context, skin, _) => LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          if (size.isEmpty) return const SizedBox.shrink();
          final hit = widget.perspective
              ? PerspectiveGeometry.forPlayback(
                  size,
                  0,
                  2100,
                  _demo,
                  widget.laneMode,
                  view: widget.playbackView,
                ).projectArcTap(.5, .7, 0)
              : TimelineGeometry(
                  size,
                  0,
                  2100,
                  wideLanes: widget.laneMode == ChartLaneMode.six,
                  overlay: widget.overlay,
                ).arcTapBounds(.5, .7, 0).center;
          final result = PracticeJudgements()
            ..record(
              PracticeKey.air,
              _samples[_sample],
              0,
              hit,
              windows: widget.timing,
            )
            ..combo = 12;
          final panelWidth = math.min(358.0, size.width - 16);
          return Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _selected = null),
                child: CustomPaint(
                  painter: widget.perspective
                      ? ChartPerspectivePainter(
                          _demo,
                          _cursor,
                          2100,
                          skin: skin,
                          laneMode: widget.laneMode,
                          playbackFraming: true,
                          playbackView: widget.playbackView,
                        )
                      : ChartTimelinePainter(
                          _demo,
                          _cursor,
                          2100,
                          skin: skin,
                          laneMode: widget.laneMode,
                          preview: true,
                          overlay: widget.overlay,
                        ),
                  foregroundPainter: PracticeFeedbackPainter(
                    _cursor,
                    result,
                    _draft,
                    skin,
                    const AlwaysStoppedAnimation(0),
                    preview: true,
                  ),
                  size: Size.infinite,
                ),
              ),
              for (final item in [
                ...FeedbackItem.values.where((item) => item != _selected),
                ?_selected,
              ])
                _element(item, size, hit),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  bottom: false,
                  minimum: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  child: _toolbar(result.history.single.grade),
                ),
              ),
              if (_settingsOpen)
                Positioned(
                  top: MediaQuery.paddingOf(context).top + 54,
                  left: 8,
                  width: math.max(1, panelWidth),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: size.height * .62),
                    child: _settingsPanel(),
                  ),
                ),
            ],
          );
        },
      ),
    ),
  );

  Widget _element(FeedbackItem item, Size size, Offset hit) {
    final value = _draft[item];
    final selected = _selected == item;
    final bounds = practiceFeedbackBounds(item, _draft, size, hit: hit);
    final area = bounds.inflate(6).intersect(Offset.zero & size);
    return Positioned.fromRect(
      key: ValueKey(item),
      rect: area,
      child: Semantics(
        label: '${item.label}${value.show ? '' : '（已关闭）'}',
        selected: selected,
        button: true,
        child: GestureDetector(
          key: ValueKey('feedback-element-${item.name}'),
          behavior: HitTestBehavior.opaque,
          onTap: () => _select(item),
          onSecondaryTap: () => _select(item, open: true),
          onDoubleTap: () => _select(item, open: true),
          onLongPress: () => _select(item, open: true),
          onPanStart: value.show && value.mode == 2
              ? (_) => _select(item)
              : null,
          onPanUpdate: value.show && value.mode == 2
              ? (event) {
                  final center =
                      practiceFeedbackBounds(
                        item,
                        _draft,
                        size,
                        hit: hit,
                      ).center +
                      event.delta;
                  _change(
                    item,
                    x: (center.dx / size.width).clamp(0, 1),
                    y: (center.dy / size.height).clamp(0, 1),
                  );
                }
              : null,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(
                color: selected
                    ? const Color(0xFF78E3D1)
                    : const Color(0x537C89A5),
                width: selected ? 1.5 : 1,
              ),
              borderRadius: BorderRadius.circular(5),
            ),
          ),
        ),
      ),
    );
  }

  Widget _toolbar(PracticeGrade grade) => Row(
    children: [
      IconButton.filledTonal(
        tooltip: '取消',
        onPressed: () => Navigator.pop(context),
        icon: const Icon(Icons.arrow_back),
      ),
      const SizedBox(width: 3),
      IconButton.filledTonal(
        tooltip: '详细设置',
        isSelected: _settingsOpen,
        onPressed: () => setState(() => _settingsOpen = !_settingsOpen),
        icon: const Icon(Icons.tune),
      ),
      if (_selected != null)
        IconButton(
          tooltip: '取消选中',
          onPressed: () => setState(() => _selected = null),
          icon: const Icon(Icons.deselect, color: Colors.white),
        ),
      const Spacer(),
      TextButton(
        onPressed: () =>
            setState(() => _sample = (_sample + 1) % _samples.length),
        style: TextButton.styleFrom(
          backgroundColor: const Color(0xDE141827),
          foregroundColor: grade.color,
        ),
        child: Text(grade.label),
      ),
      const SizedBox(width: 5),
      FilledButton(
        onPressed: () => Navigator.pop(context, _draft),
        child: const Text('应用'),
      ),
    ],
  );

  Widget _settingsPanel() => Material(
    key: const ValueKey('feedback-detail-panel'),
    elevation: 8,
    borderRadius: BorderRadius.circular(12),
    clipBehavior: Clip.antiAlias,
    child: SingleChildScrollView(
      key: ValueKey(_selected),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final item
              in _selected == null ? FeedbackItem.values : [_selected!]) ...[
            Text(item.label, style: Theme.of(context).textTheme.titleSmall),
            _itemSettings(item),
            if (_selected == null) const Divider(),
          ],
          TextButton(
            onPressed: () => setState(() {
              final selected = _selected;
              _draft = selected == null
                  ? const FeedbackSettings()
                  : FeedbackSettings({
                      ..._draft.values,
                      selected: selected.defaults,
                    });
            }),
            child: const Text('恢复默认'),
          ),
        ],
      ),
    ),
  );

  Widget _itemSettings(FeedbackItem item) {
    final value = _draft[item];
    Widget slider(
      String label,
      double current,
      double min,
      double max,
      ValueChanged<double> setter, {
      bool percent = false,
      String? id,
    }) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label ${percent ? '${(current * 100).round()}%' : current.round()}',
        ),
        Slider(
          key: id == null ? null : ValueKey('feedback-$id-${item.name}'),
          value: current.clamp(min, max),
          min: min,
          max: max,
          onChanged: setter,
        ),
      ],
    );

    return Column(
      children: [
        SwitchListTile(
          key: ValueKey('feedback-show-${item.name}'),
          title: const Text('显示'),
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: value.show,
          onChanged: (show) => _change(item, show: show),
        ),
        if (item == FeedbackItem.grade || item == FeedbackItem.timing)
          DropdownButton<int>(
            key: ValueKey('feedback-mode-${item.name}'),
            value: item == FeedbackItem.grade && value.mode == 1
                ? 0
                : value.mode,
            isExpanded: true,
            items: [
              DropdownMenuItem(
                value: 0,
                child: Text(item == FeedbackItem.grade ? '点击点上方' : '判定文字上方'),
              ),
              if (item == FeedbackItem.timing)
                const DropdownMenuItem(value: 1, child: Text('判定文字下方')),
              const DropdownMenuItem(value: 2, child: Text('自定义位置')),
            ],
            onChanged: (mode) => _change(item, mode: mode),
          ),
        if (value.mode == 2) ...[
          slider(
            '水平位置',
            value.x,
            0,
            1,
            (x) => _change(item, x: x),
            percent: true,
          ),
          slider(
            '垂直位置',
            value.y,
            0,
            1,
            (y) => _change(item, y: y),
            percent: true,
          ),
        ],
        if (item == FeedbackItem.bar)
          slider(
            '判定条宽度',
            value.width,
            .2,
            .95,
            (width) => _change(item, width: width),
            percent: true,
            id: 'width',
          ),
        slider(
          item == FeedbackItem.bar ? '判定条高度' : '文字大小',
          value.size,
          6,
          item == FeedbackItem.bar ? 40 : 88,
          (size) => _change(item, size: size),
          id: 'size',
        ),
      ],
    );
  }
}
