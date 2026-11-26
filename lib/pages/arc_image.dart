import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../services/arc_storage.dart';

typedef _ArtworkKey = ({
  ArcStorage storage,
  String paths,
  int width,
  int revision,
});

class _ArtworkProvider extends ImageProvider<_ArtworkKey> {
  final _ArtworkKey key;

  const _ArtworkProvider(this.key);

  @override
  Future<_ArtworkKey> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(key);

  @override
  ImageStreamCompleter loadImage(
    _ArtworkKey key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(codec: _load(key, decode), scale: 1);

  Future<ui.Codec> _load(_ArtworkKey key, ImageDecoderCallback decode) async {
    final data = await key.storage.readArtwork(
      key.paths.split('\n'),
      key.width,
    );
    return decode(await ui.ImmutableBuffer.fromUint8List(data));
  }
}

class ArcImage extends StatelessWidget {
  final List<String> candidates;
  final BoxFit fit;
  final Widget fallback;
  final int? cacheWidth;
  final ArcStorage? storage;

  const ArcImage({
    super.key,
    required this.candidates,
    required this.fallback,
    this.fit = BoxFit.cover,
    this.cacheWidth,
    this.storage,
  });

  @override
  Widget build(BuildContext context) {
    final library = storage == null
        ? context.select(
            (AppState state) => (
              storage: state.hasPath ? state.fileService.storage : null,
              revision: state.artworkRevision,
            ),
          )
        : (storage: storage, revision: storage!.artworkVersion);
    final source = library.storage;
    if (source == null || candidates.isEmpty) return fallback;

    final key = (
      storage: source,
      paths: candidates.join('\n'),
      width: cacheWidth ?? 640,
      revision: library.revision,
    );
    return Image(
      image: ResizeImage(
        _ArtworkProvider(key),
        width: key.width,
        allowUpscaling: false,
      ),
      fit: fit,
      gaplessPlayback: false,
      frameBuilder: (_, child, frame, synchronous) =>
          frame != null || synchronous ? child : fallback,
      errorBuilder: (_, _, _) => fallback,
    );
  }
}
