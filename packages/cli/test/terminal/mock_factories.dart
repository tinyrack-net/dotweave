// Dart port of the terminal-stream subset of
// `packages/cli/src/test/helpers/mock-factories.ts`.

import 'package:dotweave/src/terminal/logger.dart';

/// Mirror of the TS `MockStream`: records writes and counts the
/// clearLine/cursorTo spy calls.
class MockStream implements WriteStream {
  MockStream({this.isTTY = true});

  @override
  final bool isTTY;

  final List<String> writes = [];
  int clearLineCalls = 0;
  int cursorToCalls = 0;

  @override
  void write(String chunk) {
    writes.add(chunk);
  }

  @override
  void clearLine(int dir) {
    clearLineCalls++;
  }

  @override
  void cursorTo(int column) {
    cursorToCalls++;
  }
}

MockStream createMockStream([bool isTTY = true]) {
  return MockStream(isTTY: isTTY);
}
