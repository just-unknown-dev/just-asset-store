/// Display text from catalogs and manifests: what the store prints and the
/// editor shows.
library;

import 'json.dart';

/// [value], the text at [key] of [json], when it is plain text; else a
/// [StoreFormatException]. Plain text has no control characters (tabs
/// aside, and line breaks when [lines]), and none of the invisible marks
/// that reorder what follows them: nothing that could move a terminal's
/// cursor, or make a name read as another.
String plainText(
  JsonFields json,
  String key,
  String value, {
  bool lines = false,
}) {
  for (final unit in value.codeUnits) {
    final allowed = unit == 0x09 || (lines && (unit == 0x0A || unit == 0x0D));
    if (!allowed &&
        (unit < 0x20 ||
            (unit >= 0x7F && unit <= 0x9F) ||
            (unit >= 0x202A && unit <= 0x202E) ||
            (unit >= 0x2066 && unit <= 0x2069))) {
      throw json.error(
        key,
        'Contains a control character '
        '(U+${unit.toRadixString(16).toUpperCase().padLeft(4, '0')}).',
      );
    }
  }
  return value;
}

/// [plainText] of the optional [value].
String? optPlainText(
  JsonFields json,
  String key,
  String? value, {
  bool lines = false,
}) => value == null ? null : plainText(json, key, value, lines: lines);
