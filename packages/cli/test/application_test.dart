// Dart port of `packages/cli/src/application.test.ts`.
//
// The TS tests capture output by spying on the global
// `process.stdout.write`/`process.stderr.write`; the Dart port injects
// capture streams through `runCli`'s stream parameters instead.
//
// Tests that target commands not yet ported (autocomplete/__complete, track,
// init, profile) are adapted to the currently registered routes and marked
// with TODO(port) so later agents can restore the original targets.

import 'package:dotweave/src/application.dart';
import 'package:dotweave/src/cli/root_commands.dart';
import 'package:dotweave/src/lib/error.dart';
import 'package:dotweave/src/lib/version.g.dart';
import 'package:test/test.dart';

import 'helpers/capture_stream.dart';

class _ExitCodeError implements Exception, CommandExitCode {
  const _ExitCodeError(this.message, this.exitCode);

  final String message;

  @override
  final int? exitCode;

  @override
  String toString() => message;
}

Future<({int exitCode, String stdout, String stderr})> _runCapturedCli(
  List<String> inputs,
) async {
  final stdout = CaptureStream();
  final stderr = CaptureStream();
  final exitCode = await runCli(inputs, stdout: stdout, stderr: stderr);

  return (exitCode: exitCode, stdout: stdout.text, stderr: stderr.text);
}

void main() {
  group('CLI application', () {
    test('prints the current version', () async {
      final output = await _runCapturedCli(['--version']);

      expect(output.exitCode, 0);
      expect(output.stdout, contains('dotweave/$packageVersion'));
      expect(output.stderr, '');
    });

    test('prints root help from the real application', () async {
      final output = await _runCapturedCli([]);

      expect(output.exitCode, 0);
      expect(output.stderr, '');

      for (final commandName in ['autocomplete', ...rootCommandRoutes.keys]) {
        expect(output.stdout, contains(commandName));
      }

      // TODO(port): restore the TS assertion on the profile route brief
      // ('Manage active and assigned sync profiles') once cli/profile/ is
      // ported; until then pin a registered route brief instead.
      expect(
        output.stdout,
        contains('Mirror local config into the git-backed sync directory'),
      );
    });

    test('prints autocomplete scripts and internal completions', () async {
      final scriptOutput = await _runCapturedCli(['autocomplete', 'bash']);

      expect(scriptOutput.exitCode, 0);
      expect(scriptOutput.stdout, contains('__dotweave_complete() {'));
      expect(scriptOutput.stderr, '');

      final completionOutput = await _runCapturedCli([
        '__complete',
        'dotweave',
        'aut',
      ]);

      expect(completionOutput.exitCode, 0);
      expect(completionOutput.stdout, contains('autocomplete'));
      expect(completionOutput.stderr, '');
    });

    test('reports unknown commands with a suggestion', () async {
      // TS uses "profiel" → profile; the profile route is not registered
      // yet, so exercise the suggestion path against the ported push route.
      // TODO(port): switch back to "profiel" once cli/profile/ is ported.
      final output = await _runCapturedCli(['pusj']);

      expect(output.exitCode, isNot(0));
      expect(output.stdout, '');
      expect(output.stderr, contains('Command "pusj" not found.'));
      expect(output.stderr, contains('push'));
    });

    test('respects custom command exit codes', () {
      expect(resolveExitCode(const _ExitCodeError('blocked', 7)), 7);
    });

    test('falls back to a generic exit code for unsupported error shapes', () {
      expect(resolveExitCode(Exception('blocked')), 1);
      expect(resolveExitCode({'exitCode': '7'}), 1);
      expect(resolveExitCode(null), 1);
      expect(resolveExitCode(const _ExitCodeError('blocked', null)), 1);
    });

    test(
      'formats non-Error thrown values without object stringification noise',
      () {
        final message = formatApplicationError({
          'reason': 'boom',
          'retryable': false,
        });

        expect(message, contains('reason'));
        expect(message, contains('boom'));
        expect(message, isNot(contains('[object Object]')));
      },
    );

    test(
      'reports parser errors for invalid flags and missing arguments',
      () async {
        // TODO(port): the TS invalid-enum half runs `track --mode bogus`;
        // restore it once cli/track.dart is ported (router_test.dart pins the
        // enum validation template in the meantime).
        final missingArgumentOutput = await _runCapturedCli(['untrack']);

        expect(missingArgumentOutput.exitCode, isNot(0));
        expect(missingArgumentOutput.stdout, '');
        expect(
          missingArgumentOutput.stderr,
          contains('Expected argument for target'),
        );
      },
    );

    test(
      'reports unknown commands without suggestion when no close match exists',
      () async {
        final output = await _runCapturedCli(['zzzzzzz']);

        expect(output.exitCode, isNot(0));
        expect(output.stderr, contains('Command "zzzzzzz" not found.'));
        expect(output.stderr, isNot(contains('Did you mean')));
      },
    );

    test('handles invalid flag on a root command', () async {
      final output = await _runCapturedCli(['--invalid-flag']);

      expect(output.exitCode, isNot(0));
      expect(output.stderr, isNotEmpty);
    });

    test('handles --help flag at root level', () async {
      final output = await _runCapturedCli(['--help']);

      expect(output.exitCode, 0);
      // TODO(port): restore the TS assertion on the profile route brief once
      // cli/profile/ is ported.
      expect(
        output.stdout,
        contains('Mirror local config into the git-backed sync directory'),
      );
      expect(output.stderr, '');
    });

    test('handles --help flag on subcommands', () async {
      // TS runs `init --help`; init is not ported yet, so pin push instead.
      // TODO(port): switch back to init once cli/init.dart is ported.
      final output = await _runCapturedCli(['push', '--help']);

      expect(output.exitCode, 0);
      expect(
        output.stdout,
        contains('update the sync directory artifacts to match'),
      );
      expect(output.stderr, '');
    });

    test(
      'handles command execution errors from untrack on invalid target',
      () async {
        // TS runs `track /nonexistent/...`; track is not ported yet, so
        // untrack drives the same real-services error path (missing repo or
        // untracked target — both throw before any write happens).
        // TODO(port): switch back to track once cli/track.dart is ported.
        final output = await _runCapturedCli([
          'untrack',
          '/nonexistent/path/that/does/not/exist',
        ]);

        expect(output.exitCode, isNot(0));
        expect(output.stderr, isNotEmpty);
      },
    );
  });
}
