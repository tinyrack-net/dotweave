import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

String? _decodeUtf8(Uint8List contents) {
  try {
    final text = const Utf8Decoder().convert(contents);
    // Dart's UTF-8 decoder strips a leading BOM, while the TS implementation
    // decodes with `ignoreBOM: true` and keeps it. Restore the BOM so BOM
    // differences remain significant when comparing decoded text.
    final hasLeadingBom =
        contents.length >= 3 &&
        contents[0] == 0xef &&
        contents[1] == 0xbb &&
        contents[2] == 0xbf;
    if (hasLeadingBom) {
      return String.fromCharCode(0xfeff) + text;
    }
    return text;
  } on FormatException {
    return null;
  }
}

String _normalizeLineEndings(String contents) {
  return contents.replaceAll('\r\n', '\n');
}

bool fileContentsEqual(
  Uint8List left,
  Uint8List right, {
  bool normalizeTextLineEndings = false,
}) {
  if (_bytesEqual(left, right)) {
    return true;
  }

  if (normalizeTextLineEndings != true) {
    return false;
  }

  final leftText = _decodeUtf8(left);
  final rightText = _decodeUtf8(right);

  if (leftText == null || rightText == null) {
    return false;
  }

  return _normalizeLineEndings(leftText) == _normalizeLineEndings(rightText);
}

bool _bytesEqual(Uint8List left, Uint8List right) {
  if (left.length != right.length) {
    return false;
  }
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) {
      return false;
    }
  }
  return true;
}

bool shouldNormalizeTextLineEndings() {
  return Platform.isWindows;
}
