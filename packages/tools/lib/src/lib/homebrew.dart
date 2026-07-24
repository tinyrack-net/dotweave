import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'error.dart';

Future<String> calculateSha256(String filePath) async {
  final content = await File(filePath).readAsBytes();

  return sha256.convert(content).toString();
}

const List<String> homebrewArtifactNames = [
  'dotweave-macos-arm64',
  'dotweave-macos-x64',
  'dotweave-linux-x64',
  'dotweave-linux-arm64',
];

/// Renders a Homebrew formula. Byte-compatible with the pre-cutover
/// TypeScript generator.
String generateHomebrewFormula({
  required String className,
  required bool isVersioned,
  required String cleanVersion,
  required Map<String, String> hashes,
}) {
  final kegOnly = isVersioned ? '\n  keg_only :versioned_formula\n' : '';

  return '''
class $className < Formula
  desc "Git-backed configuration synchronization tool for dotfiles"
  homepage "https://dotweave.tinyrack.net"
  version "$cleanVersion"$kegOnly

  on_macos do
    on_arm do
      url "https://github.com/tinyrack-net/dotweave/releases/download/v$cleanVersion/dotweave-macos-arm64"
      sha256 "${hashes['dotweave-macos-arm64']}"
    end
    on_intel do
      url "https://github.com/tinyrack-net/dotweave/releases/download/v$cleanVersion/dotweave-macos-x64"
      sha256 "${hashes['dotweave-macos-x64']}"
    end
  end

  on_linux do
    on_intel do
      url "https://github.com/tinyrack-net/dotweave/releases/download/v$cleanVersion/dotweave-linux-x64"
      sha256 "${hashes['dotweave-linux-x64']}"
    end
    on_arm do
      url "https://github.com/tinyrack-net/dotweave/releases/download/v$cleanVersion/dotweave-linux-arm64"
      sha256 "${hashes['dotweave-linux-arm64']}"
    end
  end

  def install
    if OS.mac? && Hardware::CPU.arm?
      bin.install "dotweave-macos-arm64" => "dotweave"
    elsif OS.mac? && Hardware::CPU.intel?
      bin.install "dotweave-macos-x64" => "dotweave"
    elsif OS.linux? && Hardware::CPU.intel?
      bin.install "dotweave-linux-x64" => "dotweave"
    elsif OS.linux? && Hardware::CPU.arm?
      bin.install "dotweave-linux-arm64" => "dotweave"
    end
  end

  test do
    system "#{bin}/dotweave", "--version"
  end
end
''';
}

Future<void> performHomebrewGenerate({
  required String version,
  required String artifactsDir,
  required String repoRoot,
}) async {
  final cleanVersion = version.startsWith('v') ? version.substring(1) : version;
  final resolvedArtifactsDir = p.isAbsolute(artifactsDir)
      ? artifactsDir
      : p.normalize(p.join(repoRoot, artifactsDir));

  final hashes = <String, String>{};

  for (final artifactName in homebrewArtifactNames) {
    final filePath = p.join(resolvedArtifactsDir, artifactName);

    try {
      hashes[artifactName] = await calculateSha256(filePath);
    } on FileSystemException catch (error) {
      throw ToolException(
        'Failed to calculate hash for $artifactName at $filePath: $error',
      );
    }
  }

  final defaultFormula = generateHomebrewFormula(
    className: 'Dotweave',
    isVersioned: false,
    cleanVersion: cleanVersion,
    hashes: hashes,
  );
  final versionClassNameSuffix = cleanVersion.replaceAll('.', '');
  final versionedFormula = generateHomebrewFormula(
    className: 'DotweaveAT$versionClassNameSuffix',
    isVersioned: true,
    cleanVersion: cleanVersion,
    hashes: hashes,
  );

  final outPathDefault = p.join(resolvedArtifactsDir, 'dotweave.rb');
  final outPathVersioned = p.join(
    resolvedArtifactsDir,
    'dotweave@$cleanVersion.rb',
  );

  await File(outPathDefault).writeAsString(defaultFormula);
  await File(outPathVersioned).writeAsString(versionedFormula);

  stdout.writeln(
    'Generated Homebrew formulas: $outPathDefault, $outPathVersioned',
  );
}
