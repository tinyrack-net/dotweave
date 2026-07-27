import 'dart:async';

import 'package:test/test.dart';

import '../../tool/validate.dart';

void main() {
  group('validation scheduler', () {
    test('finishes preparation before starting dependent work', () async {
      final events = <String>[];
      final preparation = Completer<ValidationTaskResult>();

      Future<ValidationTaskResult> runner(ValidationTask task) {
        events.add('start:${task.name}');
        if (task.name == 'Dart dependencies') return preparation.future;
        events.add('finish:${task.name}');
        return Future.value(ValidationTaskResult(task: task, exitCode: 0));
      }

      final validation = runValidation(
        repoRoot: 'repo',
        target: ValidationTarget.dartStatic,
        runner: runner,
        log: (_) {},
      );

      await Future<void>.delayed(Duration.zero);
      expect(events, ['start:Dart dependencies']);
      preparation.complete(
        const ValidationTaskResult(
          task: ValidationTask(
            name: 'Dart dependencies',
            executable: 'dart',
            arguments: ['pub', 'get'],
            workingDirectory: 'repo',
          ),
          exitCode: 0,
        ),
      );

      expect(await validation, 0);
      expect(events, containsAll(['start:Dart format', 'start:Dart analyze']));
    });

    test('starts both package tests in the same parallel stage', () async {
      final started = <ValidationTask>[];
      final blockers = <String, Completer<ValidationTaskResult>>{};

      Future<ValidationTaskResult> runner(ValidationTask task) {
        started.add(task);
        final blocker = Completer<ValidationTaskResult>();
        blockers[task.name] = blocker;
        return blocker.future;
      }

      final validation = runValidation(
        repoRoot: 'repo',
        target: ValidationTarget.dartTests,
        runner: runner,
        log: (_) {},
      );

      await Future<void>.delayed(Duration.zero);
      _complete(blockers.remove('Dart dependencies')!, 0);
      await Future<void>.delayed(Duration.zero);
      _complete(blockers.remove('CLI e2e binary')!, 0);
      await Future<void>.delayed(Duration.zero);

      expect(
        started.map((task) => task.name),
        containsAll(['CLI tests', 'Shipworld tests']),
      );
      expect(started.map((task) => task.name), isNot(contains('Tools tests')));

      for (final blocker in blockers.values) {
        _complete(blocker, 0);
      }
      expect(await validation, 0);
    });

    test('waits for peers and preserves the first failing exit code', () async {
      final started = <ValidationTask>[];
      final blockers = <String, Completer<ValidationTaskResult>>{};

      Future<ValidationTaskResult> runner(ValidationTask task) {
        started.add(task);
        final blocker = Completer<ValidationTaskResult>();
        blockers[task.name] = blocker;
        return blocker.future;
      }

      final validation = runValidation(
        repoRoot: 'repo',
        target: ValidationTarget.dartAll,
        runner: runner,
        log: (_) {},
      );

      await Future<void>.delayed(Duration.zero);
      _complete(blockers.remove('Dart dependencies')!, 0);
      await Future<void>.delayed(Duration.zero);
      expect(
        started.map((task) => task.name),
        containsAll(['Dart format', 'Dart analyze', 'CLI e2e binary']),
      );

      _complete(blockers.remove('Dart format')!, 23);
      var finished = false;
      unawaited(validation.then((_) => finished = true));
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);

      _complete(blockers.remove('Dart analyze')!, 0);
      _complete(blockers.remove('CLI e2e binary')!, 0);
      expect(await validation, 23);
      expect(started.map((task) => task.name), isNot(contains('CLI tests')));
    });
  });
}

void _complete(Completer<ValidationTaskResult> completer, int exitCode) {
  completer.complete(
    ValidationTaskResult(
      task: const ValidationTask(
        name: 'fake',
        executable: 'fake',
        arguments: [],
        workingDirectory: 'repo',
      ),
      exitCode: exitCode,
    ),
  );
}
