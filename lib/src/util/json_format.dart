import 'dart:convert';

import 'string.dart';

const JsonEncoder _encoder = JsonEncoder.withIndent('  ');

/// Serializes config values exactly like the TS side's
/// `JSON.stringify(value, null, 2)` + trailing newline. Manifest and settings
/// files are committed to git, so output must stay byte-identical — pinned by
/// the golden test against a Node-generated fixture.
String formatJsonPretty(Object? value) {
  return ensureTrailingNewline(_encoder.convert(value));
}
