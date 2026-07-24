import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'error.dart';
import 'exec.dart';

Future<T> withRetry<T>(
  Future<T> Function() fn, {
  int maxRetries = 2,
  Duration delay = const Duration(seconds: 30),
}) async {
  for (var attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      return await fn();
    } catch (_) {
      if (attempt == maxRetries) {
        rethrow;
      }

      stdout.writeln(
        'Attempt $attempt/$maxRetries failed, '
        'retrying in ${delay.inSeconds}s...',
      );
      await Future<void>.delayed(delay);
    }
  }

  throw StateError('Unreachable');
}

Future<void> _tryRun(String executable, List<String> args) async {
  try {
    await runChecked(executable, args);
  } on ToolException {
    // Ignore failures (e.g. no signature or attributes exist).
  }
}

Future<void> _deleteIfExists(String path) async {
  final file = File(path);

  if (file.existsSync()) {
    await file.delete();
  }
}

Future<void> performMacosSign({
  required String repoRoot,
  required String executablePath,
  required bool skipNotarize,
}) async {
  final resolvedExecutablePath = p.join(repoRoot, executablePath);
  final entitlementsPath = p.join(repoRoot, 'packages/cli/entitlements.plist');

  final env = Platform.environment;
  final appleCertificate = env['APPLE_CERTIFICATE'];
  final appleCertificatePassword = env['APPLE_CERTIFICATE_PASSWORD'];
  final appleDeveloperId = env['APPLE_DEVELOPER_ID'];
  final appleNotaryKeyId = env['APPLE_NOTARY_KEY_ID'];
  final appleNotaryIssuerId = env['APPLE_NOTARY_ISSUER_ID'];
  final appleNotaryKeyP8Base64 = env['APPLE_NOTARY_KEY_P8_BASE64'];

  stdout.writeln('Removing existing signature if any...');
  await _tryRun('codesign', ['--remove-signature', resolvedExecutablePath]);

  stdout.writeln('Removing extended attributes if any...');
  await _tryRun('xattr', ['-cr', resolvedExecutablePath]);

  if (appleCertificate != null && appleCertificate.isNotEmpty) {
    if (appleCertificatePassword == null ||
        appleCertificatePassword.isEmpty ||
        appleDeveloperId == null ||
        appleDeveloperId.isEmpty) {
      throw const ToolException(
        'APPLE_CERTIFICATE_PASSWORD and APPLE_DEVELOPER_ID are required '
        'when APPLE_CERTIFICATE is set',
      );
    }

    stdout.writeln('Importing Apple Certificate...');
    await File('certificate.p12').writeAsBytes(base64Decode(appleCertificate));

    try {
      await _tryRun('security', ['delete-keychain', 'build.keychain']);
      await runChecked('security', [
        'create-keychain',
        '-p',
        'actions',
        'build.keychain',
      ]);

      final listResult = await runChecked('security', ['list-keychains']);
      final keychainList = listResult.stdout
          .split('\n')
          .map((keychain) => keychain.trim())
          .where((keychain) => keychain.isNotEmpty)
          .toList();

      if (!keychainList.contains('build.keychain')) {
        await runChecked('security', [
          'list-keychains',
          '-s',
          ...keychainList,
          'build.keychain',
        ]);
      }

      await runChecked('security', [
        'default-keychain',
        '-s',
        'build.keychain',
      ]);
      await runChecked('security', [
        'unlock-keychain',
        '-p',
        'actions',
        'build.keychain',
      ]);
      await runChecked('security', [
        'import',
        'certificate.p12',
        '-k',
        'build.keychain',
        '-P',
        appleCertificatePassword,
        '-T',
        '/usr/bin/codesign',
      ]);
      await runChecked('security', [
        'set-key-partition-list',
        '-S',
        'apple-tool:,apple:,codesign:',
        '-s',
        '-k',
        'actions',
        'build.keychain',
      ]);

      stdout.writeln('Signing macOS binary...');
      await runChecked('codesign', [
        '--force',
        '--options',
        'runtime',
        '--entitlements',
        entitlementsPath,
        '--sign',
        appleDeveloperId,
        resolvedExecutablePath,
      ]);

      if (appleNotaryKeyP8Base64 != null &&
          appleNotaryKeyP8Base64.isNotEmpty &&
          !skipNotarize) {
        if (appleNotaryKeyId == null ||
            appleNotaryKeyId.isEmpty ||
            appleNotaryIssuerId == null ||
            appleNotaryIssuerId.isEmpty) {
          throw const ToolException(
            'APPLE_NOTARY_KEY_ID and APPLE_NOTARY_ISSUER_ID are required '
            'when APPLE_NOTARY_KEY_P8_BASE64 is set',
          );
        }

        stdout.writeln('Notarizing macOS binary...');
        await File(
          'AuthKey.p8',
        ).writeAsBytes(base64Decode(appleNotaryKeyP8Base64));

        final zipPath = '$resolvedExecutablePath.zip';
        await runChecked('zip', ['-j', zipPath, resolvedExecutablePath]);

        await withRetry(
          () => runChecked('xcrun', [
            'notarytool',
            'submit',
            zipPath,
            '--key',
            'AuthKey.p8',
            '--key-id',
            appleNotaryKeyId,
            '--issuer',
            appleNotaryIssuerId,
            '--wait',
          ]),
        );
        await _deleteIfExists('AuthKey.p8');
      } else if (skipNotarize) {
        stdout.writeln('Notarization skipped (--skip-notarize flag).');
      } else {
        stdout.writeln('No Notary API Key found. Skipping notarization.');
      }
    } finally {
      await _deleteIfExists('certificate.p12');
    }
  } else {
    stdout.writeln('No Apple Certificate found. Performing ad-hoc signing...');
    await runChecked('codesign', ['--sign', '-', resolvedExecutablePath]);
  }
}
