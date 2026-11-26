import 'dart:convert';
import 'dart:typed_data';

/// Reads and writes revision-zero UTF-8 GNU gettext catalogs.
class GettextCatalog {
  static const _magic = 0x950412de;
  final Map<String, String> messages;
  final Endian endian;

  GettextCatalog(this.messages, {this.endian = Endian.little});

  factory GettextCatalog.decode(Uint8List bytes) {
    const invalid = FormatException('无法读取此 GNU MO 译文表');
    if (bytes.lengthInBytes < 28) throw invalid;
    final data = ByteData.sublistView(bytes);
    final byteOrder = data.getUint32(0, Endian.little) == _magic
        ? Endian.little
        : Endian.big;
    int word(int offset) => data.getUint32(offset, byteOrder);
    if (word(0) != _magic || word(4) != 0) throw invalid;
    final count = word(8);
    final originalTable = word(12);
    final translatedTable = word(16);
    if (originalTable + count * 8 > data.lengthInBytes ||
        translatedTable + count * 8 > data.lengthInBytes) {
      throw invalid;
    }
    String value(int record) {
      final length = word(record);
      final start = word(record + 4);
      if (start + length >= bytes.length || bytes[start + length] != 0) {
        throw invalid;
      }
      return utf8.decode(Uint8List.sublistView(bytes, start, start + length));
    }

    final messages = {
      for (var i = 0; i < count; i++)
        value(originalTable + 8 * i): value(translatedTable + 8 * i),
    };
    if (messages.length != count) throw invalid;
    final charset = RegExp(
      r'charset=([^\s;]+)',
      caseSensitive: false,
    ).firstMatch(messages[''] ?? '')?.group(1)?.toLowerCase();
    if (charset != null && charset != 'utf-8' && charset != 'utf8') {
      throw const FormatException('此 MO 译文表使用了其他字符编码');
    }
    return GettextCatalog(messages, endian: byteOrder);
  }

  Uint8List encode() {
    final rows =
        messages.entries
            .map(
              (entry) => (
                key: utf8.encode(entry.key),
                value: utf8.encode(entry.value),
              ),
            )
            .toList()
          ..sort((a, b) {
            for (var i = 0; i < a.key.length && i < b.key.length; i++) {
              final order = a.key[i].compareTo(b.key[i]);
              if (order != 0) return order;
            }
            return a.key.length.compareTo(b.key.length);
          });
    const originals = 28;
    final translations = originals + rows.length * 8;
    var offset = translations + rows.length * 8;
    final length = rows.fold(
      offset,
      (size, row) => size + row.key.length + row.value.length + 2,
    );
    final bytes = Uint8List(length);
    final data = ByteData.sublistView(bytes);

    void word(int at, int value) => data.setUint32(at, value, endian);
    void put(int at, List<int> text) {
      word(at, text.length);
      word(at + 4, offset);
      bytes.setRange(offset, offset + text.length, text);
      offset += text.length + 1;
    }

    word(0, _magic);
    word(8, rows.length);
    word(12, originals);
    word(16, translations);
    for (final (index, row) in rows.indexed) {
      put(originals + index * 8, row.key);
      put(translations + index * 8, row.value);
    }
    return bytes;
  }
}
