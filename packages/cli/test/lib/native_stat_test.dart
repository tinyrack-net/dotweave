// Parity pins for lib/src/lib/native_stat.dart.
//
// The fast path must agree field-for-field with the original dart:io
// implementation (kept verbatim as the fallback in filesystem.dart) on every
// fixture class it claims to answer, and must delegate (cannotAnswer) on
// everything link-shaped so reparse-tag semantics stay with dart:io.

import 'dart:io';

import 'package:dotweave/src/lib/filesystem.dart';
import 'package:dotweave/src/lib/native_stat.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Verbatim copy of the pre-fast-path `getPathStats` body: the dart:io
/// reference the fast path is pinned against.
Future<PathStats?> referencePathStats(String path) async {
  final type = await FileSystemEntity.type(path, followLinks: false);

  if (type == FileSystemEntityType.notFound) {
    return null;
  }

  if (type == FileSystemEntityType.link) {
    return const PathStats(
      isFile: false,
      isDirectory: false,
      isSymbolicLink: true,
      mode: 0,
    );
  }

  final stats = await FileStat.stat(path);

  if (stats.type == FileSystemEntityType.notFound) {
    return null;
  }

  return PathStats(
    isFile: stats.type == FileSystemEntityType.file,
    isDirectory: stats.type == FileSystemEntityType.directory,
    isSymbolicLink: false,
    mode: stats.mode,
  );
}

Future<void> expectAgreesWithReference(String path) async {
  final reference = await referencePathStats(path);
  final actual = await getPathStats(path);

  if (reference == null) {
    expect(actual, isNull, reason: 'missing-path disagreement for $path');
    return;
  }

  expect(actual, isNotNull, reason: 'existence disagreement for $path');
  expect(
    actual!.isFile,
    reference.isFile,
    reason: 'isFile disagreement for $path',
  );
  expect(
    actual.isDirectory,
    reference.isDirectory,
    reason: 'isDirectory disagreement for $path',
  );
  expect(
    actual.isSymbolicLink,
    reference.isSymbolicLink,
    reason: 'isSymbolicLink disagreement for $path',
  );
  expect(actual.mode, reference.mode, reason: 'mode disagreement for $path');
}

void main() {
  late Directory workspace;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('native-stat-test-');
  });

  tearDown(() async {
    try {
      await workspace.delete(recursive: true);
    } on FileSystemException {
      // Windows can hold handles briefly; best-effort cleanup.
    }
  });

  String path(String name) => p.join(workspace.path, name);

  group('nativeLstatSync classification', () {
    test('reports plain files and directories as present', () async {
      if (!Platform.isWindows) {
        return;
      }

      await File(path('plain.conf')).writeAsString('data');
      await Directory(path('subdir')).create();

      final fileAnswer = nativeLstatSync(path('plain.conf'));
      expect(fileAnswer.outcome, NativeStatOutcome.present);
      expect(fileAnswer.isFile, isTrue);
      expect(fileAnswer.isDirectory, isFalse);

      final dirAnswer = nativeLstatSync(path('subdir'));
      expect(dirAnswer.outcome, NativeStatOutcome.present);
      expect(dirAnswer.isDirectory, isTrue);
    });

    test('reports missing paths as absent', () {
      if (!Platform.isWindows) {
        return;
      }

      expect(
        nativeLstatSync(path('does-not-exist.conf')).outcome,
        NativeStatOutcome.absent,
      );
      expect(
        nativeLstatSync(path(p.join('missing-dir', 'nested.conf'))).outcome,
        NativeStatOutcome.absent,
      );
    });

    test('delegates symlink and junction nodes to dart:io', () async {
      if (!Platform.isWindows) {
        return;
      }

      final target = path('link-target.conf');
      await File(target).writeAsString('data');
      final linkPath = path('file-link.conf');
      await createSymlink(target, linkPath, SymlinkType.file);

      expect(nativeLstatSync(linkPath).outcome, NativeStatOutcome.cannotAnswer);

      final junctionTarget = path('junction-target');
      await Directory(junctionTarget).create();
      final junctionPath = path('junction-node');
      await createSymlink(junctionTarget, junctionPath, SymlinkType.junction);

      expect(
        nativeLstatSync(junctionPath).outcome,
        NativeStatOutcome.cannotAnswer,
      );
    });

    test('delegates on non-Windows platforms and oversized paths', () {
      if (!Platform.isWindows) {
        expect(
          nativeLstatSync(workspace.path).outcome,
          NativeStatOutcome.cannotAnswer,
        );
        return;
      }

      final longPath = path('n' * 300);
      expect(nativeLstatSync(longPath).outcome, NativeStatOutcome.cannotAnswer);
      expect(nativeLstatSync('').outcome, NativeStatOutcome.cannotAnswer);
    });
  });

  group('getPathStats parity with the dart:io reference', () {
    test('agrees on every fixture class', () async {
      final fixtures = <String>[];

      Future<String> file(String name, {bool readonly = false}) async {
        final filePath = path(name);
        await File(filePath).writeAsString('fixture');
        if (readonly && Platform.isWindows) {
          await Process.run('attrib', ['+R', filePath]);
          addTearDown(() => Process.run('attrib', ['-R', filePath]));
        }
        fixtures.add(filePath);
        return filePath;
      }

      await file('plain.conf');
      await file('note.txt');
      await file('tool.exe');
      await file('TOOL2.EXE');
      await file('run.bat');
      await file('run.cmd');
      await file('run.com');
      await file('exeish.exercise');
      await file('readonly.conf', readonly: true);
      await file('readonly.exe', readonly: true);
      await file('spaced name.conf');
      await file('유니코드-파일.conf');
      await file('trailing.dot.');

      await Directory(path('plain-dir')).create();
      fixtures.add(path('plain-dir'));
      await Directory(path('nested/deep')).create(recursive: true);
      fixtures.add(path('nested/deep'));

      // Link-shaped nodes: the fast path delegates, so parity must hold via
      // the fallback.
      final target = await file('symlink-target.conf');
      final fileLink = path('file-link.conf');
      await createSymlink(target, fileLink, SymlinkType.file);
      fixtures.add(fileLink);

      final dirLinkTarget = path('dir-link-target');
      await Directory(dirLinkTarget).create();
      final dirLink = path('dir-link');
      await createSymlink(dirLinkTarget, dirLink);
      fixtures.add(dirLink);

      final dangling = path('dangling-link.conf');
      await createSymlink(
        path('never-existed.conf'),
        dangling,
        SymlinkType.file,
      );
      fixtures.add(dangling);

      if (Platform.isWindows) {
        final junctionTarget = path('junction-target');
        await Directory(junctionTarget).create();
        final junction = path('junction-node');
        await createSymlink(junctionTarget, junction, SymlinkType.junction);
        fixtures.add(junction);
      }

      // Missing paths.
      fixtures.add(path('missing.conf'));
      fixtures.add(path(p.join('missing-dir', 'missing.conf')));

      for (final fixture in fixtures) {
        await expectAgreesWithReference(fixture);
      }
    });

    test('agrees through forward-slash separators on Windows', () async {
      if (!Platform.isWindows) {
        return;
      }

      await Directory(path('fwd/slash')).create(recursive: true);
      await File(path('fwd/slash/entry.conf')).writeAsString('x');

      final forwardSlashPath =
          '${workspace.path.replaceAll(r'\', '/')}/fwd/slash/entry.conf';
      await expectAgreesWithReference(forwardSlashPath);
    });
  });

  group('pathExists and getFollowedPathStats parity', () {
    test(
      'pathExists agrees for files, dirs, links, and missing paths',
      () async {
        await File(path('exists.conf')).writeAsString('x');
        await Directory(path('exists-dir')).create();
        final dangling = path('dangling.conf');
        await createSymlink(path('gone.conf'), dangling, SymlinkType.file);

        expect(await pathExists(path('exists.conf')), isTrue);
        expect(await pathExists(path('exists-dir')), isTrue);
        expect(await pathExists(path('missing.conf')), isFalse);
        // Dangling symlink: existence follows the chain — must report false,
        // matching FileSystemEntity.type(follow: true).
        expect(await pathExists(dangling), isFalse);
      },
    );

    test('getFollowedPathStats agrees with FileStat.stat', () async {
      await File(path('followed.conf')).writeAsString('x');

      final reference = await FileStat.stat(path('followed.conf'));
      final actual = await getFollowedPathStats(path('followed.conf'));

      expect(actual, isNotNull);
      expect(actual!.isFile, reference.type == FileSystemEntityType.file);
      expect(actual.mode, reference.mode);

      expect(await getFollowedPathStats(path('missing.conf')), isNull);
    });
  });
}
