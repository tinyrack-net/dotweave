// Test stream capturing CLI output; the seam replacing the TS tests' spies
// on `process.stdout.write` / `process.stderr.write`.

import 'package:dotweave/src/services/terminal/logger.dart';

class CaptureStream implements Stream {
  final StringBuffer _buffer = StringBuffer();

  @override
  bool get isTTY => false;

  @override
  void write(String chunk) {
    _buffer.write(chunk);
  }

  @override
  void clearLine(int dir) {}

  @override
  void cursorTo(int column) {}

  String get text => _buffer.toString();
}
