import 'dart:convert';
import 'dart:typed_data';

import 'package:arcaea_manager/pages/arc_image.dart';
import 'package:arcaea_manager/services/arc_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _ArtworkStorage extends ArcStorage {
  _ArtworkStorage() : super('fixture');

  int reads = 0;

  @override
  Future<Uint8List> readArtwork(List<String> candidates, int width) async {
    reads++;
    return base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGP4z8DwH4QZYAwAR8oH+WdZbrcAAAAASUVORK5CYII=',
    );
  }
}

void main() {
  testWidgets('artwork survives remounting and reloads after invalidation', (
    tester,
  ) async {
    final source = _ArtworkStorage();
    final tile = ArcImage(
      storage: source,
      candidates: const ['cover.png'],
      cacheWidth: 80,
      fallback: const Icon(Icons.broken_image),
    );

    Future<void> show() async {
      await tester.pumpWidget(MaterialApp(home: tile));
      final image = tester.widget<Image>(find.byType(Image));
      await tester.runAsync(
        () => precacheImage(image.image, tester.element(find.byType(Image))),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.broken_image), findsNothing);
    }

    await show();
    expect(source.reads, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await show();
    expect(source.reads, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await source.invalidateArtwork();
    await show();
    expect(source.reads, 2);
  });
}
