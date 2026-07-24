/// Bech32 codec (BIP-173, plain bech32 checksum — NOT bech32m) sufficient for
/// age key encoding.
///
/// age recipients use the lowercase HRP `age`; identities use the uppercase
/// HRP `AGE-SECRET-KEY-` (the entire string is uppercase). Mixed-case strings
/// are rejected per BIP-173.
library;

import 'dart:typed_data';

import 'exception.dart';

const String _charset = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';

final List<int> _charsetReverse = () {
  final table = List<int>.filled(128, -1);
  for (var i = 0; i < _charset.length; i++) {
    table[_charset.codeUnitAt(i)] = i;
  }
  return table;
}();

int _polymod(List<int> values) {
  const generator = <int>[
    0x3b6a57b2,
    0x26508e6d,
    0x1ea119fa,
    0x3d4233dd,
    0x2a1462b3,
  ];
  var checksum = 1;
  for (final value in values) {
    final top = checksum >> 25;
    checksum = ((checksum & 0x1ffffff) << 5) ^ value;
    for (var i = 0; i < 5; i++) {
      if ((top >> i) & 1 == 1) {
        checksum ^= generator[i];
      }
    }
  }
  return checksum;
}

List<int> _hrpExpand(String hrp) {
  return <int>[
    for (final code in hrp.codeUnits) code >> 5,
    0,
    for (final code in hrp.codeUnits) code & 31,
  ];
}

List<int> _createChecksum(String hrp, List<int> data) {
  final values = <int>[..._hrpExpand(hrp), ...data, 0, 0, 0, 0, 0, 0];
  final polymod = _polymod(values) ^ 1;
  return <int>[for (var i = 0; i < 6; i++) (polymod >> (5 * (5 - i))) & 31];
}

List<int> _convertBits(
  List<int> data,
  int fromBits,
  int toBits, {
  required bool pad,
}) {
  var accumulator = 0;
  var bits = 0;
  final result = <int>[];
  final maxValue = (1 << toBits) - 1;
  for (final value in data) {
    if (value < 0 || value >> fromBits != 0) {
      throw const AgeException('bech32: invalid data value');
    }
    accumulator = (accumulator << fromBits) | value;
    bits += fromBits;
    while (bits >= toBits) {
      bits -= toBits;
      result.add((accumulator >> bits) & maxValue);
    }
  }
  if (pad) {
    if (bits > 0) {
      result.add((accumulator << (toBits - bits)) & maxValue);
    }
  } else if (bits >= fromBits ||
      ((accumulator << (toBits - bits)) & maxValue) != 0) {
    throw const AgeException('bech32: invalid padding bits');
  }
  return result;
}

void _checkHrp(String hrp) {
  if (hrp.isEmpty) {
    throw const AgeException('bech32: empty human-readable part');
  }
  for (final code in hrp.codeUnits) {
    if (code < 33 || code > 126) {
      throw const AgeException(
        'bech32: invalid character in human-readable part',
      );
    }
  }
}

/// Encodes [data] (raw bytes) with the given human-readable part [hrp].
///
/// If [hrp] is uppercase (e.g. `AGE-SECRET-KEY-`) the whole encoded string is
/// returned uppercase; otherwise it is lowercase. A mixed-case [hrp] is
/// rejected.
String bech32Encode(String hrp, Uint8List data) {
  _checkHrp(hrp);
  final isUpper = hrp == hrp.toUpperCase() && hrp != hrp.toLowerCase();
  if (!isUpper && hrp != hrp.toLowerCase()) {
    throw const AgeException('bech32: mixed-case human-readable part');
  }
  final lowerHrp = hrp.toLowerCase();
  final values = _convertBits(data, 8, 5, pad: true);
  final checksum = _createChecksum(lowerHrp, values);
  final buffer = StringBuffer(lowerHrp)..write('1');
  for (final value in [...values, ...checksum]) {
    buffer.write(_charset[value]);
  }
  final encoded = buffer.toString();
  return isUpper ? encoded.toUpperCase() : encoded;
}

/// Decodes a bech32 [encoded] string into its human-readable part (returned
/// lowercase) and raw data bytes. Rejects mixed case and bad checksums.
({String hrp, Uint8List data}) bech32Decode(String encoded) {
  if (encoded != encoded.toLowerCase() && encoded != encoded.toUpperCase()) {
    throw const AgeException('bech32: mixed-case string');
  }
  final lower = encoded.toLowerCase();
  final separator = lower.lastIndexOf('1');
  if (separator < 1) {
    throw const AgeException('bech32: missing separator');
  }
  if (lower.length - separator - 1 < 6) {
    throw const AgeException('bech32: data part too short');
  }
  final hrp = lower.substring(0, separator);
  _checkHrp(hrp);
  final values = <int>[];
  for (final code in lower.codeUnits.sublist(separator + 1)) {
    final value = code < 128 ? _charsetReverse[code] : -1;
    if (value == -1) {
      throw const AgeException('bech32: invalid character in data part');
    }
    values.add(value);
  }
  if (_polymod([..._hrpExpand(hrp), ...values]) != 1) {
    throw const AgeException('bech32: invalid checksum');
  }
  final data = _convertBits(
    values.sublist(0, values.length - 6),
    5,
    8,
    pad: false,
  );
  return (hrp: hrp, data: Uint8List.fromList(data));
}
