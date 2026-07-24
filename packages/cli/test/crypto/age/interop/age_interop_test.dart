@Tags(['interop'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dotweave/src/crypto/age/age.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Interop tests against the reference `age-encryption` npm package
/// (installed at this package's node_modules), driven via node.
void main() {
  final packageRoot = Directory.current.path;
  final script = p.join(
    packageRoot,
    'test',
    'crypto',
    'age',
    'interop',
    'age_interop.mjs',
  );

  Future<String> runNode(List<String> args, {String stdinText = ''}) async {
    final process = await Process.start('node', [
      script,
      ...args,
    ], workingDirectory: packageRoot);
    process.stdin.write(stdinText);
    await process.stdin.close();
    final stdout = await process.stdout.transform(utf8.decoder).join();
    final stderr = await process.stderr.transform(utf8.decoder).join();
    final exitCode = await process.exitCode;
    if (exitCode != 0) {
      fail('node ${args.join(' ')} failed ($exitCode): $stderr');
    }
    return stdout;
  }

  Uint8List randomPayload(int size, Random random) {
    return Uint8List.fromList(
      List<int>.generate(size, (_) => random.nextInt(256)),
    );
  }

  test('node and the age-encryption package are available', () async {
    final result = await Process.run('node', ['--version']);
    expect(
      result.exitCode,
      0,
      reason: 'node must be installed for interop tests',
    );
    final keys = await runNode(['keygen']);
    expect(keys.trim().split('\n'), hasLength(2));
  });

  test('TS and Dart derive the same recipient for a Dart identity', () async {
    final identity = generateIdentity();
    final tsRecipient = (await runNode(['recipient', identity])).trim();
    expect(tsRecipient, await identityToRecipient(identity));
  });

  test('Dart derives the same recipient for a TS identity', () async {
    final keys = (await runNode(['keygen'])).trim().split('\n');
    final tsIdentity = keys[0].trim();
    final tsRecipient = keys[1].trim();
    expect(await identityToRecipient(tsIdentity), tsRecipient);
  });

  test('Dart-encrypt -> TS-decrypt (armored)', () async {
    final random = Random(42);
    final keys = (await runNode(['keygen'])).trim().split('\n');
    final tsIdentity = keys[0].trim();
    final tsRecipient = keys[1].trim();

    for (final size in [0, 1, 100, 65536, 70000]) {
      final plaintext = randomPayload(size, random);
      final encrypter = AgeEncrypter()..addRecipient(tsRecipient);
      final armored = armorEncode(await encrypter.encrypt(plaintext));
      final decrypted = await runNode([
        'decrypt',
        tsIdentity,
      ], stdinText: armored);
      expect(base64Decode(decrypted.trim()), plaintext, reason: 'size $size');
    }
  });

  test('TS-encrypt -> Dart-decrypt (armored)', () async {
    final random = Random(1337);
    final identity = generateIdentity();
    final recipient = await identityToRecipient(identity);

    for (final size in [0, 1, 100, 65536, 70000]) {
      final plaintext = randomPayload(size, random);
      final armored = await runNode([
        'encrypt',
        recipient,
      ], stdinText: base64Encode(plaintext));
      final decrypter = AgeDecrypter()..addIdentity(identity);
      expect(
        await decrypter.decrypt(armorDecode(armored)),
        plaintext,
        reason: 'size $size',
      );
    }
  });

  test('multi-recipient interop in both directions', () async {
    final random = Random(7);
    final plaintext = randomPayload(5000, random);

    final dartIdentity = generateIdentity();
    final dartRecipient = await identityToRecipient(dartIdentity);
    final keys = (await runNode(['keygen'])).trim().split('\n');
    final tsIdentity = keys[0].trim();
    final tsRecipient = keys[1].trim();

    // Dart encrypts to both; TS decrypts with its identity.
    final encrypter = AgeEncrypter()
      ..addRecipient(dartRecipient)
      ..addRecipient(tsRecipient);
    final armored = armorEncode(await encrypter.encrypt(plaintext));
    final tsDecrypted = await runNode([
      'decrypt',
      tsIdentity,
    ], stdinText: armored);
    expect(base64Decode(tsDecrypted.trim()), plaintext);

    // TS encrypts to both; Dart decrypts with its identity.
    final tsArmored = await runNode([
      'encrypt',
      tsRecipient,
      dartRecipient,
    ], stdinText: base64Encode(plaintext));
    final decrypter = AgeDecrypter()..addIdentity(dartIdentity);
    expect(await decrypter.decrypt(armorDecode(tsArmored)), plaintext);
  });
}
