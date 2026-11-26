import 'package:flutter/material.dart';

import 'aff_chart.dart';

typedef ArcPoint = ({int time, double x, double height});

const arcCurves = ['s', 'b', 'si', 'so', 'sisi', 'siso', 'sosi', 'soso'];

/// A connected AFF arc remains a series of ordinary segments on disk.
class ArcDraft {
  ArcDraft({
    required this.points,
    this.trace = false,
    this.color = 0,
    this.sound = 'none',
    Map<int, String>? segments,
    Set<int>? taps,
    Map<int, List<int>>? originalTaps,
  }) : segments = segments ?? {},
       taps = taps ?? {},
       originalTaps = originalTaps ?? {};

  final List<ArcPoint> points;
  final Map<int, String> segments;
  final Set<int> taps;
  final Map<int, List<int>> originalTaps;
  bool trace;
  int color;
  final String sound;

  factory ArcDraft.fromEvents(List<AffEvent> events) {
    final first = events.first;
    return ArcDraft(
      points: [
        (time: first.start, x: first.number(2), height: first.number(5)),
        for (final event in events)
          (time: event.end, x: event.number(3), height: event.number(6)),
      ],
      trace: first.trace,
      color: first.number(7).toInt(),
      sound: first.arguments[8],
      segments: {for (final event in events) event.start: event.arguments[4]},
      taps: {for (final event in events) ...event.arcTaps},
      originalTaps: {
        for (final event in events) event.start: event.arcTaps.toList(),
      },
    );
  }

  List<String> encode() {
    final ordered = points.toList()..sort((a, b) => a.time.compareTo(b.time));
    return [
      for (var i = 1; i < ordered.length; i++)
        _segment(ordered[i - 1], ordered[i], i == ordered.length - 1),
    ];
  }

  void moveTap(int oldTime, int newTime) {
    if (oldTime == newTime) return;
    if (taps.remove(oldTime)) taps.add(newTime);
    for (final entries in originalTaps.values) {
      for (var i = 0; i < entries.length; i++) {
        if (entries[i] == oldTime) entries[i] = newTime;
      }
    }
    final oldSegment = originalTaps.remove(oldTime);
    if (oldSegment != null) originalTaps[newTime] = oldSegment;
  }

  String _segment(ArcPoint a, ArcPoint b, bool finalSegment) {
    bool ownedElsewhere(int t) {
      for (final entry in originalTaps.entries) {
        if (!entry.value.contains(t)) continue;
        final end = points
            .where((point) => point.time > entry.key)
            .firstOrNull
            ?.time;
        if (end != null &&
            points.any((point) => point.time == entry.key) &&
            t >= entry.key &&
            t <= end) {
          return true;
        }
      }
      return false;
    }

    final timing = [
      for (final t in originalTaps[a.time] ?? const <int>[])
        if (taps.contains(t) && t >= a.time && t <= b.time) t,
      for (final t in taps)
        if (t >= a.time &&
            (t < b.time || (finalSegment && t == b.time)) &&
            !ownedElsewhere(t))
          t,
    ]..sort();
    final suffix = timing.isEmpty
        ? ''
        : '[${timing.map((t) => 'arctap($t)').join(',')}]';
    return 'arc(${a.time},${b.time},${a.x},${b.x},${segments[a.time] ?? 's'},'
        '${a.height},${b.height},$color,$sound,$trace)$suffix;';
  }

  static List<AffEvent> connected(AffChart chart, AffEvent selected) {
    bool ordinary(AffEvent event) =>
        event.kind == AffKind.arc &&
        event.group == selected.group &&
        event.start < event.end &&
        event.arguments.length == 10 &&
        arcCurves.contains(event.arguments[4]) &&
        const {'true', 'false'}.contains(event.arguments[9]) &&
        event.arcTaps.every((t) => t >= event.start && t <= event.end);
    if (!ordinary(selected)) return const [];
    final same = chart.events
        .where(
          (event) =>
              ordinary(event) &&
              event.arguments[7] == selected.arguments[7] &&
              event.arguments[8] == selected.arguments[8] &&
              event.arguments[9] == selected.arguments[9],
        )
        .toList();
    bool joins(AffEvent a, AffEvent b) =>
        a.end == b.start &&
        (a.number(3) - b.number(2)).abs() < 0.00001 &&
        (a.number(6) - b.number(5)).abs() < 0.00001;
    final result = [selected];
    while (true) {
      final previous = same
          .where((event) => joins(event, result.first))
          .toList();
      if (previous.length != 1 ||
          same.where((event) => joins(previous.single, event)).length != 1) {
        break;
      }
      result.insert(0, previous.single);
    }
    while (true) {
      final next = same.where((event) => joins(result.last, event)).toList();
      if (next.length != 1 ||
          same.where((event) => joins(event, next.single)).length != 1) {
        break;
      }
      result.add(next.single);
    }
    return result;
  }
}

class ArcEditorPanel extends StatefulWidget {
  const ArcEditorPanel({super.key, required this.draft, this.editTaps = true});

  final ArcDraft draft;
  final bool editTaps;

  @override
  State<ArcEditorPanel> createState() => _ArcEditorPanelState();
}

class _ArcEditorPanelState extends State<ArcEditorPanel> {
  ArcDraft get draft => widget.draft;
  String? _error;

  Future<void> _point([ArcPoint? point]) async {
    final initial =
        point ?? (time: draft.points.last.time + 250, x: 0.5, height: 1.0);
    final result = await showDialog<ArcPoint>(
      context: context,
      builder: (_) => _ArcPointDialog(initial: initial),
    );
    if (!mounted || result == null) return;
    if (draft.points.any((p) => p != point && p.time == result.time)) {
      setState(() => _error = '每个关键点需要不同的时间');
      return;
    }
    setState(() {
      if (point != null) {
        draft.points.remove(point);
        final curve = draft.segments.remove(point.time);
        if (curve != null) draft.segments[result.time] = curve;
        if (widget.editTaps) draft.moveTap(point.time, result.time);
      }
      draft.points.add(result);
      draft.points.sort((a, b) => a.time.compareTo(b.time));
      _error = null;
    });
  }

  Future<void> _addTap() async {
    final result = await showDialog<int>(
      context: context,
      builder: (_) => _ArcPointDialog(
        initial: (time: draft.points.first.time, x: 0.0, height: 0.0),
        timingOnly: true,
      ),
    );
    if (!mounted || result == null) return;
    setState(() => draft.taps.add(result));
  }

  void _save() {
    if (draft.taps.any(
      (time) => time < draft.points.first.time || time > draft.points.last.time,
    )) {
      setState(() => _error = '空键时间必须位于弧线起点和终点之间');
      return;
    }
    Navigator.pop(context, draft.encode());
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('弧线关键点与判定'),
    content: SizedBox(
      width: 520,
      height: 420,
      child: ListView(
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: draft.trace,
            title: const Text('蛇轨'),
            subtitle: Text(draft.trace ? '只判定手动标记的空键' : '沿弧线持续判定'),
            onChanged: (value) => setState(() => draft.trace = value),
          ),
          DropdownButtonFormField<int>(
            initialValue: draft.color,
            decoration: const InputDecoration(labelText: '弧线颜色'),
            items: [
              for (final code in {0, 1, 2, 3, draft.color})
                DropdownMenuItem(
                  value: code,
                  child: Text(switch (code) {
                    0 => '蓝色',
                    1 => '红色',
                    2 => '绿色',
                    3 => '浅色',
                    _ => '$code',
                  }),
                ),
            ],
            onChanged: (value) => setState(() => draft.color = value!),
          ),
          if (_error case final error?)
            Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          for (var i = 0; i < draft.points.length; i++)
            ListTile(
              key: ValueKey(draft.points[i].time),
              contentPadding: EdgeInsets.zero,
              title: Text(
                '${draft.points[i].time} ms    X ${draft.points[i].x}    Y ${draft.points[i].height}',
              ),
              onTap: () => _point(draft.points[i]),
              subtitle: i == draft.points.length - 1
                  ? null
                  : Wrap(
                      children: [
                        DropdownButton<String>(
                          value: draft.segments[draft.points[i].time] ?? 's',
                          items: [
                            for (final curve in arcCurves)
                              DropdownMenuItem(
                                value: curve,
                                child: Text(curve),
                              ),
                          ],
                          onChanged: (curve) => setState(
                            () => draft.segments[draft.points[i].time] = curve!,
                          ),
                        ),
                      ],
                    ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '在此处判定空键',
                    isSelected: draft.taps.contains(draft.points[i].time),
                    onPressed: widget.editTaps && draft.trace
                        ? () => setState(() {
                            final time = draft.points[i].time;
                            if (!draft.taps.remove(time)) draft.taps.add(time);
                          })
                        : null,
                    icon: const Icon(Icons.flag_outlined),
                    selectedIcon: const Icon(Icons.flag),
                  ),
                  IconButton(
                    tooltip: '删除关键点',
                    onPressed: draft.points.length < 3
                        ? null
                        : () => setState(() => draft.points.removeAt(i)),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
            ),
          Wrap(
            spacing: 6,
            children: [
              TextButton(onPressed: _point, child: const Text('添加关键点')),
              TextButton(
                onPressed: widget.editTaps && draft.trace ? _addTap : null,
                child: const Text('指定空键时间'),
              ),
            ],
          ),
          if (draft.taps.isNotEmpty)
            Wrap(
              spacing: 6,
              children: [
                for (final time in draft.taps.toList()..sort())
                  InputChip(
                    label: Text('$time ms'),
                    onDeleted: widget.editTaps
                        ? () => setState(() => draft.taps.remove(time))
                        : null,
                  ),
              ],
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _save, child: const Text('应用')),
    ],
  );
}

class _ArcPointDialog extends StatefulWidget {
  const _ArcPointDialog({required this.initial, this.timingOnly = false});

  final ArcPoint initial;
  final bool timingOnly;

  @override
  State<_ArcPointDialog> createState() => _ArcPointDialogState();
}

class _ArcPointDialogState extends State<_ArcPointDialog> {
  final _form = GlobalKey<FormState>();
  late int _time = widget.initial.time;
  late double _x = widget.initial.x, _y = widget.initial.height;

  Widget _field(
    String label,
    num initial,
    void Function(num) save, {
    bool whole = false,
  }) => TextFormField(
    initialValue: '$initial',
    decoration: InputDecoration(labelText: label),
    keyboardType: TextInputType.numberWithOptions(
      decimal: !whole,
      signed: true,
    ),
    validator: (text) {
      final value = whole
          ? int.tryParse(text!.trim())
          : double.tryParse(text!.trim());
      return value == null || !value.isFinite || value.abs() > 0x7fffffff
          ? '请输入有效数值'
          : null;
    },
    onSaved: (text) => save(num.parse(text!.trim())),
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.timingOnly ? '空键判定时间' : '关键点'),
    scrollable: true,
    content: Form(
      key: _form,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _field(
            '时间（毫秒）',
            _time,
            (value) => _time = value.toInt(),
            whole: true,
          ),
          if (!widget.timingOnly) ...[
            _field('X 坐标', _x, (value) => _x = value.toDouble()),
            _field('Y 高度', _y, (value) => _y = value.toDouble()),
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
        onPressed: () {
          if (!_form.currentState!.validate()) return;
          _form.currentState!.save();
          Navigator.pop(
            context,
            widget.timingOnly ? _time : (time: _time, x: _x, height: _y),
          );
        },
        child: const Text('应用'),
      ),
    ],
  );
}
