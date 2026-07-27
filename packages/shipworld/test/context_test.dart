import 'dart:io';

import 'package:shipworld/shipworld.dart';
import 'package:test/test.dart';

final class RecordingExecutor implements ProcessExecutor {
  RecordingExecutor(this.label);

  final String label;
  final calls = <String>[];

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    calls.add(executable);
    await Future<void>.delayed(const Duration(milliseconds: 1));
    return ProcessResult(0, 0, label, '');
  }

  @override
  Future<int> runInherited(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) {
    throw UnimplementedError();
  }
}

void main() {
  test(
    'process injection is isolated across concurrent async operations',
    () async {
      final first = RecordingExecutor('first');
      final second = RecordingExecutor('second');

      final results = await Future.wait([
        ShipworldContext(
          process: first,
        ).run(() => runCapture('first-tool', const [])),
        ShipworldContext(
          process: second,
        ).run(() => runCapture('second-tool', const [])),
      ]);

      expect(results.map((result) => result.stdout), ['first', 'second']);
      expect(first.calls, ['first-tool']);
      expect(second.calls, ['second-tool']);
    },
  );
}
