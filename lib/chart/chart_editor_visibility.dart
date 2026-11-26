import 'aff_chart.dart';

enum ChartDisplayItem {
  tap('地键'),
  hold('长按'),
  snake('蛇'),
  trace('弧线与蛇内辅助线'),
  skyTap('天键'),
  flick('滑键'),
  timing('BPM 标记');

  const ChartDisplayItem(this.label);
  final String label;
}

typedef ChartPick = ({AffEvent note, int? tap});

extension ChartArcDisplay on AffEvent {
  bool get standaloneSky =>
      kind == AffKind.arc &&
      start == end &&
      (variableArcTap || arcTaps.isNotEmpty);
}

class ChartEditorVisibility {
  const ChartEditorVisibility({
    this.items = const {...ChartDisplayItem.values},
    this.onlySelected = false,
    this.selection = const {},
    this.attachedTap,
  });

  final Set<ChartDisplayItem> items;
  final bool onlySelected;
  final Set<AffEvent> selection;
  final ChartPick? attachedTap;

  bool selected(AffEvent note, {int? tap}) {
    if (!selection.contains(note)) return false;
    return attachedTap?.note == note
        ? tap == attachedTap?.tap
        : tap == null || note.standaloneSky;
  }

  bool shows(AffEvent note, {int? tap}) {
    final item = switch (note.kind) {
      AffKind.tap => ChartDisplayItem.tap,
      AffKind.hold => ChartDisplayItem.hold,
      AffKind.flick => ChartDisplayItem.flick,
      AffKind.timing => ChartDisplayItem.timing,
      AffKind.arc when tap != null || note.variableArcTap =>
        ChartDisplayItem.skyTap,
      AffKind.arc when note.standaloneSky => null,
      AffKind.arc =>
        note.trace ? ChartDisplayItem.trace : ChartDisplayItem.snake,
      _ => null,
    };
    return items.contains(item) && (!onlySelected || selected(note, tap: tap));
  }

  bool showsGuide(AffEvent note) =>
      !note.trace &&
      !note.variableArcTap &&
      items.contains(ChartDisplayItem.trace) &&
      shows(note);
}
