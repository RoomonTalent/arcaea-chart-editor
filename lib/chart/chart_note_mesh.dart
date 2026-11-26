import 'dart:convert';

import 'package:flutter/material.dart';

import '../services/arc_storage.dart';

typedef MeshPoint = ({double x, double y, double z});
typedef MeshVertex = ({MeshPoint point, Offset uv});

class ChartNoteMesh {
  const ChartNoteMesh(this.triangles);

  final List<List<MeshVertex>> triangles;

  static Future<ChartNoteMesh?> load(ArcStorage? storage, String path) async {
    if (storage == null) return null;
    try {
      if (await storage.kind(path) != EntryKind.file) return null;
      final bytes = await storage.read(path);
      if (bytes.length > 192 * 1024) return null;
      return ChartNoteMesh.parse(utf8.decode(bytes));
    } catch (_) {
      return null;
    }
  }

  factory ChartNoteMesh.parse(String text) {
    final points = <MeshPoint>[];
    final uv = <Offset>[];
    final triangles = <List<MeshVertex>>[];
    double coordinate(String text) {
      final value = double.parse(text);
      if (!value.isFinite || value.abs() > 16) {
        throw const FormatException('无效的 OBJ 坐标');
      }
      return value;
    }

    for (final line in const LineSplitter().convert(text)) {
      final tokens = line.split('#').first.trim().split(RegExp(r'\s+'));
      switch (tokens.first) {
        case 'v':
          points.add((
            x: coordinate(tokens[1]),
            y: coordinate(tokens[2]),
            z: coordinate(tokens[3]),
          ));
        case 'vt':
          uv.add(Offset(coordinate(tokens[1]), 1 - coordinate(tokens[2])));
        case 'f':
          final face = [for (final token in tokens.skip(1)) token.split('/')];
          MeshVertex getVertex(List<String> index) {
            final vertex = int.parse(index[0]);
            final texel = int.parse(index[1]);
            return (
              point: points[vertex < 0 ? points.length + vertex : vertex - 1],
              uv: uv[texel < 0 ? uv.length + texel : texel - 1],
            );
          }
          for (var i = 2; i < face.length; i++) {
            if (triangles.length >= 96) throw const FormatException('空键模型面数过多');
            triangles.add([
              getVertex(face[0]),
              getVertex(face[i - 1]),
              getVertex(face[i]),
            ]);
          }
      }
    }
    if (triangles.isEmpty) throw const FormatException('空键模型没有可用的纹理面');
    return ChartNoteMesh(List.unmodifiable(triangles));
  }
}
