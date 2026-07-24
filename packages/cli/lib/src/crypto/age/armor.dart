/// age ASCII armor: a strict subset of PEM using standard base64 with padding
/// and 64-character lines.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'exception.dart';
import 'stanza.dart';

const String _beginLine = '-----BEGIN AGE ENCRYPTED FILE-----';
const String _endLine = '-----END AGE ENCRYPTED FILE-----';

/// Encodes a binary age [file] into ASCII armor (with a final newline).
String armorEncode(Uint8List file) {
  final encoded = base64Encode(file);
  final buffer = StringBuffer()
    ..write(_beginLine)
    ..write('\n');
  for (var offset = 0; offset < encoded.length; offset += 64) {
    buffer
      ..write(encoded.substring(offset, min(offset + 64, encoded.length)))
      ..write('\n');
  }
  buffer
    ..write(_endLine)
    ..write('\n');
  return buffer.toString();
}

/// Decodes an ASCII armored age file. Extra whitespace before and after the
/// armor is ignored and newlines may be CRLF or LF; everything else is parsed
/// strictly (line lengths, label lines, canonical padded base64).
Uint8List armorDecode(String armored) {
  final lines = armored.trim().replaceAll('\r\n', '\n').split('\n');
  if (lines.isEmpty || lines.first != _beginLine) {
    throw const AgeException('invalid armor begin line');
  }
  if (lines.length < 2 || lines.last != _endLine) {
    throw const AgeException('invalid armor end line');
  }
  final body = lines.sublist(1, lines.length - 1);
  for (var i = 0; i < body.length; i++) {
    final length = body[i].length;
    final isLast = i == body.length - 1;
    final validLength = isLast
        ? length > 0 && length <= 64 && length % 4 == 0
        : length == 64;
    if (!validLength) {
      throw const AgeException('invalid armor line length');
    }
  }
  return _decodePaddedBase64(body.join());
}

Uint8List _decodePaddedBase64(String input) {
  if (input.length % 4 != 0) {
    throw const AgeException('invalid armor base64 length');
  }
  var padding = 0;
  var stripped = input;
  while (stripped.endsWith('=')) {
    stripped = stripped.substring(0, stripped.length - 1);
    padding++;
  }
  if (padding > 2 || stripped.contains('=')) {
    throw const AgeException('invalid armor base64 padding');
  }
  final expectedPadding = switch (stripped.length % 4) {
    0 => 0,
    2 => 2,
    3 => 1,
    _ => -1,
  };
  if (padding != expectedPadding) {
    throw const AgeException('invalid armor base64 padding');
  }
  return decodeBase64NoPad(stripped);
}
