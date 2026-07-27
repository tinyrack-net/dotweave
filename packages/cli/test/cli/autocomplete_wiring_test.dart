import 'package:dotweave/src/cli/autocomplete.dart';
import 'package:test/test.dart';

// The script generators live in `cliweave` and are tested there against an
// arbitrary executable name. What is dotweave's own is the binding: that the
// scripts are generated for `dotweave __complete` and not something else. The
// shells actually running these scripts are exercised in
// `test/e2e/autocomplete_e2e_test.dart`.

void main() {
  group('dotweave completion script wiring', () {
    test('generates scripts bound to the dotweave executable', () {
      expect(completionScripts.executableName, 'dotweave');
      expect(completionScripts.completeSubcommand, '__complete');
    });

    test('every shell script invokes `dotweave __complete`', () {
      expect(
        completionScripts.bash,
        contains('env -u COMP_LINE dotweave __complete "\${inputs[@]}"'),
      );
      expect(
        completionScripts.zsh,
        contains('env -u COMP_LINE dotweave __complete "\${inputs[@]}"'),
      );
      expect(completionScripts.fish, contains('command dotweave __complete'));
      expect(
        completionScripts.powershell,
        contains(r'& dotweave __complete $inputs'),
      );
    });

    test('registers completers under the dotweave command name', () {
      expect(completionScripts.bash, contains('__dotweave_complete() {'));
      expect(
        completionScripts.zsh,
        contains('compdef __dotweave_complete dotweave'),
      );
      expect(completionScripts.fish, contains('complete -c dotweave -f'));
      expect(
        completionScripts.powershell,
        contains('Register-ArgumentCompleter -Native -CommandName dotweave'),
      );
    });
  });
}
