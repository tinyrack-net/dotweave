import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shipworld/release.dart';
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
      'shipworld-pubspec-',
    );
    tempDirectories.add(directory);
    return directory;
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

  group('pubspec version helpers', () {
    test('reads version from pubspec.yaml', () async {
      final dir = await createTempDir();
      final filePath = await writeRawFile(
        dir,
        'pubspec.yaml',
        'name: example_app\nversion: 0.53.0\n',
      );

      expect(await readPubspecVersion(filePath), '0.53.0');
    });

    test('throws when pubspec version is missing', () async {
      final dir = await createTempDir();
      final filePath = await writeRawFile(
        dir,
        'pubspec.yaml',
        'name: example_app\n',
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
            'name: example_app\n'
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
