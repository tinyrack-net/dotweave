import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shipworld/shipworld.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('shipworld-payload-');
  });

  tearDown(() async {
    await temporary.delete(recursive: true);
  });

  test('stages a single CLI executable', () async {
    final source = File(p.join(temporary.path, 'source.exe'));
    await source.writeAsString('cli');
    final destination = p.join(temporary.path, 'staged');

    await ExecutablePayload(
      executablePath: source.path,
      executableName: 'example.exe',
    ).stage(destination);

    expect(
      await File(p.join(destination, 'example.exe')).readAsString(),
      'cli',
    );
  });

  test(
    'stages a Flutter-style directory and preserves launcher path',
    () async {
      final source = Directory(p.join(temporary.path, 'flutter'));
      await Directory(p.join(source.path, 'data')).create(recursive: true);
      await File(p.join(source.path, 'app.exe')).writeAsString('launcher');
      await File(p.join(source.path, 'data', 'asset')).writeAsString('asset');
      final payload = DirectoryPayload(
        directoryPath: source.path,
        launcherRelativePath: 'app.exe',
      );
      final destination = p.join(temporary.path, 'staged');

      await payload.stage(destination);

      expect(payload.launcherRelativePath, 'app.exe');
      expect(
        await File(p.join(destination, 'data', 'asset')).readAsString(),
        'asset',
      );
    },
  );

  test('rejects launcher paths that escape the payload', () async {
    final source = Directory(p.join(temporary.path, 'bundle'));
    await source.create();
    await File(p.join(source.path, 'launcher')).writeAsString('binary');
    final payload = DirectoryPayload(
      directoryPath: source.path,
      launcherRelativePath: p.join('..', 'launcher'),
    );

    await expectLater(
      payload.stage(p.join(temporary.path, 'staged')),
      throwsA(
        isA<ShipworldException>().having(
          (error) => error.code,
          'code',
          'invalid_payload',
        ),
      ),
    );
  });
}
