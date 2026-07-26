// Enforces the layering of `lib/src` at test time.
//
// Nothing in Dart enforces intra-package layering: every file under `lib/src`
// can import every other, and `implementation_imports` only fires across
// package boundaries. So the direction the package already follows is checked
// here instead of being split into a `dotweave_core` package purely to buy the
// "no upward import" invariant from pub. The rules below cost ~100 lines and
// also express things a pubspec never could (see the dart:io rule).
//
// When a rule genuinely needs to change, change it here deliberately.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Layer for a path under `lib/src`, or `null` for top-level files such as
/// `application.dart`.
String? _layerOf(String posixPath) {
  final match = RegExp(r'^lib/src/([^/]+)/').firstMatch(posixPath);

  return match?.group(1);
}

/// Layers each layer is allowed to depend on, besides itself.
///
/// `cli` is the composition layer, so it may reach everything. `services` may
/// not touch `terminal`: presentation lives above the service layer, and the
/// service layer currently has zero imports of it.
const Map<String, Set<String>> _allowedDependencies = {
  'cli': {'services', 'config', 'terminal', 'lib', 'assets'},
  'terminal': {'lib'},
  'services': {'config', 'lib', 'assets', 'crypto'},
  'config': {'lib'},
  'lib': {'crypto'},
  'crypto': <String>{},
  'assets': <String>{},
};

/// Layers that must stay free of direct process/filesystem access.
///
/// `crypto` is pure computation and its freedom from `dart:io` is what keeps
/// it extractable as a standalone package.
const Set<String> _layersWithoutDartIo = {'crypto'};

Iterable<File> _sourceFiles(String directory) sync* {
  final root = Directory(directory);

  if (!root.existsSync()) {
    return;
  }

  for (final entity in root.listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      yield entity;
    }
  }
}

void main() {
  // Tests run with the package root as the working directory.
  final sources = _sourceFiles('lib/src').toList();

  test('lib/src has sources to check', () {
    expect(sources, isNotEmpty, reason: 'layering rules checked nothing');
  });

  test('no layer imports a layer it is not allowed to depend on', () {
    final violations = <String>[];

    for (final file in sources) {
      final posixPath = p.posix.joinAll(p.split(p.relative(file.path)));
      final fromLayer = _layerOf(posixPath);

      if (fromLayer == null) {
        // Top-level files (application.dart) are the composition root.
        continue;
      }

      final allowed = _allowedDependencies[fromLayer];

      expect(
        allowed,
        isNotNull,
        reason:
            'lib/src/$fromLayer/ is a new layer; add it to '
            '_allowedDependencies with an explicit rule',
      );

      for (final match in RegExp(
        r"import 'package:dotweave/src/([^/']+)/",
      ).allMatches(file.readAsStringSync())) {
        final toLayer = match.group(1)!;

        if (toLayer == fromLayer || allowed!.contains(toLayer)) {
          continue;
        }

        violations.add('$posixPath -> src/$toLayer/');
      }
    }

    expect(violations, isEmpty);
  });

  test('pure layers do not reach for dart:io', () {
    final violations = <String>[];

    for (final file in sources) {
      final posixPath = p.posix.joinAll(p.split(p.relative(file.path)));

      if (!_layersWithoutDartIo.contains(_layerOf(posixPath))) {
        continue;
      }

      if (RegExp("import 'dart:io'").hasMatch(file.readAsStringSync())) {
        violations.add(posixPath);
      }
    }

    expect(violations, isEmpty);
  });
}
