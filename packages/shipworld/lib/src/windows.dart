import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'context.dart';
import 'error.dart';
import 'payload.dart';
import 'process.dart';

const List<String> msixArchitectures = ['x64', 'arm64'];

String parseMsixArchitecture(String value) {
  if (!msixArchitectures.contains(value)) {
    throw ShipworldException(
      'Invalid MSIX architecture: $value. '
      'Must be one of: ${msixArchitectures.join(', ')}',
    );
  }

  return value;
}

class MsixIdentity {
  const MsixIdentity({
    required this.identityName,
    required this.publisher,
    required this.publisherDisplayName,
    this.displayName,
  });

  final String identityName;
  final String publisher;
  final String publisherDisplayName;
  final String? displayName;
}

/// Product metadata used to render and build an MSIX package.
final class MsixConfig {
  const MsixConfig({
    required this.applicationId,
    required this.displayName,
    required this.description,
    required this.executableName,
    this.defaultLanguage = 'en-US',
    this.minWindowsVersion = '10.0.19041.0',
    this.maxTestedWindowsVersion = '10.0.26100.0',
    this.backgroundColor = '#102A43',
  });

  final String applicationId;
  final String displayName;
  final String description;
  final String executableName;
  final String defaultLanguage;
  final String minWindowsVersion;
  final String maxTestedWindowsVersion;
  final String backgroundColor;
}

String _resolveRepoPath(String repoRoot, String path) {
  return p.normalize(p.join(repoRoot, path));
}

String _readRequiredEnv(Map<String, String> env, String name) {
  final value = env[name];

  if (value == null || value.trim().isEmpty) {
    throw ShipworldException(
      '$name is required to build Windows MSIX packages',
    );
  }

  return value;
}

MsixIdentity readMsixIdentityFromEnv([Map<String, String>? environment]) {
  final env = environment ?? currentShipworldEnvironment;
  final displayName = env['MSIX_DISPLAY_NAME'];

  return MsixIdentity(
    identityName: _readRequiredEnv(env, 'MSIX_IDENTITY_NAME'),
    publisher: _readRequiredEnv(env, 'MSIX_PUBLISHER'),
    publisherDisplayName: _readRequiredEnv(env, 'MSIX_PUBLISHER_DISPLAY_NAME'),
    displayName: displayName != null && displayName.trim().isNotEmpty
        ? displayName
        : null,
  );
}

final RegExp _digitsPattern = RegExp(r'^\d+$');

String convertVersionToMsixVersion(String version) {
  final stableAndBuild = version.split('-').first;
  final buildParts = stableAndBuild.split('+');
  final coreVersion = buildParts.first;
  final parts = coreVersion.split('.');

  if (parts.length != 3) {
    throw ShipworldException('Invalid package version for MSIX: $version');
  }

  final numericParts = <int>[];

  for (final part in parts) {
    if (!_digitsPattern.hasMatch(part)) {
      throw ShipworldException('Invalid package version for MSIX: $version');
    }

    final value = int.parse(part);

    if (value < 0 || value > 65535) {
      throw ShipworldException('MSIX version segment out of range: $part');
    }

    numericParts.add(value);
  }

  var build = 0;
  if (buildParts.length > 1) {
    if (buildParts.length != 2 || !_digitsPattern.hasMatch(buildParts[1])) {
      throw ShipworldException('Invalid package version for MSIX: $version');
    }

    build = int.parse(buildParts[1]);
    if (build > 65535) {
      throw ShipworldException(
        'MSIX version segment out of range: ${buildParts[1]}',
      );
    }
  }

  return '${numericParts[0]}.${numericParts[1]}.${numericParts[2]}.$build';
}

String _escapeXml(String value) {
  return value
      .replaceAll('&', '&amp;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}

String buildMsixManifest({
  required String arch,
  required MsixIdentity identity,
  required String version,
  required MsixConfig config,
}) {
  final displayName = identity.displayName ?? config.displayName;

  return '''
<?xml version="1.0" encoding="utf-8"?>
<Package
  xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
  xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10"
  xmlns:uap5="http://schemas.microsoft.com/appx/manifest/uap/windows10/5"
  xmlns:uap10="http://schemas.microsoft.com/appx/manifest/uap/windows10/10"
  xmlns:desktop4="http://schemas.microsoft.com/appx/manifest/desktop/windows10/4"
  xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities"
  IgnorableNamespaces="uap uap5 uap10 desktop4 rescap">
  <Identity
    Name="${_escapeXml(identity.identityName)}"
    Publisher="${_escapeXml(identity.publisher)}"
    Version="${_escapeXml(version)}"
    ProcessorArchitecture="$arch" />
  <Properties>
    <DisplayName>${_escapeXml(displayName)}</DisplayName>
    <PublisherDisplayName>${_escapeXml(identity.publisherDisplayName)}</PublisherDisplayName>
    <Logo>Assets\\StoreLogo.png</Logo>
  </Properties>
  <Resources>
    <Resource Language="${_escapeXml(config.defaultLanguage)}" />
  </Resources>
  <Dependencies>
    <TargetDeviceFamily
      Name="Windows.Desktop"
      MinVersion="${_escapeXml(config.minWindowsVersion)}"
      MaxVersionTested="${_escapeXml(config.maxTestedWindowsVersion)}" />
  </Dependencies>
  <Capabilities>
    <rescap:Capability Name="runFullTrust" />
  </Capabilities>
  <Applications>
    <Application
      Id="${_escapeXml(config.applicationId)}"
      Executable="${_escapeXml(config.executableName)}"
      EntryPoint="Windows.FullTrustApplication"
      uap10:RuntimeBehavior="packagedClassicApp"
      uap10:TrustLevel="mediumIL"
      desktop4:SupportsMultipleInstances="true">
      <uap:VisualElements
        DisplayName="${_escapeXml(displayName)}"
        Description="${_escapeXml(config.description)}"
        Square150x150Logo="Assets\\Square150x150Logo.png"
        Square44x44Logo="Assets\\Square44x44Logo.png"
        BackgroundColor="${_escapeXml(config.backgroundColor)}" />
      <Extensions>
        <uap5:Extension Category="windows.appExecutionAlias">
          <uap5:AppExecutionAlias desktop4:Subsystem="console">
            <uap5:ExecutionAlias Alias="${_escapeXml(config.executableName)}" />
          </uap5:AppExecutionAlias>
        </uap5:Extension>
      </Extensions>
    </Application>
  </Applications>
</Package>
''';
}

final List<int> _crcTable = List<int>.generate(256, (index) {
  var crc = index;

  for (var bit = 0; bit < 8; bit++) {
    crc = (crc & 1) == 1 ? 0xedb88320 ^ (crc >> 1) : crc >> 1;
  }

  return crc;
});

int _crc32(List<List<int>> buffers) {
  var crc = 0xffffffff;

  for (final buffer in buffers) {
    for (final byte in buffer) {
      crc = (crc >> 8) ^ _crcTable[(crc ^ byte) & 0xff];
    }
  }

  return (crc ^ 0xffffffff) & 0xffffffff;
}

Uint8List _pngChunk(String type, List<int> data) {
  final typeBytes = ascii.encode(type);
  final chunk = BytesBuilder(copy: false);
  final length = ByteData(4)..setUint32(0, data.length);
  final crc = ByteData(4)..setUint32(0, _crc32([typeBytes, data]));

  chunk.add(length.buffer.asUint8List());
  chunk.add(typeBytes);
  chunk.add(data);
  chunk.add(crc.buffer.asUint8List());

  return chunk.takeBytes();
}

Uint8List _createLogoPng(int size) {
  const bytesPerPixel = 4;
  final rowSize = 1 + size * bytesPerPixel;
  final raw = Uint8List(rowSize * size);
  const base = [16, 42, 67, 255];
  const accent = [20, 184, 166, 255];
  const light = [245, 247, 250, 255];
  final bandStart = (size * 0.22).floor();
  final bandEnd = (size * 0.34).floor();
  final markStart = (size * 0.42).floor();
  final markEnd = (size * 0.58).floor();

  for (var y = 0; y < size; y++) {
    final rowOffset = y * rowSize;
    raw[rowOffset] = 0;

    for (var x = 0; x < size; x++) {
      final pixelOffset = rowOffset + 1 + x * bytesPerPixel;
      final List<int> color;

      if ((x >= bandStart && x <= bandEnd) ||
          (x >= markStart && x <= markEnd && y >= markStart && y <= markEnd)) {
        color = accent;
      } else if (x >= markStart && x <= markEnd) {
        color = light;
      } else {
        color = base;
      }

      raw[pixelOffset] = color[0];
      raw[pixelOffset + 1] = color[1];
      raw[pixelOffset + 2] = color[2];
      raw[pixelOffset + 3] = color[3];
    }
  }

  final signature = Uint8List.fromList([
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, //
  ]);
  final ihdr = ByteData(13)
    ..setUint32(0, size)
    ..setUint32(4, size);
  final ihdrBytes = ihdr.buffer.asUint8List();
  ihdrBytes[8] = 8;
  ihdrBytes[9] = 6;
  ihdrBytes[10] = 0;
  ihdrBytes[11] = 0;
  ihdrBytes[12] = 0;

  final png = BytesBuilder(copy: false);
  png.add(signature);
  png.add(_pngChunk('IHDR', ihdrBytes));
  png.add(_pngChunk('IDAT', ZLibEncoder().encode(raw)));
  png.add(_pngChunk('IEND', const []));

  return png.takeBytes();
}

Future<void> _writeMsixAssets(String assetsDirectory) async {
  await Directory(assetsDirectory).create(recursive: true);

  await File(
    p.join(assetsDirectory, 'StoreLogo.png'),
  ).writeAsBytes(_createLogoPng(50));
  await File(
    p.join(assetsDirectory, 'Square44x44Logo.png'),
  ).writeAsBytes(_createLogoPng(44));
  await File(
    p.join(assetsDirectory, 'Square150x150Logo.png'),
  ).writeAsBytes(_createLogoPng(150));
}

final RegExp _naturalChunkPattern = RegExp(r'(\d+)|(\D+)');

int _compareNatural(String left, String right) {
  final leftChunks = _naturalChunkPattern.allMatches(left).toList();
  final rightChunks = _naturalChunkPattern.allMatches(right).toList();
  final length = leftChunks.length < rightChunks.length
      ? leftChunks.length
      : rightChunks.length;

  for (var index = 0; index < length; index++) {
    final leftDigits = leftChunks[index].group(1);
    final rightDigits = rightChunks[index].group(1);
    int comparison;

    if (leftDigits != null && rightDigits != null) {
      comparison = int.parse(leftDigits).compareTo(int.parse(rightDigits));
    } else {
      comparison = leftChunks[index]
          .group(0)!
          .compareTo(rightChunks[index].group(0)!);
    }

    if (comparison != 0) {
      return comparison;
    }
  }

  return leftChunks.length.compareTo(rightChunks.length);
}

Future<String> _findWindowsSdkTool(String toolName) async {
  final env = currentShipworldEnvironment;
  String? value(String name) {
    final direct = env[name];
    if (direct != null) return direct;
    final normalized = name.toLowerCase();
    for (final entry in env.entries) {
      if (entry.key.toLowerCase() == normalized) return entry.value;
    }
    return null;
  }

  final envOverride = value('${toolName.toUpperCase()}_PATH');

  if (envOverride != null && envOverride.trim().isNotEmpty) {
    return envOverride;
  }

  if (!Platform.isWindows) {
    throw ShipworldException(
      '$toolName.exe is only available on Windows runners',
    );
  }

  final windowsSdkDir = value('WindowsSdkDir');
  final programFiles = value('ProgramFiles');
  final programFilesX86 = value('ProgramFiles(x86)');

  final sdkRoots = <String>[
    if (windowsSdkDir != null) p.join(windowsSdkDir, 'bin'),
    if (programFilesX86 != null)
      p.join(programFilesX86, 'Windows Kits', '10', 'bin'),
    if (programFiles != null) p.join(programFiles, 'Windows Kits', '10', 'bin'),
  ];

  for (final sdkRoot in sdkRoots) {
    List<String> versions;

    try {
      versions =
          Directory(sdkRoot)
              .listSync()
              .whereType<Directory>()
              .map((entry) => p.basename(entry.path))
              .toList()
            ..sort((left, right) => _compareNatural(right, left));
    } on FileSystemException {
      continue;
    }

    for (final version in versions) {
      for (final arch in ['x64', 'x86']) {
        final candidate = p.join(sdkRoot, version, arch, '$toolName.exe');

        if (File(candidate).existsSync()) {
          return candidate;
        }
      }
    }

    try {
      final fallback =
          Directory(sdkRoot)
              .listSync(recursive: true)
              .whereType<File>()
              .where(
                (entry) =>
                    p.basename(entry.path).toLowerCase() ==
                    '$toolName.exe'.toLowerCase(),
              )
              .map((entry) => entry.path)
              .toList()
            ..sort((left, right) => _compareNatural(right, left));
      if (fallback.isNotEmpty) return fallback.first;
    } on FileSystemException {
      // Continue to the next configured SDK root.
    }
  }

  throw ShipworldException(
    'Windows SDK tool $toolName.exe was not found. '
    'Set ${toolName.toUpperCase()}_PATH to its absolute path.',
    code: 'missing_platform_tool',
  );
}

Future<void> _createPriFile(String packageRoot) async {
  final makePriPath = await _findWindowsSdkTool('makepri');
  final priConfigPath = p.join(packageRoot, 'priconfig.xml');

  await runInherited(makePriPath, [
    'createconfig',
    '/cf',
    priConfigPath,
    '/dq',
    'en-US',
  ], workingDirectory: packageRoot);

  await runInherited(makePriPath, [
    'new',
    '/pr',
    packageRoot,
    '/cf',
    priConfigPath,
  ], workingDirectory: packageRoot);

  final priConfigFile = File(priConfigPath);

  if (priConfigFile.existsSync()) {
    await priConfigFile.delete();
  }
}

/// Builds an MSIX package from a prebuilt executable or directory payload.
Future<({String outputPath, String packageRoot})> buildMsixPackage({
  required String arch,
  required ArtifactPayload payload,
  required MsixConfig config,
  required MsixIdentity identity,
  required String version,
  required String repoRoot,
  required String outputPath,
  required String packageRoot,
}) async {
  if (version.contains('-')) {
    throw ShipworldException(
      'Prerelease versions cannot be packaged for MSIX: $version',
    );
  }

  final resolvedPackageRoot = _resolveRepoPath(repoRoot, packageRoot);
  final resolvedOutputPath = _resolveRepoPath(repoRoot, outputPath);

  await _removeDirectory(resolvedPackageRoot);
  await Directory(resolvedPackageRoot).create(recursive: true);
  await Directory(p.dirname(resolvedOutputPath)).create(recursive: true);
  await payload.stage(resolvedPackageRoot);
  await File(p.join(resolvedPackageRoot, 'AppxManifest.xml')).writeAsString(
    buildMsixManifest(
      arch: arch,
      identity: identity,
      version: convertVersionToMsixVersion(version),
      config: config,
    ),
  );
  await _writeMsixAssets(p.join(resolvedPackageRoot, 'Assets'));
  await _createPriFile(resolvedPackageRoot);

  final makeAppxPath = await _findWindowsSdkTool('makeappx');

  await runInherited(makeAppxPath, [
    'pack',
    '/v',
    '/o',
    '/h',
    'SHA256',
    '/d',
    resolvedPackageRoot,
    '/p',
    resolvedOutputPath,
  ], workingDirectory: repoRoot);

  return (outputPath: resolvedOutputPath, packageRoot: resolvedPackageRoot);
}

Future<void> _removeDirectory(String path) async {
  final directory = Directory(path);

  if (directory.existsSync()) {
    await directory.delete(recursive: true);
  }
}

/// Bundles architecture-specific MSIX packages.
Future<String> buildMsixBundle({
  required String repoRoot,
  required String version,
  required String packageDir,
  required String outputPath,
  required String workingDirectory,
}) async {
  final resolvedPackageDir = _resolveRepoPath(repoRoot, packageDir);
  final resolvedOutputPath = _resolveRepoPath(repoRoot, outputPath);
  final bundleInputDir = _resolveRepoPath(repoRoot, workingDirectory);
  final packageNames =
      Directory(resolvedPackageDir)
          .listSync()
          .whereType<File>()
          .map((entry) => p.basename(entry.path))
          .where((name) => name.endsWith('.msix'))
          .toList()
        ..sort();

  if (packageNames.isEmpty) {
    throw ShipworldException('No .msix packages found in $resolvedPackageDir');
  }

  await _removeDirectory(bundleInputDir);
  await Directory(bundleInputDir).create(recursive: true);

  for (final packageName in packageNames) {
    await File(
      p.join(resolvedPackageDir, packageName),
    ).copy(p.join(bundleInputDir, packageName));
  }

  final makeAppxPath = await _findWindowsSdkTool('makeappx');

  await runInherited(makeAppxPath, [
    'bundle',
    '/v',
    '/o',
    '/bv',
    convertVersionToMsixVersion(version),
    '/d',
    bundleInputDir,
    '/p',
    resolvedOutputPath,
  ], workingDirectory: repoRoot);

  return resolvedOutputPath;
}

/// Context-bound Windows packaging API used by applications and the CLI.
final class WindowsPackagingService {
  const WindowsPackagingService(this.context);

  final ShipworldContext context;

  Future<({String outputPath, String packageRoot})> buildPackage({
    required String arch,
    required ArtifactPayload payload,
    required MsixConfig config,
    required MsixIdentity identity,
    required String version,
    required String repoRoot,
    required String outputPath,
    required String packageRoot,
  }) {
    return context.run(
      () => buildMsixPackage(
        arch: arch,
        payload: payload,
        config: config,
        identity: identity,
        version: version,
        repoRoot: repoRoot,
        outputPath: outputPath,
        packageRoot: packageRoot,
      ),
    );
  }

  Future<String> buildBundle({
    required String repoRoot,
    required String version,
    required String packageDir,
    required String outputPath,
    required String workingDirectory,
  }) {
    return context.run(
      () => buildMsixBundle(
        repoRoot: repoRoot,
        version: version,
        packageDir: packageDir,
        outputPath: outputPath,
        workingDirectory: workingDirectory,
      ),
    );
  }
}
