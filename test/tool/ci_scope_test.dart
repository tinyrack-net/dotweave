import 'package:test/test.dart';

import '../../tool/ci_scope.dart';

void main() {
  group('CI change scope', () {
    test('an unreadable diff is the full scope', () {
      // The `changes` job pipes an empty list here when the API call fails.
      // That must never read as documentation.
      expect(CiChangeScope.forPullRequest(const []), CiChangeScope.full);
    });

    test('top-level markdown and agent skills are documentation', () {
      expect(
        CiChangeScope.forPullRequest(const [
          'README.md',
          'AGENTS.md',
          'PARITY.md',
          '.agents/skills/dotweave-documentation-writing/SKILL.md',
        ]),
        CiChangeScope.docsOnly,
      );
    });

    test('published documentation is not documentation-only', () {
      // test/e2e/docs_cli_drift_e2e_test.dart reads homepage/app/content and
      // compares it against the CLI's help output, so a page there has to run
      // the Dart suite that checks it.
      expect(
        CiChangeScope.forPullRequest(const [
          'homepage/app/content/en/guide.md',
        ]),
        CiChangeScope.full,
      );
      expect(
        CiChangeScope.forPullRequest(const [
          'homepage/app/content/ko/index.mdx',
        ]),
        CiChangeScope.full,
      );
    });

    test('a homepage change outside the content tree skips the Dart half', () {
      expect(
        CiChangeScope.forPullRequest(const [
          'homepage/app/components/globe.tsx',
          'homepage/package.json',
        ]),
        CiChangeScope.homepageOnly,
      );
    });

    test('a Dart change skips the homepage half', () {
      expect(
        CiChangeScope.forPullRequest(const [
          'lib/src/util/filesystem.dart',
          'test/util/filesystem_test.dart',
          'tool/validate.dart',
        ]),
        CiChangeScope.dartOnly,
      );
    });

    test('a pubspec change reaches both halves', () {
      // The homepage build reads the CLI version out of pubspec.yaml, so a
      // version bump can break the site without touching homepage/.
      expect(
        CiChangeScope.forPullRequest(const ['pubspec.yaml']),
        CiChangeScope.full,
      );
    });

    test('a workflow change is always the full scope', () {
      // A pipeline edit has to run the jobs it edited, and `lint` is where
      // actionlint checks the workflow.
      expect(
        CiChangeScope.forPullRequest(const ['.github/workflows/pipeline.yml']),
        CiChangeScope.full,
      );
      expect(
        CiChangeScope.forPullRequest(const ['.github/ci-matrices.json']),
        CiChangeScope.full,
      );
    });

    test('a mixed diff is the full scope', () {
      expect(
        CiChangeScope.forPullRequest(const [
          'lib/src/application.dart',
          'homepage/app/root.tsx',
        ]),
        CiChangeScope.full,
      );
    });

    test('blank lines in the file list are ignored', () {
      // The job pipes `printf '%s\n'` output in, which can carry a trailing
      // newline and therefore an empty final entry.
      expect(
        CiChangeScope.forPullRequest(const ['', 'README.md', '   ']),
        CiChangeScope.docsOnly,
      );
    });

    test('every scope has the output word the workflow matches on', () {
      // The `changes` job switches on these literals, so a rename here is a
      // silent scope change there.
      expect(
        CiChangeScope.values.map((scope) => scope.outputValue),
        containsAll(<String>[
          'docs-only',
          'homepage-only',
          'dart-only',
          'full',
        ]),
      );
    });
  });
}
