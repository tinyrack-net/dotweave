// Dart port of `packages/cli/src/services/autocomplete.test.ts`.
//
// The TS tests stub `process.env.COMP_LINE` via `vi.stubEnv`; the Dart port
// passes an explicit `Env` through `resolveCompletionInputs`'s injectable
// environment seam instead (no `afterEach` unstubbing needed).

import 'package:dotweave/src/lib/env.dart';
import 'package:dotweave/src/services/autocomplete.dart';
import 'package:test/test.dart';

void main() {
  group('autocomplete helpers', () {
    test('emits stable shell script invariants', () {
      expect(bashAutocompleteScript, contains('__dotweave_complete() {'));
      expect(
        bashAutocompleteScript,
        contains('env -u COMP_LINE dotweave __complete "\${inputs[@]}"'),
      );
      expect(
        powershellAutocompleteScript,
        contains('Register-ArgumentCompleter -Native -CommandName dotweave'),
      );
      expect(
        powershellAutocompleteScript,
        contains(r'$commandLine = $commandAst.ToString()'),
      );
      expect(
        powershellAutocompleteScript,
        contains(r"$commandLine.EndsWith(' ')"),
      );
      expect(
        zshAutocompleteScript,
        contains('add-zsh-hook precmd __dotweave_ensure_completion'),
      );
    });

    test('strips the cli binary token from raw completion inputs', () {
      final env = Env(const {});

      expect(resolveCompletionInputs(['dotweave', 'track', 'fi'], env: env), [
        'track',
        'fi',
      ]);
      expect(
        resolveCompletionInputs([
          r'C:\Users\test\bin\dotweave.exe',
          'status',
        ], env: env),
        ['status'],
      );
    });

    test('prefers COMP_LINE when shells provide a richer completion line', () {
      final env = Env(const {
        'COMP_LINE': '  dotweave   profile   use   work  ',
      });

      expect(resolveCompletionInputs(['ignored', 'tokens'], env: env), [
        'profile',
        'use',
        'work',
        '',
      ]);
    });

    test('returns an empty input list for blank completion lines', () {
      final env = Env(const {'COMP_LINE': '   '});

      expect(
        resolveCompletionInputs(['dotweave', 'track'], env: env),
        <String>[],
      );
    });
  });
}
