import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../services/arc_storage.dart';
import '../services/file_service.dart';
import 'chart_note_mesh.dart';

const chartArcColors = [
  Color(0xFF83A7FF),
  Color(0xFFF48FAE),
  Color(0xFF9FE79A),
  Color(0xFFC6DAFF),
];
const chartArcHalfWidth = 0.9 / 8.5;

enum ChartSprite {
  background('background', [
    'background.jpg',
    'background.png',
    'bg.jpg',
    'bg.png',
  ]),
  track('track', ['track.png']),
  tap('tap', ['note.png', 'tap.png']),
  hold('hold', ['note_hold.png', 'hold.png']),
  arc('arc', ['arc_body.png', 'arc.png']),
  arcTap('arcTap', ['arctap.png', 'arc_cap.png']),
  designant('designant', ['tap_tomato.png', 'designant.png']),
  flick('flick', ['flick.png']),
  judgement('judgement', ['track_critical_line.png', 'judgement.png']),
  skyLine('skyLine', ['red_air_line.png', 'skyline.png']),
  extraTrack('extraTrack', ['track_extralane.png']),
  intersection('intersection', ['height_indicator.png']),
  hitEffect('hitEffect', ['touch_effect.png', 'lane_hit.png']),
  hitPure('hitPure', ['hit_pure.png']),
  hitFar('hitFar', ['hit_far.png']),
  hitLost('hitLost', ['hit_lost.png']),
  hitEarly('hitEarly', ['hit_early.png', 'early.png']),
  hitLate('hitLate', ['hit_late.png', 'late.png']),
  pauseButton('pauseButton', ['btn-pause-active.png']),
  shutterLeft('shutterLeft', ['shutter_l.png']),
  shutterRight('shutterRight', ['shutter_r.png']),
  practiceStats('practiceStats', ['score-banner-s.png']);

  const ChartSprite(this.key, this.names);

  final String key;
  final List<String> names;
}

/// Decoded once when opening a chart, shared by the editor and both previews.
class ChartSkin {
  const ChartSkin._(
    this._textures, [
    this.meshes = const {},
    this._snakeTextures = const [],
  ]);

  static const defaults = ChartSkin._({});
  final Map<ChartSprite, ChartTexture> _textures;
  final Map<ChartSprite, ChartNoteMesh> meshes;
  final List<ChartTexture> _snakeTextures;
  static final _sharedArtwork =
      <
        ({String storage, int revision, int size, String candidates}),
        Uint8List
      >{};
  static int _sharedBytes = 0;
  static const _sharedBudget = 8 * 1024 * 1024;

  ChartTexture? operator [](ChartSprite name) => _textures[name];
  ChartTexture? snakeTexture(int color, {bool shaded = false}) =>
      _snakeTextures.isEmpty
      ? null
      : _snakeTextures[2 * (color % chartArcColors.length) + (shaded ? 1 : 0)];

  static final _imagePath = RegExp(
    r'^(?:[a-zA-Z0-9_. -]+/)*[a-zA-Z0-9_. -]+\.(?:png|jpg|jpeg|webp)$',
    caseSensitive: false,
  );

  static Future<ChartSkin> load({
    ArcStorage? folder,
    ArcStorage? root,
    String? chartKey,
    int side = 0,
    List<String> backgrounds = const [],
    Iterable<String>? knownFiles,
  }) async {
    final names = backgrounds.where(FileService.isBackgroundId).toSet();
    final folderFiles = <String>{...?knownFiles};
    if (folder != null && knownFiles == null) {
      try {
        folderFiles.addAll(
          (await folder.list())
              .where((entry) => entry.kind == EntryKind.file)
              .map((entry) => entry.name),
        );
      } catch (_) {
        // A chart can still use library artwork or the built-in palette.
      }
    }
    final songSkin = await _manifest(folder, folderFiles, 'skin.json');
    final chartSkin = chartKey == null
        ? const <String, String>{}
        : await _manifest(folder, folderFiles, '$chartKey.skin.json');
    final scene = names.firstOrNull ?? '';
    final variant = switch (scene) {
      'arcanaeden' => 'arcana',
      'yugamu' => 'dark',
      _ when scene.startsWith('finale_') => 'finale',
      _ when scene.startsWith('nijuusei') && side == 1 => 'dark_nijuusei',
      _ => scene,
    };
    final dark =
        scene.endsWith('_conflict') ||
        scene.contains('-conflict') ||
        (side == 1 && !scene.endsWith('_light') && !scene.contains('-light'));
    final sideTrack = switch (side) {
      2 => 'track_colorless.png',
      3 => 'track_black.png',
      _ => dark ? 'track_dark.png' : 'track.png',
    };

    final entries = await Future.wait(
      ChartSprite.values.map((sprite) async {
        final local = <String>{
          ?chartSkin[sprite.key],
          if (chartKey != null)
            for (final name in sprite.names)
              if (folderFiles.contains('${chartKey}_$name'))
                '${chartKey}_$name',
          ?songSkin[sprite.key],
          if (sprite == ChartSprite.background)
            for (final id in names)
              for (final extension in ['jpg', 'png', 'webp'])
                if (folderFiles.contains('$id.$extension')) '$id.$extension',
          ...sprite.names.where(folderFiles.contains),
        };
        final library = switch (sprite) {
          ChartSprite.background => [
            for (final id in names)
              for (final directory in ['img/bg/1080', 'img/bg'])
                for (final extension in ['jpg', 'png', 'webp'])
                  '$directory/$id.$extension',
            if (side == 2) 'img/bg_colorless.jpg',
            if (side == 3) 'img/1080/bg_lephon.jpg',
            'img/bg/1080/base_${dark ? 'conflict' : 'light'}.jpg',
            'img/bg/base_${dark ? 'conflict' : 'light'}.jpg',
          ],
          ChartSprite.track => [
            if (variant.isNotEmpty) 'img/track_$variant.png',
            'img/$sideTrack',
          ],
          ChartSprite.tap => [if (dark) 'img/note_dark.png', 'img/note.png'],
          ChartSprite.hold => [
            if (dark) 'img/note_hold_dark.png',
            'img/note_hold.png',
          ],
          ChartSprite.arc => ['img/arc_body.png'],
          ChartSprite.arcTap => [
            'models/tap_${dark ? 'd' : 'l'}.png',
            'img/arc_cap.png',
          ],
          ChartSprite.designant => ['models/tap_tomato.png'],
          ChartSprite.flick => ['img/flick.png'],
          ChartSprite.judgement => [
            if (side == 2) 'img/track_critical_line_colorless.png',
            'img/track_critical_line.png',
          ],
          ChartSprite.skyLine => ['img/red_air_line.png'],
          ChartSprite.extraTrack => [
            'img/track_extralane_${dark ? 'dark' : 'light'}.png',
          ],
          ChartSprite.intersection => ['img/height_indicator.png'],
          ChartSprite.hitEffect => [
            'img/touch_effect.png',
            'img/lane_hit.png',
            'particle/note_${dark ? 'conflict' : 'light'}.png',
          ],
          ChartSprite.hitPure ||
          ChartSprite.hitFar ||
          ChartSprite.hitLost ||
          ChartSprite.hitEarly ||
          ChartSprite.hitLate => [for (final name in sprite.names) 'img/$name'],
          ChartSprite.pauseButton => ['layouts/ingame/btn-pause-active.png'],
          ChartSprite.shutterLeft ||
          ChartSprite.shutterRight => ['img/${sprite.names.single}'],
          ChartSprite.practiceStats => ['img/results/score-banner-s.png'],
        };
        final dimension = switch (sprite) {
          ChartSprite.background => Platform.isAndroid ? 1280 : 1600,
          ChartSprite.arc => 256,
          ChartSprite.pauseButton => 128,
          ChartSprite.practiceStats => 512,
          _ => 1024,
        };
        final texture =
            await _loadTexture(folder, local.toList(), dimension) ??
            await _loadTexture(root, library, dimension, shared: true);
        return (sprite, texture);
      }),
    );
    Future<ChartNoteMesh?> mesh(String local, String fallback) async {
      for (final name in [if (chartKey != null) '${chartKey}_$local', local]) {
        if (!folderFiles.contains(name)) continue;
        final model = await ChartNoteMesh.load(folder, name);
        if (model != null) return model;
      }
      return ChartNoteMesh.load(root, fallback);
    }

    final models = await Future.wait([
      mesh('arctap.obj', 'models/tap_${dark ? 'd' : 'l'}.obj'),
      mesh('designant.obj', 'models/tap_tomato.obj'),
    ]);
    final textures = {for (final (name, texture) in entries) name: ?texture};
    return ChartSkin._(textures, {
      ChartSprite.arcTap: ?models[0],
      ChartSprite.designant: ?models[1],
    }, await _snakePalette(textures[ChartSprite.arc]));
  }

  static Future<List<ChartTexture>> _snakePalette(ChartTexture? texture) async {
    if (texture == null) return const [];
    final images = <ChartTexture>[];
    try {
      final image = texture.image;
      final rgba = (await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      ))!.buffer.asUint8List();
      for (final color in chartArcColors) {
        for (final shade in [1.0, 0.76]) {
          final pixels = Uint8List(rgba.length);
          for (var i = 0; i < rgba.length; i += 4) {
            final luminance =
                (rgba[i] * 0.2126 +
                    rgba[i + 1] * 0.7152 +
                    rgba[i + 2] * 0.0722) /
                255;
            final light = (0.32 + luminance * 0.68) * shade * rgba[i + 3];
            pixels[i] = (color.r * light).round();
            pixels[i + 1] = (color.g * light).round();
            pixels[i + 2] = (color.b * light).round();
            pixels[i + 3] = rgba[i + 3];
          }
          final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
          try {
            final descriptor = ui.ImageDescriptor.raw(
              buffer,
              width: image.width,
              height: image.height,
              pixelFormat: ui.PixelFormat.rgba8888,
            );
            try {
              final codec = await descriptor.instantiateCodec();
              try {
                images.add(ChartTexture((await codec.getNextFrame()).image));
              } finally {
                codec.dispose();
              }
            } finally {
              descriptor.dispose();
            }
          } finally {
            buffer.dispose();
          }
        }
      }
      return images;
    } catch (_) {
      for (final image in images) {
        image.dispose();
      }
      return const [];
    }
  }

  static Future<Map<String, String>> _manifest(
    ArcStorage? folder,
    Set<String> names,
    String manifest,
  ) async {
    if (folder == null || !names.contains(manifest)) return const {};
    try {
      final bytes = await folder.read(manifest);
      if (bytes.length > 16 * 1024) return const {};
      final data = jsonDecode(utf8.decode(bytes));
      if (data is! Map<String, dynamic>) return const {};
      return {
        for (final entry in data.entries)
          if (entry.value case final String name
              when _imagePath.hasMatch(name) &&
                  !name.split('/').any((part) => part == '..' || part == '.'))
            entry.key: name,
      };
    } catch (_) {
      return const {};
    }
  }

  static Future<ChartTexture?> _loadTexture(
    ArcStorage? storage,
    List<String> names,
    int maxDimension, {
    bool shared = false,
  }) async {
    if (storage == null || names.isEmpty) return null;
    final bytes = await _tryArtwork(
      storage,
      names,
      maxDimension,
      shared: shared,
    );
    if (bytes == null) return null;
    final decoded = await _decode(bytes, maxDimension);
    if (decoded != null || names.length == 1) return decoded;
    // A corrupt override may have hidden a usable lower-priority image.
    for (final name in names) {
      final bytes = await _tryArtwork(storage, [name], maxDimension);
      if (bytes == null) continue;
      final image = await _decode(bytes, maxDimension);
      if (image != null) return image;
    }
    return null;
  }

  static Future<Uint8List?> _tryArtwork(
    ArcStorage storage,
    List<String> names,
    int size, {
    bool shared = false,
  }) async {
    try {
      final key = (
        storage: storage.identity,
        revision: storage.artworkVersion,
        size: size,
        candidates: names.join('\n'),
      );
      if (shared) {
        if (_sharedArtwork.remove(key) case final previous?) {
          _sharedArtwork[key] = previous;
          return previous;
        }
      }
      final bytes = await storage.readArtwork(names, size);
      if (shared && bytes.length <= _sharedBudget ~/ 2) {
        _sharedBytes -= _sharedArtwork.remove(key)?.length ?? 0;
        _sharedArtwork[key] = bytes;
        _sharedBytes += bytes.length;
        while (_sharedBytes > _sharedBudget || _sharedArtwork.length > 40) {
          _sharedBytes -= _sharedArtwork
              .remove(_sharedArtwork.keys.first)!
              .length;
        }
      }
      return bytes;
    } catch (_) {
      return null;
    }
  }

  static Future<ChartTexture?> _decode(
    Uint8List bytes,
    int maxDimension,
  ) async {
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      try {
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        try {
          final scale = math.min(
            1.0,
            maxDimension / math.max(descriptor.width, descriptor.height),
          );
          final codec = await descriptor.instantiateCodec(
            targetWidth: math.max(1, (descriptor.width * scale).round()),
            targetHeight: math.max(1, (descriptor.height * scale).round()),
          );
          try {
            return ChartTexture((await codec.getNextFrame()).image);
          } finally {
            codec.dispose();
          }
        } finally {
          descriptor.dispose();
        }
      } finally {
        buffer.dispose();
      }
    } catch (_) {
      return null;
    }
  }

  void paintBackground(Canvas canvas, Size size, {required bool flat}) {
    final bounds = Offset.zero & size;
    if (this[ChartSprite.background] case final texture?) {
      paintImage(
        canvas: canvas,
        rect: bounds,
        image: texture.image,
        fit: BoxFit.cover,
      );
      canvas.drawRect(
        bounds,
        Paint()..color = Color(flat ? 0xAA0C1325 : 0x330C1325),
      );
    } else {
      canvas.drawRect(
        bounds,
        Paint()
          ..shader = const RadialGradient(
            center: Alignment(0, -0.5),
            radius: 1.05,
            colors: [Color(0xFF42415E), Color(0xFF181F38), Color(0xFF101625)],
          ).createShader(bounds),
      );
    }
  }

  void dispose() {
    for (final texture in _snakeTextures) {
      texture.dispose();
    }
    for (final texture in _textures.values) {
      texture.dispose();
    }
  }
}

class ChartTexture {
  ChartTexture(this.image);

  final ui.Image image;
  ui.ImageShader? _shader;
  ui.ImageShader get _imageShader => _shader ??= ui.ImageShader(
    image,
    TileMode.clamp,
    TileMode.repeated,
    Matrix4.identity().storage,
    filterQuality: FilterQuality.low,
  );

  void draw(
    Canvas canvas,
    Rect target, {
    double alpha = 1,
    double fromY = 0,
    double toY = 1,
    bool flipY = false,
  }) {
    if (flipY) {
      canvas.save();
      canvas.translate(0, target.top + target.bottom);
      canvas.scale(1, -1);
    }
    canvas.drawImageRect(
      image,
      Rect.fromLTRB(
        0,
        image.height * fromY,
        image.width.toDouble(),
        image.height * toY,
      ),
      target,
      Paint()
        ..filterQuality = FilterQuality.low
        ..color = Colors.white.withValues(alpha: alpha),
    );
    if (flipY) canvas.restore();
  }

  void triangles(
    Canvas canvas,
    List<Offset> points,
    List<Offset> uv,
    List<Color> shades,
    double alpha,
  ) {
    final vertices = ui.Vertices(
      ui.VertexMode.triangles,
      points,
      textureCoordinates: [
        for (final p in uv) Offset(p.dx * image.width, p.dy * image.height),
      ],
      colors: shades,
    );
    canvas.drawVertices(
      vertices,
      BlendMode.modulate,
      Paint()
        ..shader = _imageShader
        ..color = Colors.white.withValues(alpha: alpha),
    );
    vertices.dispose();
  }

  /// Paints a texture on pairs of left/right points along a projected surface.
  void strip(
    Canvas canvas,
    List<Offset> points, {
    double alpha = 1,
    double start = 0,
    double end = 1,
    Color? tint,
  }) {
    final rows = points.length ~/ 2;
    final texels = <Offset>[];
    for (var row = 0; row < rows; row++) {
      final y = (start + (end - start) * row / (rows - 1)) * image.height;
      texels.addAll([Offset(0, y), Offset(image.width.toDouble(), y)]);
    }
    final vertices = ui.Vertices(
      ui.VertexMode.triangleStrip,
      points,
      textureCoordinates: texels,
    );
    canvas.drawVertices(
      vertices,
      BlendMode.src,
      Paint()
        ..shader = _imageShader
        ..color = Colors.white.withValues(alpha: alpha)
        ..colorFilter = tint == null
            ? null
            : ColorFilter.mode(tint, BlendMode.modulate),
    );
    vertices.dispose();
  }

  void dispose() {
    _shader?.dispose();
    image.dispose();
  }
}
