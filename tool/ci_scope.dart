// The smallest safe set of pipeline jobs for a pull request's diff.
//
// Run this directly (`dart tool/ci_scope.dart`), never through `dart run`: the
// `changes` job decides the scope before any dependency is resolved, so this
// file must import nothing outside the Dart SDK.
//
// Reads changed file paths on stdin, one per line, and writes one scope name.

import 'dart:convert';
import 'dart:io';

/// The half of the repository a diff can affect.
///
/// The repository has two independent halves: the Dart CLI at the root and the
/// Node homepage under `homepage/`. A diff confined to one of them does not
/// need the other half's jobs.
enum CiChangeScope {
  /// Prose only. Nothing in the pipeline verifies it.
  docsOnly('docs-only'),

  /// Only the homepage changed, so the Dart jobs have nothing to check.
  homepageOnly('homepage-only'),

  /// Only the Dart package changed, so the homepage jobs have nothing to check.
  dartOnly('dart-only'),

  /// Both halves, or something that reaches both.
  full('full');

  const CiChangeScope(this.outputValue);

  /// The word the `changes` job writes to `$GITHUB_OUTPUT`.
  final String outputValue;

  /// Resolves the smallest safe scope for [changedFiles].
  ///
  /// Fails open: every shape this cannot account for resolves to [full]. A
  /// narrower scope is returned only when every file in the diff justifies it.
  static CiChangeScope forPullRequest(Iterable<String> changedFiles) {
    final files = changedFiles
        .map((file) => file.trim())
        .where((file) => file.isNotEmpty)
        .toList(growable: false);

    // An unreadable diff arrives here as an empty list. That is not prose.
    if (files.isEmpty) return full;

    // A pipeline change has to run the jobs it changed.
    if (files.any((file) => file.startsWith('.github/'))) return full;

    if (files.every(_isDocumentation)) return docsOnly;

    final touchesDart = files.any(_touchesDart);
    final touchesHomepage = files.any(_touchesHomepage);
    if (touchesDart && touchesHomepage) return full;
    if (touchesHomepage) return homepageOnly;
    if (touchesDart) return dartOnly;
    return full;
  }

  /// Whether [file] is prose that no pipeline job reads.
  ///
  /// Only top-level markdown and the agent skills qualify. Markdown nested
  /// anywhere else is somebody's fixture or somebody's content tree.
  static bool _isDocumentation(String file) =>
      file.startsWith('.agents/') ||
      (!file.contains('/') && file.endsWith('.md'));

  /// Whether [file] is checked by a Dart job.
  ///
  /// `homepage/app/content/` counts, even though it lives under the homepage,
  /// because `test/e2e/docs_cli_drift_e2e_test.dart` reads that tree and
  /// compares it against the CLI's help output.
  static bool _touchesDart(String file) =>
      file.startsWith('homepage/app/content/') || !file.startsWith('homepage/');

  /// Whether [file] is checked by a homepage job.
  ///
  /// `pubspec.yaml` counts because the homepage build reads the CLI version
  /// out of it, so a version bump can break the site without touching it.
  static bool _touchesHomepage(String file) =>
      file.startsWith('homepage/') || file == 'pubspec.yaml';
}

Future<void> main() async {
  final files = await stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .toList();
  stdout.writeln(CiChangeScope.forPullRequest(files).outputValue);
}
