import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dotweave_tools/src/lib/homebrew.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String _sha256Hex(String content) {
  return sha256.convert(utf8.encode(content)).toString();
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

  Future<Directory> createArtifactsDir() async {
    final directory = await Directory.systemTemp.createTemp('dotweave-');
    tempDirectories.add(directory);

    for (final name in homebrewArtifactNames) {
      await File(p.join(directory.path, name)).writeAsString(name);
    }

    return directory;
  }

  test(
    'generates syntactically valid Ruby formula with balanced blocks',
    () async {
      final artifactsDir = await createArtifactsDir();

      await performHomebrewGenerate(
        version: 'v0.42.9',
        artifactsDir: artifactsDir.path,
        repoRoot: artifactsDir.path,
      );

      final formula = await File(
        p.join(artifactsDir.path, 'dotweave.rb'),
      ).readAsString();

      expect(formula, contains('class Dotweave < Formula'));
      expect(formula, contains('def install'));
      expect(formula, contains('test do'));
      expect(
        formula,
        contains(
          'desc "Git-backed configuration synchronization tool for dotfiles"',
        ),
      );
    },
  );

  test('writes a versioned formula with keg_only and AT class name', () async {
    final artifactsDir = await createArtifactsDir();

    await performHomebrewGenerate(
      version: '0.42.9',
      artifactsDir: artifactsDir.path,
      repoRoot: artifactsDir.path,
    );

    final versionedFormula = await File(
      p.join(artifactsDir.path, 'dotweave@0.42.9.rb'),
    ).readAsString();

    expect(versionedFormula, contains('class DotweaveAT0429 < Formula'));
    expect(versionedFormula, contains('keg_only :versioned_formula'));
  });

  test('throws when an artifact is missing', () async {
    final artifactsDir = await createArtifactsDir();
    await File(p.join(artifactsDir.path, 'dotweave-linux-arm64')).delete();

    await expectLater(
      performHomebrewGenerate(
        version: 'v0.42.9',
        artifactsDir: artifactsDir.path,
        repoRoot: artifactsDir.path,
      ),
      throwsA(
        predicate(
          (Object? error) =>
              '$error'.contains('Failed to calculate hash') &&
              '$error'.contains('dotweave-linux-arm64'),
        ),
      ),
    );
  });

  test('generates a byte-exact default formula for known inputs', () async {
    final artifactsDir = await createArtifactsDir();

    await performHomebrewGenerate(
      version: 'v0.42.9',
      artifactsDir: artifactsDir.path,
      repoRoot: artifactsDir.path,
    );

    final formula = await File(
      p.join(artifactsDir.path, 'dotweave.rb'),
    ).readAsString();

    final macosArm = _sha256Hex('dotweave-macos-arm64');
    final macosX64 = _sha256Hex('dotweave-macos-x64');
    final linuxX64 = _sha256Hex('dotweave-linux-x64');
    final linuxArm = _sha256Hex('dotweave-linux-arm64');

    final expected =
        '''
class Dotweave < Formula
  desc "Git-backed configuration synchronization tool for dotfiles"
  homepage "https://dotweave.tinyrack.net"
  version "0.42.9"

  on_macos do
    on_arm do
      url "https://github.com/tinyrack-net/dotweave/releases/download/v0.42.9/dotweave-macos-arm64"
      sha256 "$macosArm"
    end
    on_intel do
      url "https://github.com/tinyrack-net/dotweave/releases/download/v0.42.9/dotweave-macos-x64"
      sha256 "$macosX64"
    end
  end

  on_linux do
    on_intel do
      url "https://github.com/tinyrack-net/dotweave/releases/download/v0.42.9/dotweave-linux-x64"
      sha256 "$linuxX64"
    end
    on_arm do
      url "https://github.com/tinyrack-net/dotweave/releases/download/v0.42.9/dotweave-linux-arm64"
      sha256 "$linuxArm"
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

    expect(formula, expected);
  });
}
