import 'dart:convert';
import 'dart:io';

import 'package:dotweave_tools/src/lib/version_files.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Matcher _throwsMessage(Pattern pattern) {
  return throwsA(predicate((Object? error) => '$error'.contains(pattern)));
}

void main() {
  final tempDirectories = <Directory>[];

  tearDown(() async {
    while (tempDirectories.isNotEmpty) {
      final directory = tempDirectories.removeLast();

      if (directory.existsSync()) {
        await directory.delete(recursive: true);
      }
    }
  });

  Future<Directory> createTempDir() async {
    final directory = await Directory.systemTemp.createTemp(
      'dotweave-pkgjson-',
    );
    tempDirectories.add(directory);
    return directory;
  }

  Future<String> writePackageJson(Directory dir, Object? data) async {
    final filePath = p.join(dir.path, 'package.json');
    const encoder = JsonEncoder.withIndent('  ');
    await File(filePath).writeAsString('${encoder.convert(data)}\n');
    return filePath;
  }

  Future<String> writeRawFile(
    Directory dir,
    String name,
    String content,
  ) async {
    final filePath = p.join(dir.path, name);
    await File(filePath).writeAsString(content);
    return filePath;
  }

  group('readPackageJsonVersion', () {
    test('reads version from valid package.json', () async {
      final dir = await createTempDir();
      final filePath = await writePackageJson(dir, {
        'name': 'foo',
        'version': '1.2.3',
      });

      expect(await readPackageJsonVersion(filePath), '1.2.3');
    });

    test('throws when version field is missing', () async {
      final dir = await createTempDir();
      final filePath = await writePackageJson(dir, {'name': 'foo'});

      await expectLater(
        readPackageJsonVersion(filePath),
        _throwsMessage('Missing version'),
      );
    });

    test('throws when version is a number', () async {
      final dir = await createTempDir();
      final filePath = await writePackageJson(dir, {'version': 42});

      await expectLater(
        readPackageJsonVersion(filePath),
        _throwsMessage('Missing version'),
      );
    });

    test('throws when version is null', () async {
      final dir = await createTempDir();
      final filePath = await writePackageJson(dir, {'version': null});

      await expectLater(
        readPackageJsonVersion(filePath),
        _throwsMessage('Missing version'),
      );
    });

    test('throws for JSON array', () async {
      final dir = await createTempDir();
      final filePath = await writeRawFile(dir, 'package.json', '[1, 2, 3]');

      await expectLater(
        readPackageJsonVersion(filePath),
        _throwsMessage('Invalid package.json'),
      );
    });

    test('throws for JSON null', () async {
      final dir = await createTempDir();
      final filePath = await writeRawFile(dir, 'package.json', 'null');

      await expectLater(
        readPackageJsonVersion(filePath),
        _throwsMessage('Invalid package.json'),
      );
    });
  });

  group('writePackageJsonVersion', () {
    test('writes updated version preserving other fields', () async {
      final dir = await createTempDir();
      final filePath = await writePackageJson(dir, {
        'description': 'bar',
        'name': 'foo',
        'version': '1.0.0',
      });

      await writePackageJsonVersion(filePath, '2.0.0');

      final raw = await File(filePath).readAsString();
      final parsed = jsonDecode(raw) as Map<String, Object?>;

      expect(parsed['version'], '2.0.0');
      expect(parsed['name'], 'foo');
      expect(parsed['description'], 'bar');
    });

    test('preserves 2-space indent and trailing newline', () async {
      final dir = await createTempDir();
      final filePath = await writePackageJson(dir, {'version': '1.0.0'});

      await writePackageJsonVersion(filePath, '2.0.0');

      final raw = await File(filePath).readAsString();

      expect(raw.endsWith('\n'), isTrue);
      expect(raw, matches(RegExp(r'^\{\n {2}"')));
    });
  });

  group('pubspec version helpers', () {
    test('reads version from pubspec.yaml', () async {
      final dir = await createTempDir();
      final filePath = await writeRawFile(
        dir,
        'pubspec.yaml',
        'name: dotweave\nversion: 0.53.0\n',
      );

      expect(await readPubspecVersion(filePath), '0.53.0');
    });

    test('throws when pubspec version is missing', () async {
      final dir = await createTempDir();
      final filePath = await writeRawFile(
        dir,
        'pubspec.yaml',
        'name: dotweave\n',
      );

      await expectLater(
        readPubspecVersion(filePath),
        _throwsMessage('Missing version'),
      );
    });

    test('updates version preserving comments and other fields', () async {
      final dir = await createTempDir();
      final filePath = await writeRawFile(
        dir,
        'pubspec.yaml',
        '# leading comment\n'
            'name: dotweave\n'
            'version: 0.53.0\n'
            'environment:\n'
            '  sdk: ^3.12.0\n',
      );

      await writePubspecVersion(filePath, '0.54.0');

      final raw = await File(filePath).readAsString();

      expect(raw, contains('# leading comment'));
      expect(raw, contains('version: 0.54.0'));
      expect(raw, contains('sdk: ^3.12.0'));
      expect(await readPubspecVersion(filePath), '0.54.0');
    });
  });

  group('version constant helpers', () {
    test('renders the generated file byte-exactly', () {
      expect(
        renderVersionConstant('1.2.3'),
        '// Generated from pubspec.yaml by the release tool. '
        'Do not edit by hand.\n'
        "const String packageVersion = '1.2.3';\n",
      );
    });

    test('round-trips write and read', () async {
      final dir = await createTempDir();
      final filePath = p.join(dir.path, 'version.g.dart');

      await writeVersionConstant(filePath, '9.8.7');

      expect(await readVersionConstant(filePath), '9.8.7');
    });

    test('throws when constant is missing', () async {
      final dir = await createTempDir();
      final filePath = await writeRawFile(
        dir,
        'version.g.dart',
        '// nothing here\n',
      );

      await expectLater(
        readVersionConstant(filePath),
        _throwsMessage('Missing packageVersion'),
      );
    });
  });
}
