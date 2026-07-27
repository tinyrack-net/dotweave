// Byte-exact help rendering for dotweave's own configured command tree.
//
// The framework's parity tests live in `cliweave`; these three
// assert the composed result -- what a user actually sees for
// `dotweave push --help` and friends -- so they stay with the application
// whose commands, briefs, and flag set produce that output. They are the
// tightest pin in the suite: any column-width, ordering, or spacing change
// breaks them, which is the point.

import 'package:dotweave/src/application.dart';
import 'package:test/test.dart';

import '../helpers/capture_stream.dart';

Future<({int exitCode, String stdout, String stderr})> _runDotweave(
  List<String> inputs,
) async {
  final stdout = CaptureStream();
  final stderr = CaptureStream();
  final exitCode = await runCli(inputs, stdout: stdout, stderr: stderr);

  return (exitCode: exitCode, stdout: stdout.text, stderr: stderr.text);
}

void main() {
  group('dotweave help rendering', () {
    test('renders push command help byte-identical to stricli', () async {
      final result = await _runDotweave(['push', '--help']);

      expect(result.exitCode, 0);
      expect(result.stderr, '');
      expect(
        result.stdout,
        'USAGE\n'
        '  dotweave push [--dry-run] [--profile profile]\n'
        '  dotweave push --help\n'
        '\n'
        'Collect the current state of tracked local files and directories, then update the sync directory artifacts to match. Secret targets are encrypted before they are written into the repository.\n'
        '\n'
        'FLAGS\n'
        '     [--dry-run/--no-dry-run]  Preview repository updates only\n'
        "     [--profile]               Use a registered profile layer for this command (add non-default profiles with 'dotweave profile add')\n"
        '  -h  --help                   Print help information and exit\n',
      );
    });

    test('renders untrack command help with positional arguments', () async {
      final result = await _runDotweave(['untrack', '--help']);

      expect(result.exitCode, 0);
      expect(result.stderr, '');
      expect(
        result.stdout,
        'USAGE\n'
        '  dotweave untrack <target>\n'
        '  dotweave untrack --help\n'
        '\n'
        'Remove a tracked root entry or a nested override from dotweave configuration. This only updates the sync config; actual file changes happen on the next push or pull. Use a local path to remove the main tracked target, or use a repository-relative child path inside a tracked directory to remove only that override.\n'
        '\n'
        'FLAGS\n'
        '  -h --help  Print help information and exit\n'
        '\n'
        'ARGUMENTS\n'
        '  target  Tracked local path (including cwd-relative) or repository path to stop tracking\n',
      );
    });

    test('renders root route map help byte-identical to stricli', () async {
      final result = await _runDotweave([]);

      expect(result.exitCode, 0);
      expect(result.stderr, '');
      expect(
        result.stdout,
        'USAGE\n'
        '  dotweave autocomplete bash|fish|powershell|zsh ...\n'
        '  dotweave cd\n'
        '  dotweave doctor\n'
        '  dotweave init [--force] [--key-file path] [<repository>]\n'
        '  dotweave profile add|list|remove|use ...\n'
        '  dotweave pull [--dry-run] [--profile profile] [--yes]\n'
        '  dotweave push [--dry-run] [--profile profile]\n'
        '  dotweave skill install ...\n'
        '  dotweave status [--profile profile]\n'
        '  dotweave track [--kind file|directory] [--mode mode|platform=mode]... [--permission octal|platform=octal]... [--profile profile]... [--local platform=path]... [--repo path|platform=path]... <target>...\n'
        '  dotweave untrack <target>\n'
        '  dotweave --help\n'
        '  dotweave --version\n'
        '\n'
        'Manage tracked configuration files under your home directory, mirror them into a git-backed sync directory, and restore them later on other devices.\n'
        '\n'
        'FLAGS\n'
        '  -h --help     Print help information and exit\n'
        '  -v --version  Print version information and exit\n'
        '\n'
        'COMMANDS\n'
        '  autocomplete  Print shell autocomplete scripts\n'
        '  cd            Launch a shell in the sync directory\n'
        '  doctor        Check sync directory, config, age identity, and tracked local paths\n'
        '  init          Initialize the git-backed sync directory\n'
        '  profile       Manage active and assigned sync profiles\n'
        '  pull          Apply the git-backed sync directory to local config paths\n'
        '  push          Mirror local config into the git-backed sync directory\n'
        '  skill         Manage portable agent skills\n'
        '  status        Show planned push and pull changes for the current sync config\n'
        '  track         Track local files or directories for syncing\n'
        '  untrack       Stop tracking a synced path\n',
      );
    });
  });
}
