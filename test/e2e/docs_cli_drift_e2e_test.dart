// Dart port of `tests/docs-cli-drift.e2e.test.ts`.
//
// The dotweave package root is the repo root, so the homepage docs paths
// resolve from it directly, regardless of the test runner's working directory.

@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/e2e_context.dart';

final String _workspaceRoot = e2ePackageRoot();
final String _docsRoot = p.join(_workspaceRoot, 'homepage', 'app', 'content');

final RegExp _contentFilePattern = RegExp(r'\.(md|mdx)$');

Future<List<String>> _collectContentFiles(String directory) async {
  final files = <String>[];

  await for (final entry in Directory(directory).list(followLinks: false)) {
    if (entry is Directory) {
      files.addAll(await _collectContentFiles(entry.path));
    } else if (entry is File &&
        _contentFilePattern.hasMatch(p.basename(entry.path))) {
      files.add(entry.path);
    }
  }

  return files;
}

final List<({String name, RegExp pattern})> _unsupportedInitFlags = [
  (name: '--key', pattern: RegExp(r'(^|[\s`])--key(?![-\w])')),
  (name: '--promptKey', pattern: RegExp('--promptKey')),
  (name: '--url', pattern: RegExp(r'--url\b')),
];

final List<({String name, RegExp pattern})> _staleSecretArtifactFragments = [
  (name: '`.age` secret artifact suffix', pattern: RegExp(r'`\.age`')),
  (
    name: '.age secret artifact example',
    pattern: RegExp(r'\b(?:config|credentials|work-key)\.age\b'),
  ),
];

final RegExp _linePattern = RegExp(r'\r?\n');

void main() {
  group('documentation CLI drift', () {
    test('does not document removed init credential flags', () async {
      final files = [
        p.join(_workspaceRoot, 'README.md'),
        ...await _collectContentFiles(_docsRoot),
      ];
      final violations = <String>[];

      for (final file in files) {
        final text = await File(file).readAsString();
        final lines = text.split(_linePattern);

        for (var index = 0; index < lines.length; index += 1) {
          final line = lines[index];

          for (final flag in _unsupportedInitFlags) {
            if (flag.pattern.hasMatch(line)) {
              violations.add(
                '${p.relative(file, from: _workspaceRoot)}:${index + 1} '
                'uses ${flag.name}',
              );
            }
          }
        }
      }

      expect(violations, isEmpty);
    });

    test('does not document the legacy .age secret artifact suffix', () async {
      final files = await _collectContentFiles(_docsRoot);
      final violations = <String>[];

      for (final file in files) {
        final text = await File(file).readAsString();
        final lines = text.split(_linePattern);

        for (var index = 0; index < lines.length; index += 1) {
          final line = lines[index];

          for (final fragment in _staleSecretArtifactFragments) {
            if (fragment.pattern.hasMatch(line)) {
              violations.add(
                '${p.relative(file, from: _workspaceRoot)}:${index + 1} '
                'uses ${fragment.name}',
              );
            }
          }
        }
      }

      expect(violations, isEmpty);
    });
  });
}
