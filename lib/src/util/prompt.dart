import 'dart:async';
import 'dart:io';

/// Minimal readline-like interface mirroring the surface of Node's
/// `node:readline/promises` interface used by [ask].
abstract class ReadlineInterface {
  Future<String> question(String query);
  void close();
}

class _StdioReadlineInterface implements ReadlineInterface {
  @override
  Future<String> question(String query) async {
    stdout.write(query);
    return stdin.readLineSync() ?? '';
  }

  @override
  void close() {}
}

ReadlineInterface _createStdioInterface() => _StdioReadlineInterface();

Future<String> ask(
  String question, {
  ReadlineInterface Function() createInterface = _createStdioInterface,
}) async {
  final rl = createInterface();
  try {
    return await rl.question(question);
  } finally {
    rl.close();
  }
}
