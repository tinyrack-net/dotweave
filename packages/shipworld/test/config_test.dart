import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shipworld/shipworld.dart';
import 'package:test/test.dart';

void main() {
  test('loads independently versioned package targets', () async {
    final config = await loadShipworldConfig(
      p.join('example', 'multi_package', 'shipworld.yaml'),
    );

    expect(config.targets.keys, ['cliweave', 'dartage']);
    expect(config.target('cliweave').kind, ShipworldTargetKind.pubPackage);
    expect(config.target('dartage').renderTag('0.2.0'), 'dartage-v0.2.0');
  });

  test('rejects unknown schema versions', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'shipworld-config-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final file = File(p.join(temporary.path, 'shipworld.yaml'));
    await file.writeAsString(
      'schema: 2\nremote: origin\n'
      'batch-commit: "release: {targets}"\ntargets: {}\n',
    );

    await expectLater(
      loadShipworldConfig(file.path),
      throwsA(
        isA<ShipworldException>().having(
          (error) => error.code,
          'code',
          'unsupported_schema',
        ),
      ),
    );

    await file.writeAsString('''
schema: 1
remote: origin
batch-commit: "release: {targets}"
targets:
  bad:
    kind: pub-package
    root: ../outside
    version:
      source: pubspec.yaml
    tag: "bad-v{version}"
    commit: "release: bad {version}"
    branch: main
''');
    await expectLater(
      loadShipworldConfig(file.path),
      throwsA(
        isA<ShipworldException>().having(
          (error) => error.code,
          'code',
          'invalid_path',
        ),
      ),
    );
  });

  test('parses typed Flutter desktop packaging sections', () async {
    final config = await loadShipworldConfig(
      p.join('test', 'fixtures', 'flutter_app', 'shipworld.yaml'),
    );
    final target = config.target('fixture');

    expect(target.kind, ShipworldTargetKind.flutterApplication);
    expect(target.payload?.kind, PayloadKind.directory);
    expect(target.windows?.identityEnvironment.name, 'SHIPWORLD_MSIX_NAME');
    expect(target.macos?.entitlements, 'entitlements.plist');
    expect(target.linux?.categories, ['Utility']);
    expect(target.homebrew?.formulaClass, 'ShipworldFixture');
  });

  test('rejects unknown fields and escaping target roots', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'shipworld-config-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final file = File(p.join(temporary.path, 'shipworld.yaml'));
    await file.writeAsString('''
schema: 1
remote: origin
batch-commit: "release: {targets}"
unexpected: true
targets:
  bad:
    kind: pub-package
    root: ../outside
    version:
      source: pubspec.yaml
    tag: "bad-v{version}"
    commit: "release: bad {version}"
    branch: main
''');

    await expectLater(
      loadShipworldConfig(file.path),
      throwsA(
        isA<ShipworldException>().having(
          (error) => error.code,
          'code',
          'invalid_config',
        ),
      ),
    );
  });

  test('ships a valid JSON Schema document', () async {
    final schema =
        jsonDecode(
              await File(
                p.join('schema', 'shipworld.schema.json'),
              ).readAsString(),
            )
            as Map<String, Object?>;

    expect(schema['title'], 'Shipworld configuration');
    expect(schema[r'$defs'], isA<Map<String, Object?>>());
  });
}
