import 'dart:io';

import 'package:crypto/crypto.dart';

/// One downloadable Homebrew artifact.
final class HomebrewArtifact {
  const HomebrewArtifact({
    required this.platform,
    required this.architecture,
    required this.url,
    required this.sha256,
    required this.fileName,
  });

  final String platform;
  final String architecture;
  final String url;
  final String sha256;
  final String fileName;
}

/// Product metadata for a generated Homebrew Formula.
final class HomebrewFormulaConfig {
  const HomebrewFormulaConfig({
    required this.className,
    required this.description,
    required this.homepage,
    required this.version,
    required this.executableName,
    this.versioned = false,
  });

  final String className;
  final String description;
  final String homepage;
  final String version;
  final String executableName;
  final bool versioned;
}

Future<String> calculateSha256(String filePath) async {
  final content = await File(filePath).readAsBytes();

  return sha256.convert(content).toString();
}

/// Renders a product-neutral Formula for macOS and Linux artifacts.
String generateConfigurableHomebrewFormula({
  required HomebrewFormulaConfig config,
  required List<HomebrewArtifact> artifacts,
}) {
  String artifact(String platform, String architecture) {
    return artifacts
        .singleWhere(
          (item) =>
              item.platform == platform && item.architecture == architecture,
        )
        .fileName;
  }

  HomebrewArtifact details(String platform, String architecture) {
    return artifacts.singleWhere(
      (item) => item.platform == platform && item.architecture == architecture,
    );
  }

  final macArm = details('macos', 'arm64');
  final macX64 = details('macos', 'x64');
  final linuxArm = details('linux', 'arm64');
  final linuxX64 = details('linux', 'x64');
  final kegOnly = config.versioned ? '\n  keg_only :versioned_formula\n' : '';

  return '''
class ${config.className} < Formula
  desc "${config.description}"
  homepage "${config.homepage}"
  version "${config.version}"$kegOnly

  on_macos do
    on_arm do
      url "${macArm.url}"
      sha256 "${macArm.sha256}"
    end
    on_intel do
      url "${macX64.url}"
      sha256 "${macX64.sha256}"
    end
  end

  on_linux do
    on_intel do
      url "${linuxX64.url}"
      sha256 "${linuxX64.sha256}"
    end
    on_arm do
      url "${linuxArm.url}"
      sha256 "${linuxArm.sha256}"
    end
  end

  def install
    if OS.mac? && Hardware::CPU.arm?
      bin.install "${artifact('macos', 'arm64')}" => "${config.executableName}"
    elsif OS.mac? && Hardware::CPU.intel?
      bin.install "${artifact('macos', 'x64')}" => "${config.executableName}"
    elsif OS.linux? && Hardware::CPU.intel?
      bin.install "${artifact('linux', 'x64')}" => "${config.executableName}"
    elsif OS.linux? && Hardware::CPU.arm?
      bin.install "${artifact('linux', 'arm64')}" => "${config.executableName}"
    end
  end

  test do
    system "#{bin}/${config.executableName}", "--version"
  end
end
''';
}

/// Renders a Homebrew Cask for a notarized macOS application archive.
String generateHomebrewCask({
  required String token,
  required String version,
  required String sha256,
  required String url,
  required String appName,
  required String description,
  required String homepage,
}) {
  return '''
cask "$token" do
  version "$version"
  sha256 "$sha256"

  url "$url"
  name "$appName"
  desc "$description"
  homepage "$homepage"

  app "$appName.app"
end
''';
}
