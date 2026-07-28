import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dotweave/src/util/error.dart';
import 'package:dotweave/src/util/git.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final List<String> _temporaryDirectories = [];

final Map<String, String> _gitTestEnvironment = {
  'GIT_AUTHOR_EMAIL': 'test@example.com',
  'GIT_AUTHOR_NAME': 'Test User',
  'GIT_COMMITTER_EMAIL': 'test@example.com',
  'GIT_COMMITTER_NAME': 'Test User',
  'GIT_CONFIG_COUNT': '1',
  'GIT_CONFIG_KEY_0': 'commit.gpgsign',
  'GIT_CONFIG_NOSYSTEM': '1',
  'GIT_CONFIG_VALUE_0': 'false',
  'GIT_CONFIG_GLOBAL': Platform.isWindows ? 'NUL' : '/dev/null',
};

Future<String> _createTemporaryDirectory(String prefix) async {
  final directory = await Directory.systemTemp.createTemp(prefix);

  return directory.path;
}

Future<String> _createWorkspace() async {
  final directory = await _createTemporaryDirectory('dotweave-git-');

  _temporaryDirectories.add(directory);

  return directory;
}

Future<ProcessResult> _runGit(List<String> args, [String? cwd]) async {
  final result = await Process.run(
    'git',
    args,
    workingDirectory: cwd,
    runInShell: false,
    environment: {...Platform.environment, ..._gitTestEnvironment},
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );

  if (result.exitCode != 0) {
    throw Exception(
      'git ${args.join(' ')} failed with code ${result.exitCode}: '
      '${result.stderr}',
    );
  }

  return result;
}

GitExecFileException _createGitError(
  String message, {
  String? stderr,
  String? stdout,
}) {
  return GitExecFileException(message, stderr: stderr, stdout: stdout);
}

ProcessException _createEnoentError() {
  return const ProcessException('git', ['status'], 'spawn git ENOENT', 2);
}

class _FakeStreamingChild {
  _FakeStreamingChild()
    : stderrController = StreamController<String>(),
      stdoutController = StreamController<String>(),
      resultCompleter = Completer<int?>();

  final StreamController<String> stderrController;
  final StreamController<String> stdoutController;
  final Completer<int?> resultCompleter;

  GitStreamingChild get child => GitStreamingChild(
    stderr: stderrController.stream,
    stdout: stdoutController.stream,
    result: resultCompleter.future,
  );

  Future<void> closeStreams() async {
    await stdoutController.close();
    await stderrController.close();
  }
}

void main() {
  tearDown(() async {
    while (_temporaryDirectories.isNotEmpty) {
      final directory = _temporaryDirectories.removeLast();
      final target = Directory(directory);

      if (await target.exists()) {
        await target.delete(recursive: true);
      }
    }
  });

  group('pumpProcessOutput', () {
    // These drive the pump directly because the `spawnGit` seam replaces the
    // whole spawn function, so nothing else in the suite ever executes it.

    ({
      StreamController<String> stdoutSink,
      StreamController<String> stderrSink,
      Completer<int?> result,
    })
    makeSinks() => (
      stdoutSink: StreamController<String>(),
      stderrSink: StreamController<String>(),
      result: Completer<int?>(),
    );

    test('forwards output and completes with the exit code', () async {
      final sinks = makeSinks();
      final stdoutText = sinks.stdoutSink.stream.join();
      final stderrText = sinks.stderrSink.stream.join();

      await pumpProcessOutput(
        stdout: Stream.value(utf8.encode('out')),
        stderr: Stream.value(utf8.encode('err')),
        exitCode: Future.value(0),
        stdoutSink: sinks.stdoutSink,
        stderrSink: sinks.stderrSink,
        result: sinks.result,
      );

      expect(await sinks.result.future, 0);
      expect(await stdoutText, 'out');
      expect(await stderrText, 'err');
      expect(sinks.stdoutSink.isClosed, isTrue);
      expect(sinks.stderrSink.isClosed, isTrue);
    });

    test('completes with an error when the exit code fails', () async {
      // The regression. `result` used to be left uncompleted here, so every
      // caller awaiting `GitStreamingChild.result` hung forever with no error
      // and no exit code. The timeout turns a reintroduced hang into a fast
      // failure rather than a 30-second wait.
      final sinks = makeSinks();
      unawaited(sinks.stdoutSink.stream.drain<void>());
      unawaited(sinks.stderrSink.stream.drain<void>());
      // Listen before pumping: a completer that errors with no listener
      // attached reports an unhandled async error instead.
      final resultSettled = expectLater(
        sinks.result.future.timeout(const Duration(seconds: 5)),
        throwsA(isA<ProcessException>()),
      );

      await pumpProcessOutput(
        stdout: const Stream<List<int>>.empty(),
        stderr: const Stream<List<int>>.empty(),
        exitCode: Future<int>.error(const ProcessException('git', [])),
        stdoutSink: sinks.stdoutSink,
        stderrSink: sinks.stderrSink,
        result: sinks.result,
      );

      await resultSettled;
      expect(sinks.stdoutSink.isClosed, isTrue);
      expect(sinks.stderrSink.isClosed, isTrue);
    });

    test('completes with an error when a sink rejects the stream', () async {
      // The other way the pump can throw: `addStream` raises synchronously on
      // a sink that is already closed. Same requirement — `result` must still
      // resolve, and both sinks must still be closed.
      final sinks = makeSinks();
      // Both need a listener: `close()` on an unlistened controller never
      // completes, which would hang the setup and then the pump's own cleanup.
      unawaited(sinks.stdoutSink.stream.drain<void>());
      unawaited(sinks.stderrSink.stream.drain<void>());
      await sinks.stdoutSink.close();
      final resultSettled = expectLater(
        sinks.result.future.timeout(const Duration(seconds: 5)),
        throwsA(isA<StateError>()),
      );

      await pumpProcessOutput(
        stdout: const Stream<List<int>>.empty(),
        stderr: const Stream<List<int>>.empty(),
        exitCode: Future.value(0),
        stdoutSink: sinks.stdoutSink,
        stderrSink: sinks.stderrSink,
        result: sinks.result,
      );

      await resultSettled;
      expect(sinks.stderrSink.isClosed, isTrue);
    });

    test('surfaces a failing output stream to its consumer', () async {
      // An erroring source stream is NOT a pump failure: `addStream` forwards
      // the error to the sink rather than throwing, so the consumer sees it
      // and `result` still reports the exit code. Pinned so the distinction
      // does not get "fixed" into a spurious result error later.
      final sinks = makeSinks();
      final stdoutDone = expectLater(
        sinks.stdoutSink.stream,
        emitsError(isA<SocketException>()),
      );
      unawaited(sinks.stderrSink.stream.drain<void>());

      await pumpProcessOutput(
        stdout: Stream<List<int>>.error(const SocketException('pipe broke')),
        stderr: const Stream<List<int>>.empty(),
        exitCode: Future.value(0),
        stdoutSink: sinks.stdoutSink,
        stderrSink: sinks.stderrSink,
        result: sinks.result,
      );

      await stdoutDone;
      expect(await sinks.result.future.timeout(const Duration(seconds: 5)), 0);
    });
  });

  group('git helpers', () {
    group('runGitCommandWithDependencies', () {
      test('uses trimmed stderr before stdout or error message', () async {
        await expectLater(
          runGitCommandWithDependencies(
            ['status'],
            null,
            GitCommandDependencies(
              execFileAsync: (file, args, {cwd}) async {
                throw _createGitError(
                  'fallback message',
                  stderr: '  fatal from stderr\n',
                  stdout: 'stdout message',
                );
              },
            ),
          ),
          throwsA(
            isA<Exception>().having(
              (error) => error.toString(),
              'message',
              contains('fatal from stderr'),
            ),
          ),
        );
      });

      test('uses stdout when stderr is empty', () async {
        await expectLater(
          runGitCommandWithDependencies(
            ['status'],
            null,
            GitCommandDependencies(
              execFileAsync: (file, args, {cwd}) async {
                throw _createGitError(
                  'fallback message',
                  stderr: '  \n',
                  stdout: ' stdout message\n',
                );
              },
            ),
          ),
          throwsA(
            isA<Exception>().having(
              (error) => error.toString(),
              'message',
              contains('stdout message'),
            ),
          ),
        );
      });

      test('uses the error message when stderr and stdout are empty', () async {
        await expectLater(
          runGitCommandWithDependencies(
            ['status'],
            null,
            GitCommandDependencies(
              execFileAsync: (file, args, {cwd}) async {
                throw _createGitError(
                  'fallback message',
                  stderr: '',
                  stdout: '',
                );
              },
            ),
          ),
          throwsA(
            isA<Exception>().having(
              (error) => error.toString(),
              'message',
              contains('fallback message'),
            ),
          ),
        );
      });

      test('uses a stable fallback when a non-Error value is thrown', () async {
        await expectLater(
          runGitCommandWithDependencies(
            ['status'],
            null,
            GitCommandDependencies(
              execFileAsync: (file, args, {cwd}) async {
                // ignore: only_throw_errors
                throw 'boom';
              },
            ),
          ),
          throwsA(
            isA<Exception>().having(
              (error) => error.toString(),
              'message',
              contains('git failed.'),
            ),
          ),
        );
      });

      test('reports a missing git executable from execFile', () async {
        await expectLater(
          runGitCommandWithDependencies(
            ['status'],
            null,
            GitCommandDependencies(
              execFileAsync: (file, args, {cwd}) async {
                throw _createEnoentError();
              },
            ),
          ),
          throwsA(
            isA<DotweaveError>()
                .having(
                  (error) => error.code,
                  'code',
                  'GIT_EXECUTABLE_NOT_FOUND',
                )
                .having((error) => error.hint, 'hint', contains('PATH'))
                .having(
                  (error) => error.message,
                  'message',
                  'Git is not installed or not on PATH.',
                ),
          ),
        );
      });
    });

    group('runStreamingGitCommandWithDependencies', () {
      test('rejects when the child process emits an error', () async {
        final fake = _FakeStreamingChild();
        final result = runStreamingGitCommandWithDependencies(
          ['status'],
          null,
          StreamingGitCommandDependencies(
            spawnGit: (command, args, {cwd}) => fake.child,
          ),
        );

        fake.resultCompleter.completeError(Exception('spawn failed'));

        await expectLater(
          result,
          throwsA(
            isA<Exception>().having(
              (error) => error.toString(),
              'message',
              contains('spawn failed'),
            ),
          ),
        );
      });

      test('reports a missing git executable from spawn', () async {
        final fake = _FakeStreamingChild();
        final result = runStreamingGitCommandWithDependencies(
          ['status'],
          null,
          StreamingGitCommandDependencies(
            spawnGit: (command, args, {cwd}) => fake.child,
          ),
        );

        fake.resultCompleter.completeError(_createEnoentError());

        await expectLater(
          result,
          throwsA(
            isA<DotweaveError>()
                .having(
                  (error) => error.code,
                  'code',
                  'GIT_EXECUTABLE_NOT_FOUND',
                )
                .having((error) => error.hint, 'hint', contains('PATH'))
                .having(
                  (error) => error.message,
                  'message',
                  'Git is not installed or not on PATH.',
                ),
          ),
        );
      });

      test(
        'reports an unknown code when the child process closes without a code',
        () async {
          final fake = _FakeStreamingChild();
          final result = runStreamingGitCommandWithDependencies(
            ['status'],
            null,
            StreamingGitCommandDependencies(
              spawnGit: (command, args, {cwd}) => fake.child,
            ),
          );

          await fake.closeStreams();
          fake.resultCompleter.complete(null);

          await expectLater(
            result,
            throwsA(
              isA<Exception>().having(
                (error) => error.toString(),
                'message',
                contains('git exited with code unknown.'),
              ),
            ),
          );
        },
      );

      test(
        'uses stderr before stdout when the child process exits non-zero',
        () async {
          final fake = _FakeStreamingChild();
          final result = runStreamingGitCommandWithDependencies(
            ['status'],
            null,
            StreamingGitCommandDependencies(
              spawnGit: (command, args, {cwd}) => fake.child,
            ),
          );

          fake.stdoutController.add('stdout message\n');
          fake.stderrController.add('stderr message\n');
          await fake.closeStreams();
          fake.resultCompleter.complete(2);

          await expectLater(
            result,
            throwsA(
              isA<Exception>().having(
                (error) => error.toString(),
                'message',
                contains('stderr message'),
              ),
            ),
          );
        },
      );
    });

    test('initializes a repository with a main branch', () async {
      final workspace = await _createWorkspace();
      final repositoryPath = p.join(workspace, 'sync');

      final result = await initializeRepository(repositoryPath);

      expect(result.action, 'initialized');
      expect(result.source, isNull);
      await expectLater(verifyIsGitRepository(repositoryPath), completes);

      final head = await _runGit([
        '-C',
        repositoryPath,
        'symbolic-ref',
        '--short',
        'HEAD',
      ]);

      expect(head.stdout, 'main\n');
    });

    test('clones an existing repository and reports the source', () async {
      final workspace = await _createWorkspace();
      final sourcePath = p.join(workspace, 'source');
      final targetPath = p.join(workspace, 'clone');

      await _runGit(['init', '-b', 'main', sourcePath], workspace);

      final result = await initializeRepository(targetPath, sourcePath);

      expect(result.action, 'cloned');
      expect(result.source, sourcePath);
      await expectLater(verifyIsGitRepository(targetPath), completes);
    });

    test('wraps missing git repositories in a DotweaveError', () async {
      final workspace = await _createWorkspace();
      final missingRepositoryPath = p.join(workspace, 'not-a-repo');

      await expectLater(
        verifyIsGitRepository(missingRepositoryPath),
        throwsA(anything),
      );
      await expectLater(
        requireGitRepository(missingRepositoryPath),
        throwsA(isA<DotweaveError>()),
      );
      await expectLater(
        requireGitRepository(missingRepositoryPath),
        throwsA(
          isA<DotweaveError>().having(
            (error) => error.message,
            'message',
            contains('Sync repository is not initialized'),
          ),
        ),
      );
    });

    test(
      'fails to initialize a repository in a non-writable location',
      () async {
        final workspace = await _createWorkspace();
        final fileParentPath = p.join(workspace, 'not-a-directory');

        await File(fileParentPath).writeAsString('not a directory');

        await expectLater(
          initializeRepository(p.join(fileParentPath, 'repo')),
          throwsA(anything),
        );
      },
    );
  });
}
