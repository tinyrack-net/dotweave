import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Structural assertions on the CI pipeline.
///
/// The workflow is read as text rather than parsed: `package:yaml` is only a
/// transitive dependency, so importing it fails `depend_on_referenced_packages`
/// under `dart analyze --fatal-infos`. Well-formedness is actionlint's job;
/// this file pins the invariants that survive a rewrite.
void main() {
  final root = _repoRoot();
  // Normalised so the line anchors below survive a CRLF checkout.
  final workflow = File(
    p.join(root, '.github', 'workflows', 'pipeline.yml'),
  ).readAsStringSync().replaceAll('\r\n', '\n');
  final matrices =
      jsonDecode(
            File(
              p.join(root, '.github', 'ci-matrices.json'),
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;

  group('quality gate', () {
    test('accepts a skipped job but not a skipped scope', () {
      final gate = _job(workflow, 'quality-gate');

      // A job scoped out by diff reports `skipped`, which has to pass.
      expect(gate, contains('.result == "success" or .result == "skipped"'));
      // `changes` decides the scope. If it fails, every other job skips and a
      // gate without this clause would wave through a run that verified
      // nothing.
      expect(gate, contains('.changes.result == "success"'));
      // The strict predicate this replaced fails the moment a job is scoped
      // out, which is every conditional job in the file.
      expect(workflow, isNot(contains('all(.[]; .result == "success")')));
      expect(gate, contains('if: always()'));
    });

    test('needs every quality job and no publishing job', () {
      final gate = _job(workflow, 'quality-gate');

      for (final job in const [
        'changes',
        'lint',
        'dart-analyze',
        'dart-test',
        'homepage',
        'autocomplete-shell-smoke',
        'build-and-package',
      ]) {
        expect(gate, contains('- $job'), reason: '$job must gate a merge');
      }

      // These carry a ref guard, so they report `skipped` on a pull request.
      // The gate now counts that as a pass, which would make listing them
      // here look like coverage it is not.
      for (final job in const [
        'bundle-msix',
        'build-appimage',
        'publish-release',
        'publish-winget',
      ]) {
        expect(gate, isNot(contains('- $job')));
      }
    });
  });

  group('shared setup', () {
    test('every Dart job installs the SDK through the composite action', () {
      expect(workflow, isNot(contains('dart-lang/setup-dart')));
      expect(workflow, isNot(contains('actions/cache@')));
      expect(workflow, contains('./.github/actions/setup-dart'));
    });

    test('the SDK pin lives in one file and satisfies the pubspec', () {
      final action = File(
        p.join(root, '.github', 'actions', 'setup-dart', 'action.yml'),
      ).readAsStringSync();

      expect(action, contains('sdk: 3.12.2'));
      expect(workflow, isNot(contains('3.12.2')));

      final pubspec = File(p.join(root, 'pubspec.yaml')).readAsStringSync();
      final constraint = RegExp(r'sdk:\s*\^(\d+)\.(\d+)\.').firstMatch(pubspec);
      expect(constraint, isNotNull, reason: 'pubspec must pin an SDK range');
      expect(int.parse(constraint!.group(1)!), 3);
      expect(int.parse(constraint.group(2)!), lessThanOrEqualTo(12));
    });
  });

  group('change scope', () {
    test('resolves the scope before dependencies are resolved', () {
      final changes = _job(workflow, 'changes');

      // `dart run` needs a resolved package config the job does not have.
      expect(changes, contains('dart tool/ci_scope.dart'));
      expect(changes, isNot(contains('dart run tool/ci_scope.dart')));
    });

    test('reads the pull request file list from the API', () {
      final changes = _job(workflow, 'changes');

      expect(changes, contains('gh api'));
      expect(changes, contains('--paginate'));
      // Reading a pull request's files needs more than the workflow default.
      expect(changes, contains('pull-requests: read'));
    });

    test('falls back to the full scope when the diff is unreadable', () {
      final changes = _job(workflow, 'changes');

      expect(changes, contains('scope=full'));
      expect(changes, contains('using full scope'));
      // A non-pull-request event never decides the scope from a diff.
      expect(changes, contains(r'if [ -n "${PR_NUMBER}" ]'));
    });

    test('the two halves of the repository gate each other out', () {
      for (final job in const [
        'dart-analyze',
        'dart-test',
        'autocomplete-shell-smoke',
      ]) {
        expect(
          _job(workflow, job),
          contains("needs.changes.outputs.dart == 'true'"),
          reason: '$job belongs to the Dart half',
        );
      }

      for (final job in const ['lint', 'homepage']) {
        expect(
          _job(workflow, job),
          contains("needs.changes.outputs.homepage == 'true'"),
          reason: '$job belongs to the homepage half',
        );
      }

      // build-and-package has no guard of its own: it depends on dart-test, so
      // it cascades to skipped whenever the Dart half is scoped out.
      final packageJob = _job(workflow, 'build-and-package');
      expect(packageJob, contains('- changes'));
      expect(packageJob, contains('- dart-test'));
    });
  });

  group('matrices', () {
    test('every job takes its matrix from ci-matrices.json', () {
      expect(
        _job(workflow, 'dart-test'),
        contains('fromJSON(needs.changes.outputs.test_matrix)'),
      );
      expect(
        _job(workflow, 'autocomplete-shell-smoke'),
        contains('fromJSON(needs.changes.outputs.autocomplete_matrix)'),
      );
      expect(
        _job(workflow, 'build-and-package'),
        contains('fromJSON(needs.changes.outputs.package_matrix)'),
      );
    });

    test('every matrix keeps a non-empty host and cross group', () {
      // An empty `include:` is a workflow error, not a skipped job, so a
      // narrowing that empties one of these breaks the run outright.
      for (final name in const ['test', 'autocomplete', 'package']) {
        final group = matrices[name]! as Map<String, dynamic>;
        expect(group['host'], isNotEmpty, reason: '$name.host');
        expect(group['cross'], isNotEmpty, reason: '$name.cross');
      }
    });

    test('the test matrix covers all three operating systems', () {
      final hosts = _entries(
        matrices,
        'test',
      ).map((entry) => entry['os']! as String).toList();

      expect(hosts, hasLength(3));
      expect(hosts.any((os) => os.startsWith('ubuntu')), isTrue);
      expect(hosts.any((os) => os.startsWith('macos')), isTrue);
      expect(hosts.any((os) => os.startsWith('windows')), isTrue);
    });

    test('the autocomplete matrix covers every shell the CLI completes', () {
      // Mirrors `_supportedAutocompleteShells` in
      // test/e2e/autocomplete_e2e_test.dart, which is private to that suite.
      final shells = _entries(
        matrices,
        'autocomplete',
      ).map((entry) => entry['shell']! as String).toSet();

      expect(shells, {'bash', 'zsh', 'fish', 'powershell'});
    });

    test('every shell the matrix forces is installed or built in', () {
      final job = _job(workflow, 'autocomplete-shell-smoke');

      // The suite hard-fails rather than skipping when CI selects a shell the
      // runner lacks, so a matrix entry without an install step is a red job.
      expect(job, contains('DOTWEAVE_AUTOCOMPLETE_SHELL'));
      expect(job, contains('Install zsh (Ubuntu)'));
      expect(job, contains('Install fish (Ubuntu)'));
      expect(job, contains('Install fish (macOS)'));
    });

    test('the package matrix builds every published asset', () {
      final assets = _entries(
        matrices,
        'package',
      ).map((entry) => entry['asset']! as String).toSet();

      // publish-winget uploads these by name.
      expect(assets, contains('dotweave-win-x64.exe'));
      expect(assets, contains('dotweave-win-arm64.exe'));
      // build-appimage downloads these as artifacts.
      expect(assets, contains('dotweave-linux-x64'));
      expect(assets, contains('dotweave-linux-arm64'));
      // Both macOS architectures ship in the Homebrew formula.
      expect(assets, contains('dotweave-macos-x64'));
      expect(assets, contains('dotweave-macos-arm64'));

      // bundle-msix combines exactly the entries that declare an MSIX arch.
      final msixArches = _entries(matrices, 'package')
          .where((entry) => entry.containsKey('msixarch'))
          .map((entry) => entry['msixarch']! as String)
          .toSet();
      expect(msixArches, {'x64', 'arm64'});
    });

    test('no runner label is taught to actionlint after it goes unused', () {
      // Which labels actionlint already knows is a property of its version,
      // so the `lint` job is what checks that every label is accepted. What
      // this pins is the other direction: a label that stops being used has
      // to stop being declared, or the config outlives the runner bump that
      // motivated it.
      final config = File(
        p.join(root, '.github', 'actionlint.yaml'),
      ).readAsStringSync();

      final used = <String>{
        for (final name in const ['test', 'autocomplete', 'package'])
          ..._entries(matrices, name).map((entry) => entry['os']! as String),
      };

      final declared = RegExp(r'^    - (\S+)$', multiLine: true)
          .allMatches(config.replaceAll('\r\n', '\n'))
          .map((match) => match.group(1)!);

      expect(declared, isNotEmpty);
      for (final label in declared) {
        expect(
          used.contains(label) || workflow.contains('runs-on: $label'),
          isTrue,
          reason: '$label is declared for actionlint but no job uses it',
        );
      }
    });
  });

  group('triggers', () {
    test('the merge queue trigger stays wired', () {
      // The merge queue re-runs this pipeline against main before squashing,
      // so it is what makes the required check mean anything.
      expect(workflow, contains('merge_group:'));
      expect(workflow, contains('pull_request:'));
    });

    test('a merge-queue run cannot be cancelled out of the pipeline', () {
      // A cancelled check reads as a failure and ejects the pull request from
      // the queue.
      expect(workflow, contains("github.event_name != 'merge_group'"));
      expect(workflow, contains("github.ref != 'refs/heads/main'"));
      expect(workflow, contains("startsWith(github.ref, 'refs/tags/v')"));
    });
  });
}

/// The slice of [workflow] belonging to the job named [name].
///
/// Runs from the job's own key to the next key at the same indent, so an
/// assertion cannot accidentally match a neighbouring job.
String _job(String workflow, String name) {
  final header = '\n  $name:\n';
  final start = workflow.indexOf(header);
  if (start < 0) fail('No job named "$name" in the pipeline');

  // Search past the job's own header, which would otherwise match first and
  // return an empty slice.
  final matches = RegExp(
    r'^  [a-z0-9-]+:$',
    multiLine: true,
  ).allMatches(workflow, start + header.length);

  return workflow.substring(
    start,
    matches.isEmpty ? workflow.length : matches.first.start,
  );
}

/// Every entry of the named matrix group, host and cross together.
List<Map<String, dynamic>> _entries(
  Map<String, dynamic> matrices,
  String name,
) {
  final group = matrices[name]! as Map<String, dynamic>;
  return [
    for (final key in const ['host', 'cross'])
      ...(group[key]! as List<dynamic>).cast<Map<String, dynamic>>(),
  ];
}

String _repoRoot() {
  var root = Directory.current;
  while (!Directory(p.join(root.path, '.github')).existsSync()) {
    final parent = root.parent;
    if (parent.path == root.path) fail('Could not locate the repository root');
    root = parent;
  }
  return root.path;
}
