import 'package:test/test.dart';
import 'package:tinyrack_cli/tinyrack_cli.dart';

// The scripts are consumed by real shells, so these pin the invariants a shell
// would break on, plus the substitution of the executable name into every
// place it appears.

CompletionScripts scripts({
  String executableName = 'example',
  String completeSubcommand = '__complete',
  String? functionPrefix,
}) {
  return CompletionScripts(
    executableName: executableName,
    completeSubcommand: completeSubcommand,
    functionPrefix: functionPrefix,
  );
}

void main() {
  group('function naming', () {
    test('derives shell function names from the executable', () {
      final s = scripts();

      expect(s.bash, contains('__example_complete() {'));
      expect(s.fish, contains('function __example_complete'));
      expect(s.zsh, contains('__example_complete() {'));
      expect(
        s.zsh,
        contains('add-zsh-hook precmd __example_ensure_completion'),
      );
    });

    test('replaces characters a POSIX function name cannot contain', () {
      // `__my-cli_complete` would be a syntax error in bash, and the script is
      // sourced rather than parsed by us, so the shell is the one that fails.
      final s = scripts(executableName: 'my-cli');

      expect(s.bash, contains('__my_cli_complete() {'));
      expect(s.bash, isNot(contains('__my-cli_complete')));
      // The command being completed keeps its real name.
      expect(s.bash, contains('-F __my_cli_complete my-cli'));
    });

    test('honours an explicit function prefix', () {
      final s = scripts(functionPrefix: '_custom');

      expect(s.bash, contains('_custom_complete() {'));
      expect(s.zsh, contains('add-zsh-hook precmd _custom_ensure_completion'));
    });
  });

  group('script invariants', () {
    test('every script calls the executable and subcommand', () {
      final s = scripts(completeSubcommand: 'completions');

      expect(
        s.bash,
        contains('env -u COMP_LINE example completions "\${inputs[@]}"'),
      );
      expect(
        s.zsh,
        contains('env -u COMP_LINE example completions "\${inputs[@]}"'),
      );
      expect(s.fish, contains('command example completions \$tokens'));
      expect(s.powershell, contains(r'& example completions $inputs'));
    });

    test('registers the completer with the shell', () {
      final s = scripts();

      expect(s.bash, contains('complete -o default -o nospace -F'));
      expect(s.zsh, contains('compdef __example_complete example'));
      expect(s.fish, contains('complete -c example -f'));
      expect(
        s.powershell,
        contains('Register-ArgumentCompleter -Native -CommandName example'),
      );
    });

    test('zsh bootstraps compinit so the script works in a bare shell', () {
      expect(scripts().zsh, contains('autoload -Uz compinit'));
    });

    test('powershell reads the cursor position to detect a new word', () {
      final s = scripts();

      expect(s.powershell, contains(r'$commandLine = $commandAst.ToString()'));
      expect(s.powershell, contains(r"$commandLine.EndsWith(' ')"));
    });

    test('every script ends with a newline', () {
      // A script that is `eval`'d without a trailing newline concatenates with
      // whatever follows it.
      for (final script in [
        scripts().bash,
        scripts().zsh,
        scripts().fish,
        scripts().powershell,
      ]) {
        expect(script, endsWith('\n'));
      }
    });
  });

  group('resolveCompletionInputs', () {
    String? noEnv(String name) => null;

    test('strips a leading executable token', () {
      final s = scripts(executableName: 'dotweave');

      expect(
        s.resolveCompletionInputs(['dotweave', 'track', 'fi'], readEnv: noEnv),
        ['track', 'fi'],
      );
    });

    test('recognises a windows path and .exe suffix', () {
      final s = scripts(executableName: 'dotweave');

      expect(
        s.resolveCompletionInputs([
          r'C:\Users\test\bin\dotweave.exe',
          'status',
        ], readEnv: noEnv),
        ['status'],
      );
    });

    test('leaves inputs alone when the first token is something else', () {
      final s = scripts(executableName: 'dotweave');

      expect(s.resolveCompletionInputs(['track', 'fi'], readEnv: noEnv), [
        'track',
        'fi',
      ]);
    });

    test('prefers COMP_LINE, keeping the trailing empty word', () {
      // The trailing space in COMP_LINE means "the cursor starts a new word",
      // which the token list alone cannot express.
      final s = scripts(executableName: 'dotweave');

      expect(
        s.resolveCompletionInputs(
          ['ignored', 'tokens'],
          readEnv: (name) => name == 'COMP_LINE'
              ? '  dotweave   profile   use   work  '
              : null,
        ),
        ['profile', 'use', 'work', ''],
      );
    });

    test('returns nothing for a blank completion line', () {
      final s = scripts(executableName: 'dotweave');

      expect(
        s.resolveCompletionInputs([
          'dotweave',
          'track',
        ], readEnv: (name) => name == 'COMP_LINE' ? '   ' : null),
        <String>[],
      );
    });
  });
}
