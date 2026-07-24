/// age v1 file header parse/serialize and header MAC computation.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'exception.dart';
import 'primitives.dart';
import 'stanza.dart';

/// The age v1 intro line (without trailing newline).
const String ageVersionLine = 'age-encryption.org/v1';

/// A parsed age v1 header.
class ParsedHeader {
  /// Creates a parsed header.
  const ParsedHeader({
    required this.stanzas,
    required this.mac,
    required this.macInput,
    required this.payloadOffset,
  });

  /// Recipient stanzas in file order.
  final List<Stanza> stanzas;

  /// The 32-byte header MAC read from the `---` line.
  final Uint8List mac;

  /// The exact bytes the MAC is computed over: intro line, stanzas, and the
  /// three `---` characters (no trailing space, MAC, or newline).
  final Uint8List macInput;

  /// Offset of the first payload byte in the original file.
  final int payloadOffset;
}

class _LineReader {
  _LineReader(this._bytes);

  final Uint8List _bytes;
  int offset = 0;

  String readLine() {
    if (offset >= _bytes.length) {
      throw const AgeException('truncated age header');
    }
    final newline = _indexOfNewline();
    if (newline == -1) {
      throw const AgeException('truncated age header: missing newline');
    }
    final line = String.fromCharCodes(_bytes, offset, newline);
    offset = newline + 1;
    return line;
  }

  int _indexOfNewline() {
    for (var i = offset; i < _bytes.length; i++) {
      if (_bytes[i] == 0x0a) {
        return i;
      }
    }
    return -1;
  }
}

/// Parses the header of an age [file], returning the stanzas, the MAC, the
/// exact MAC input bytes, and the payload offset.
ParsedHeader parseHeader(Uint8List file) {
  final reader = _LineReader(file);
  if (reader.readLine() != ageVersionLine) {
    throw const AgeException('unsupported or malformed age version line');
  }
  final stanzas = <Stanza>[];
  while (true) {
    final lineStart = reader.offset;
    final line = reader.readLine();
    if (line.startsWith('-> ')) {
      stanzas.add(parseStanza(line, reader.readLine));
      continue;
    }
    if (line.startsWith('--- ')) {
      final encodedMac = line.substring(4);
      if (encodedMac.contains(' ')) {
        throw const AgeException('malformed header MAC line');
      }
      final mac = decodeBase64NoPad(encodedMac);
      if (mac.length != 32) {
        throw const AgeException('header MAC must be 32 bytes');
      }
      return ParsedHeader(
        stanzas: stanzas,
        mac: mac,
        macInput: Uint8List.sublistView(file, 0, lineStart + 3),
        payloadOffset: reader.offset,
      );
    }
    throw const AgeException('unexpected line in age header');
  }
}

/// Serializes the header intro line and [stanzas], ending with the three `---`
/// characters (the exact MAC input).
Uint8List serializeHeaderWithoutMac(List<Stanza> stanzas) {
  final buffer = StringBuffer()
    ..write(ageVersionLine)
    ..write('\n');
  for (final stanza in stanzas) {
    buffer.write(stanza.serialize());
  }
  buffer.write('---');
  return ascii.encode(buffer.toString());
}

/// Serializes a complete header: [serializeHeaderWithoutMac] plus a space, the
/// unpadded base64 [mac], and a newline.
Uint8List serializeHeader(List<Stanza> stanzas, Uint8List mac) {
  final withoutMac = serializeHeaderWithoutMac(stanzas);
  final suffix = ascii.encode(' ${encodeBase64NoPad(mac)}\n');
  final result = Uint8List(withoutMac.length + suffix.length);
  result.setAll(0, withoutMac);
  result.setAll(withoutMac.length, suffix);
  return result;
}

/// Computes the header MAC: HMAC-SHA-256 over [macInput] with the key
/// HKDF-SHA-256(ikm: file key, salt: empty, info: "header").
Future<Uint8List> computeHeaderMac(
  Uint8List fileKey,
  Uint8List macInput,
) async {
  final macKey = await hkdfSha256(
    ikm: fileKey,
    salt: const <int>[],
    info: utf8.encode('header'),
  );
  return hmacSha256(macKey, macInput);
}

/// Verifies the MAC of a parsed [header] against [fileKey] in constant time.
Future<void> verifyHeaderMac(Uint8List fileKey, ParsedHeader header) async {
  final expected = await computeHeaderMac(fileKey, header.macInput);
  if (!constantTimeEquals(expected, header.mac)) {
    throw const AgeException(
      'incorrect header MAC',
      code: AgeExceptionCode.decryptionFailed,
    );
  }
}
