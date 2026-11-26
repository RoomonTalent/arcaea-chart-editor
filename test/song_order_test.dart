import 'package:arcaea_manager/models/difficulty.dart';
import 'package:arcaea_manager/models/pack.dart';
import 'package:arcaea_manager/models/song.dart';
import 'package:arcaea_manager/services/song_order.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final packs = [
    Pack.fromJson({'id': 'first'}),
    Pack.fromJson({'id': 'second'}),
  ];

  Song song(
    String id, {
    int? date,
    String pack = 'first',
    Map<int, (int, bool)> ratings = const {},
  }) => Song.fromJson({
    'id': id,
    'set': pack,
    'date': ?date,
    'title_localized': {'en': id},
    'difficulties': [
      for (final entry in ratings.entries)
        {
          'ratingClass': entry.key,
          'rating': entry.value.$1,
          'ratingPlus': entry.value.$2,
        },
    ],
  });

  test('default order uses release date then pack order for undated songs', () {
    final songs = [
      song('second-a', pack: 'second'),
      song('same-date-a', date: 300),
      song('unlisted', pack: 'single'),
      song('other-unlisted', pack: 'custom'),
      song('unlisted-b', pack: 'single'),
      song('first-a'),
      song('earliest', date: 100),
      song('first-b', date: 0),
      song('same-date-b', date: 300),
    ];
    final sorted = sortSongs(songs, packs, SongSortMode.defaultOrder);
    expect(sorted.map((song) => song.id), [
      'earliest',
      'same-date-a',
      'same-date-b',
      'first-a',
      'first-b',
      'second-a',
      'unlisted',
      'unlisted-b',
      'other-unlisted',
    ]);
    expect(songs.first.id, 'second-a');
  });

  test('title ordering uses the displayed title and ignores case', () {
    final songs = [song('Zulu'), song('beta'), song('Alpha')];
    expect(sortSongs(songs, packs, SongSortMode.title).map((song) => song.id), [
      'Alpha',
      'beta',
      'Zulu',
    ]);
  });

  test('difficulty ordering uses the selected chart or the highest rating', () {
    const etr = RatingClass.eternal;
    const byd = RatingClass.beyond;
    final songs = [
      song('unknown', ratings: {etr: (0, false)}),
      song('hardest', ratings: {etr: (9, false), byd: (12, false)}),
      song('plus', ratings: {etr: (9, true)}),
      song('eight', ratings: {etr: (8, false)}),
      song('ten', ratings: {etr: (10, false)}),
    ];

    expect(
      sortSongs(
        songs,
        packs,
        SongSortMode.difficulty,
        ratingClass: etr,
      ).map((song) => song.id),
      ['eight', 'hardest', 'plus', 'ten', 'unknown'],
    );
    expect(
      sortSongs(songs, packs, SongSortMode.difficulty).map((song) => song.id),
      ['eight', 'plus', 'ten', 'hardest', 'unknown'],
    );
  });
}
