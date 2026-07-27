import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shipworld/macos.dart';
import 'package:shipworld/shipworld.dart';
import 'package:test/test.dart';

final class _MacExecutor implements ProcessExecutor {
  final calls = <List<String>>[];

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    calls.add([executable, ...arguments]);
    return ProcessResult(0, 0, '', '');
  }

  @override
  Future<int> runInherited(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) {
    throw UnimplementedError();
  }
}

void main() {
  group('decodeBase64Secret', () {
    final payload = List<int>.generate(180, (index) => index % 251);
    final encoded = base64Encode(payload);

    test('decodes plain single-line base64', () {
      expect(decodeBase64Secret(encoded), payload);
    });

    test('decodes base64 wrapped at 64 columns like the base64 CLI', () {
      final wrapped = RegExp(
        '.{1,64}',
      ).allMatches(encoded).map((match) => match.group(0)).join('\n');

      // Dart's strict decoder rejects this shape outright — the lenient
      // helper must accept it (Node Buffer.from(s, 'base64') semantics the
      // CI secrets were created for).
      expect(() => base64Decode(wrapped), throwsFormatException);
      expect(decodeBase64Secret(wrapped), payload);
    });

    test('decodes base64 with surrounding whitespace and CRLF wrapping', () {
      final wrapped = RegExp(
        '.{1,76}',
      ).allMatches(encoded).map((match) => match.group(0)).join('\r\n');

      expect(decodeBase64Secret(' $wrapped\r\n'), payload);
    });
  });

  test('signs nested Flutter binaries before the app bundle', () async {
    final temporary = await Directory.systemTemp.createTemp('shipworld-macos-');
    addTearDown(() => temporary.delete(recursive: true));
    final app = Directory(p.join(temporary.path, 'Example.app'));
    final framework = File(
      p.join(app.path, 'Contents', 'Frameworks', 'example.dylib'),
    );
    await framework.parent.create(recursive: true);
    await framework.writeAsString('binary');
    final entitlements = File(p.join(temporary.path, 'entitlements.plist'));
    await entitlements.writeAsString('<plist/>');
    final executor = _MacExecutor();

    await MacosPackagingService(ShipworldContext(process: executor)).sign(
      MacosSignConfig(
        inputPath: app.path,
        entitlementsPath: entitlements.path,
        skipNotarize: true,
        isAppBundle: true,
      ),
    );

    expect(executor.calls.first.last, framework.path);
    expect(
      executor.calls.any(
        (call) => call.contains('--entitlements') && call.last == app.path,
      ),
      isTrue,
    );
    expect(executor.calls.last, contains('--verify'));
  });
}
