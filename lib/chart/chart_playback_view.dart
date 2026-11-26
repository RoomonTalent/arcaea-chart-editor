import 'dart:convert';

typedef ChartPlaybackView = ({
  double width,
  double length,
  double pitch,
  double height,
  double runout,
  double skyHeight,
});

const defaultChartPlaybackView = (
  width: 1.0,
  length: 1.0,
  pitch: 0.0,
  height: 0.0,
  runout: 1.0,
  skyHeight: 1.0,
);

enum ChartViewAxis {
  width('轨道宽度', '×', .65, 1.3),
  length('轨道总长度', '×', .6, 1.8),
  pitch('俯仰角调整', '°', -14, 18),
  height('轨道高度', '%', -12, 20),
  runout('判定线后轨道长度', '×', 0, 2.4),
  skyHeight('天空判定线高度', '×', .55, 1.55);

  const ChartViewAxis(this.label, this.unit, this.min, this.max);
  final String label, unit;
  final double min, max;

  double value(ChartPlaybackView view) => switch (this) {
    width => view.width,
    length => view.length,
    pitch => view.pitch,
    height => view.height,
    runout => view.runout,
    skyHeight => view.skyHeight,
  };
}

String encodeChartPlaybackView(ChartPlaybackView view) => jsonEncode({
  for (final axis in ChartViewAxis.values) axis.name: axis.value(view),
});

ChartPlaybackView decodeChartPlaybackView(String? data) {
  final Map<String, dynamic> values;
  try {
    final decoded = data == null ? null : jsonDecode(data);
    values = decoded is Map<String, dynamic> ? decoded : const {};
  } on FormatException {
    return defaultChartPlaybackView;
  }
  double read(ChartViewAxis axis) {
    final value = values[axis.name];
    return value is num && value.isFinite
        ? value.toDouble()
        : axis.value(defaultChartPlaybackView);
  }

  return (
    width: read(ChartViewAxis.width),
    length: read(ChartViewAxis.length),
    pitch: read(ChartViewAxis.pitch),
    height: read(ChartViewAxis.height),
    runout: read(ChartViewAxis.runout),
    skyHeight: read(ChartViewAxis.skyHeight),
  );
}
