/// age header stanza wire format.
///
/// A stanza is serialized as `-> type arg1 arg2\n` followed by its body as
/// unpadded canonical standard base64 wrapped at 64 columns, where the final
/// line is strictly shorter than 64 characters (an empty final line when the
/// body length is a multiple of 48 bytes, including the empty body).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'exception.dart';

const String _base64Alphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

final List<int> _base64Reverse = () {
  final table = List<int>.filled(128, -1);
  for (var i = 0; i < _base64Alphabet.length; i++) {
    table[_base64Alphabet.codeUnitAt(i)] = i;
  }
  return table;
}();

/// Encodes bytes as unpadded standard base64.
String encodeBase64NoPad(List<int> bytes) {
  var encoded = base64Encode(bytes);
  while (encoded.endsWith('=')) {
    encoded = encoded.substring(0, encoded.length - 1);
  }
  return encoded;
}

/// Decodes unpadded canonical standard base64, rejecting padding characters,
/// invalid lengths, and non-zero trailing bits.
Uint8List decodeBase64NoPad(String input) {
  if (input.length % 4 == 1) {
    throw const AgeException('invalid base64 length');
  }
  final output = BytesBuilder(copy: false);
  var accumulator = 0;
  var bits = 0;
  for (final code in input.codeUnits) {
    final value = code < 128 ? _base64Reverse[code] : -1;
    if (value == -1) {
      throw const AgeException('invalid base64 character');
    }
    accumulator = (accumulator << 6) | value;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      output.addByte((accumulator >> bits) & 0xff);
    }
  }
  if (bits > 0 && (accumulator & ((1 << bits) - 1)) != 0) {
    throw const AgeException('non-canonical base64 trailing bits');
  }
  return output.toBytes();
}

bool _isValidLabel(String label) {
  if (label.isEmpty) {
    return false;
  }
  for (final code in label.codeUnits) {
    if (code < 0x21 || code > 0x7e) {
      return false;
    }
  }
  return true;
}

/// A single age header stanza.
class Stanza {
  /// Creates a stanza, validating that the type and arguments are non-empty
  /// printable-ASCII strings without spaces.
  Stanza(this.type, this.args, this.body) {
    if (!_isValidLabel(type) || args.any((arg) => !_isValidLabel(arg))) {
      throw const AgeException(
        'stanza type and arguments must be non-empty printable ASCII without spaces',
      );
    }
  }

  /// Stanza type, e.g. `X25519`.
  final String type;

  /// Stanza arguments.
  final List<String> args;

  /// Raw stanza body bytes.
  final Uint8List body;

  /// Serializes this stanza to its wire format (including trailing newline).
  String serialize() {
    final buffer = StringBuffer()
      ..write('-> ')
      ..write([type, ...args].join(' '))
      ..write('\n');
    final encoded = encodeBase64NoPad(body);
    var offset = 0;
    while (encoded.length - offset >= 64) {
      buffer
        ..write(encoded.substring(offset, offset + 64))
        ..write('\n');
      offset += 64;
    }
    // Final line is strictly shorter than 64 characters and may be empty.
    buffer
      ..write(encoded.substring(offset))
      ..write('\n');
    return buffer.toString();
  }
}

/// Parses one stanza given its already-read [firstLine] (which must start with
/// `-> `) and a [readLine] callback yielding subsequent header lines.
Stanza parseStanza(String firstLine, String Function() readLine) {
  if (!firstLine.startsWith('-> ')) {
    throw const AgeException('malformed stanza start line');
  }
  final parts = firstLine.substring(3).split(' ');
  if (parts.isEmpty || parts.any((part) => !_isValidLabel(part))) {
    throw const AgeException('malformed stanza type or arguments');
  }
  final encodedBody = StringBuffer();
  while (true) {
    final line = readLine();
    if (line.length > 64) {
      throw const AgeException('stanza body line longer than 64 characters');
    }
    encodedBody.write(line);
    if (line.length < 64) {
      break;
    }
  }
  final body = decodeBase64NoPad(encodedBody.toString());
  return Stanza(parts.first, parts.sublist(1), body);
}
