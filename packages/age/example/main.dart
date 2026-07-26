// Generate a keypair, encrypt to it, and decrypt back.
//
// Run it with:
//   dart run example/main.dart

import 'dart:convert';
import 'dart:typed_data';

import 'package:dotweave_age/dotweave_age.dart';

Future<void> main() async {
  final identity = generateIdentity();
  final recipient = await identityToRecipient(identity);

  print('recipient: $recipient');

  final encrypter = AgeEncrypter()..addRecipient(recipient);
  final ciphertext = await encrypter.encrypt(
    Uint8List.fromList(utf8.encode('secret')),
  );

  // `armorEncode` produces the PEM-style text form for storing in a file.
  print(armorEncode(ciphertext).split('\n').first);

  final decrypter = AgeDecrypter()..addIdentity(identity);
  final plaintext = await decrypter.decrypt(ciphertext);

  print('decrypted: ${utf8.decode(plaintext)}');
}
