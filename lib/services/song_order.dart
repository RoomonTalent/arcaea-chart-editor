import '../models/difficulty.dart';
import '../models/pack.dart';
import '../models/song.dart';

enum SongSortMode { defaultOrder, title, difficulty }

List<Song> sortSongs(
  List<Song> songs,
  List<Pack> packs,
  SongSortMode mode, {
  int? ratingClass,
}) {
  final packOrder = <String, int>{};
  for (final pack in packs) {
    packOrder.putIfAbsent(pack.id, () => packOrder.length);
  }
  for (final song in songs) {
    packOrder.putIfAbsent(song.set_, () => packOrder.length);
  }
  final entries = [
    for (final (index, song) in songs.indexed)
      (
        song: song,
        index: index,
        title: mode == SongSortMode.title
            ? song.displayTitle.trim().toLowerCase()
            : '',
        difficulty: mode == SongSortMode.difficulty
            ? _sortRating(song, ratingClass)
            : null,
      ),
  ];

  entries.sort((a, b) {
    final primary = switch (mode) {
      SongSortMode.defaultOrder => 0,
      SongSortMode.title => a.title.compareTo(b.title),
      SongSortMode.difficulty => _compareRatings(a.difficulty, b.difficulty),
    };
    if (primary != 0) return primary;

    final aDate = _releaseSeconds(a.song.date);
    final bDate = _releaseSeconds(b.song.date);
    if (aDate > 0 && bDate > 0) {
      final releaseOrder = aDate.compareTo(bDate);
      if (releaseOrder != 0) return releaseOrder;
    } else if (aDate > 0 || bDate > 0) {
      return aDate > 0 ? -1 : 1;
    } else {
      final aPack = packOrder[a.song.set_]!;
      final bPack = packOrder[b.song.set_]!;
      final byPack = aPack.compareTo(bPack);
      if (byPack != 0) return byPack;
    }

    return a.index.compareTo(b.index);
  });

  return entries.map((entry) => entry.song).toList();
}

num _releaseSeconds(int date) => date >= 100000000000 ? date / 1000 : date;

int _compareRatings(int? a, int? b) {
  if (a == null) return b == null ? 0 : 1;
  if (b == null) return -1;
  return a.compareTo(b);
}

int? _sortRating(Song song, int? ratingClass) {
  if (ratingClass != null) return _level(song.difficultyFor(ratingClass));

  int? highest;
  for (final difficulty in song.availableDifficulties) {
    final level = _level(difficulty);
    if (level != null && (highest == null || level > highest)) {
      highest = level;
    }
  }
  return highest;
}

int? _level(Difficulty? difficulty) {
  if (difficulty == null || difficulty.rating <= 0) return null;
  return difficulty.rating * 2 + (difficulty.ratingPlus ? 1 : 0);
}
