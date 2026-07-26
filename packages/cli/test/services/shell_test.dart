import 'package:dotweave/src/config/platform.dart';
import 'package:dotweave/src/services/shell.dart';
import 'package:dotweave/src/util/env.dart';
import 'package:dotweave/src/util/error.dart';
import 'package:test/test.dart';

Env _env([Map<String, String> values = const {}]) {
  return Env(values, caseInsensitiveKeys: false);
}

ShellDependencies _deps({
  Map<String, String> env = const {},
  PlatformKey platformKey = PlatformKey.linux,
  ShellSpawn? spawn,
}) {
  return ShellDependencies(
    env: _env(env),
    resolveCurrentPlatformKey: () => platformKey,
    spawn: spawn,
  );
}

void main() {
  group('shell launcher', () {
    group('resolveShellCommandForPlatform', () {
      test('resolves SHELL on linux', () async {
        expect(
          await resolveShellCommandForPlatform(
            PlatformKey.linux,
            env: _env({'SHELL': '/bin/zsh'}),
          ),
          const ShellCommand(args: [], command: '/bin/zsh'),
        );
      });

      test('falls back to /bin/sh when SHELL is not set', () async {
        expect(
          await resolveShellCommandForPlatform(PlatformKey.wsl, env: _env()),
          const ShellCommand(args: [], command: '/bin/sh'),
        );
      });

      test('uses COMSPEC on windows', () async {
        expect(
          await resolveShellCommandForPlatform(
            PlatformKey.win,
            env: _env({'COMSPEC': r'C:\Windows\System32\cmd.exe'}),
          ),
          const ShellCommand(args: [], command: r'C:\Windows\System32\cmd.exe'),
        );
      });

      test(
        'falls back to cmd.exe on windows when COMSPEC is not set',
        () async {
          expect(
            await resolveShellCommandForPlatform(PlatformKey.win, env: _env()),
            const ShellCommand(args: [], command: 'cmd.exe'),
          );
        },
      );
    });

    group('resolveShellCommand', () {
      test('delegates to resolveShellCommandForPlatform with the current '
          'platform', () async {
        expect(
          await resolveShellCommand(
            dependencies: _deps(env: {'SHELL': '/bin/fish'}),
          ),
          const ShellCommand(args: [], command: '/bin/fish'),
        );
      });
    });

    group('launchShellInDirectory', () {
      test('rejects when the shell process fails to spawn', () async {
        await expectLater(
          launchShellInDirectory(
            '/tmp',
            dependencies: _deps(
              env: {'SHELL': '/nonexistent/shell'},
              spawn: (command, args, directory) async {
                throw Exception('spawn failed');
              },
            ),
          ),
          throwsA(isA<DotweaveError>()),
        );
      });

      test(
        'uses the windows shell hint when a windows shell fails to spawn',
        () async {
          await expectLater(
            launchShellInDirectory(
              '/tmp',
              dependencies: _deps(
                env: {'COMSPEC': 'missing-cmd.exe'},
                platformKey: PlatformKey.win,
                spawn: (command, args, directory) async {
                  throw Exception('not found');
                },
              ),
            ),
            throwsA(
              isA<DotweaveError>().having(
                (error) => error.hint,
                'hint',
                'Set COMSPEC to a valid shell executable.',
              ),
            ),
          );
        },
      );

      test('launchShellInDirectory resolves when the shell process exits '
          'successfully', () async {
        await expectLater(
          launchShellInDirectory(
            '/tmp',
            dependencies: _deps(
              env: {'SHELL': '/bin/bash'},
              spawn: (command, args, directory) async {
                return const ShellCloseEvent(code: 0);
              },
            ),
          ),
          completes,
        );
      });

      test(
        'launchShellInDirectory rejects when the shell process exits non-zero',
        () async {
          await expectLater(
            launchShellInDirectory(
              '/tmp',
              dependencies: _deps(
                env: {'SHELL': '/bin/bash'},
                spawn: (command, args, directory) async {
                  return const ShellCloseEvent(code: 1);
                },
              ),
            ),
            throwsA(isA<ShellExitError>()),
          );
        },
      );

      test('reports signal termination', () async {
        await expectLater(
          launchShellInDirectory(
            '/tmp',
            dependencies: _deps(
              env: {'SHELL': '/bin/bash'},
              spawn: (command, args, directory) async {
                return const ShellCloseEvent(signal: 'SIGTERM');
              },
            ),
          ),
          throwsA(
            isA<DotweaveError>().having(
              (error) => error.message,
              'message',
              'Shell exited due to signal SIGTERM.',
            ),
          ),
        );
      });

      test('uses exit code 1 when the shell closes without a code', () async {
        await expectLater(
          launchShellInDirectory(
            '/tmp',
            dependencies: _deps(
              env: {'SHELL': '/bin/bash'},
              spawn: (command, args, directory) async {
                return const ShellCloseEvent();
              },
            ),
          ),
          throwsA(
            isA<ShellExitError>()
                .having((error) => error.exitCode, 'exitCode', 1)
                .having(
                  (error) => error.message,
                  'message',
                  'Shell exited with code unknown.',
                ),
          ),
        );
      });

      test('includes non-Error spawn error details', () async {
        await expectLater(
          launchShellInDirectory(
            '/tmp',
            dependencies: _deps(
              env: {'SHELL': '/bin/bash'},
              spawn: (command, args, directory) async {
                // ignore: only_throw_errors
                throw 'not an Error';
              },
            ),
          ),
          throwsA(
            isA<DotweaveError>().having((error) => error.details, 'details', [
              'Shell: /bin/bash',
              'not an Error',
            ]),
          ),
        );
      });
    });
  });
}
