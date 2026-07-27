import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'context.dart';
import 'error.dart';
import 'process.dart';

/// Product-neutral macOS signing inputs.
final class MacosSignConfig {
  const MacosSignConfig({
    required this.inputPath,
    required this.entitlementsPath,
    this.skipNotarize = false,
    this.isAppBundle = false,
    this.environment,
  });

  final String inputPath;
  final String entitlementsPath;
  final bool skipNotarize;
  final bool isAppBundle;
  final Map<String, String>? environment;
}

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
  } on ShipworldException {
    // Ignore failures (e.g. no signature or attributes exist).
  }
}

/// Decodes a base64 secret leniently, like Node's `Buffer.from(s, 'base64')`
/// which the pre-cutover TS signing flow used: CI secrets produced with the
/// `base64` CLI wrap at 64/76 columns, and Dart's strict decoder rejects the
/// embedded newlines ("Invalid padding character").
List<int> decodeBase64Secret(String value) {
  return base64Decode(value.replaceAll(RegExp(r'\s'), ''));
}

Future<void> _deleteIfExists(String path) async {
  final file = File(path);

  if (file.existsSync()) {
    await file.delete();
  }
}

Future<void> signMacosExecutable({
  required String inputPath,
  required String entitlementsPath,
  required bool skipNotarize,
  Map<String, String>? environment,
}) async {
  final resolvedExecutablePath = p.normalize(p.absolute(inputPath));
  final env = environment ?? currentShipworldEnvironment;
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
      throw const ShipworldException(
        'APPLE_CERTIFICATE_PASSWORD and APPLE_DEVELOPER_ID are required '
        'when APPLE_CERTIFICATE is set',
      );
    }

    stdout.writeln('Importing Apple Certificate...');
    await File(
      'certificate.p12',
    ).writeAsBytes(decodeBase64Secret(appleCertificate));

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
          throw const ShipworldException(
            'APPLE_NOTARY_KEY_ID and APPLE_NOTARY_ISSUER_ID are required '
            'when APPLE_NOTARY_KEY_P8_BASE64 is set',
          );
        }

        stdout.writeln('Notarizing macOS binary...');
        await File(
          'AuthKey.p8',
        ).writeAsBytes(decodeBase64Secret(appleNotaryKeyP8Base64));

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

/// Signs a native executable or Flutter `.app` payload.
///
/// Flutter bundles are signed from their nested binaries outward before the
/// root application receives the hardened-runtime signature.
Future<void> signMacosPayload(MacosSignConfig config) async {
  if (!config.isAppBundle) {
    return signMacosExecutable(
      inputPath: config.inputPath,
      entitlementsPath: config.entitlementsPath,
      skipNotarize: config.skipNotarize,
      environment: config.environment,
    );
  }

  final env = config.environment ?? currentShipworldEnvironment;
  final developerId = env['APPLE_DEVELOPER_ID'];
  final identity = developerId != null && developerId.isNotEmpty
      ? developerId
      : '-';
  final nested = <File>[];

  await for (final entity in Directory(
    config.inputPath,
  ).list(recursive: true)) {
    if (entity is File &&
        (entity.path.endsWith('.dylib') ||
            entity.path.contains('${p.separator}Frameworks${p.separator}'))) {
      nested.add(entity);
    }
  }

  nested.sort((left, right) => right.path.length.compareTo(left.path.length));

  for (final file in nested) {
    await runChecked('codesign', [
      '--force',
      '--options',
      'runtime',
      '--sign',
      identity,
      file.path,
    ]);
  }

  await runChecked('codesign', [
    '--force',
    '--options',
    'runtime',
    '--entitlements',
    config.entitlementsPath,
    '--sign',
    identity,
    config.inputPath,
  ]);

  await runChecked('codesign', [
    '--verify',
    '--deep',
    '--strict',
    config.inputPath,
  ]);
}

/// Creates a metadata-preserving zip for a signed macOS application.
Future<String> archiveMacosApp({
  required String appPath,
  required String outputPath,
}) async {
  await runChecked('ditto', [
    '-c',
    '-k',
    '--keepParent',
    '--sequesterRsrc',
    appPath,
    outputPath,
  ]);

  return outputPath;
}

/// Context-bound macOS signing and archive API.
final class MacosPackagingService {
  const MacosPackagingService(this.context);

  final ShipworldContext context;

  Future<void> sign(MacosSignConfig config) {
    return context.run(() => signMacosPayload(config));
  }

  Future<String> archive({
    required String appPath,
    required String outputPath,
  }) {
    return context.run(
      () => archiveMacosApp(appPath: appPath, outputPath: outputPath),
    );
  }
}
