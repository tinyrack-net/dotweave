import 'package:shipworld/homebrew.dart';
import 'package:shipworld/windows.dart';
import 'package:test/test.dart';

void main() {
  test('maps Flutter build metadata to the MSIX revision segment', () {
    expect(convertVersionToMsixVersion('1.2.3+42'), '1.2.3.42');
  });

  test('renders product-neutral MSIX metadata', () {
    final manifest = buildMsixManifest(
      arch: 'arm64',
      identity: const MsixIdentity(
        identityName: 'example.app',
        publisher: 'CN=Example',
        publisherDisplayName: 'Example',
      ),
      version: '1.2.3.4',
      config: const MsixConfig(
        applicationId: 'example',
        displayName: 'Example App',
        description: 'A Flutter desktop app',
        executableName: 'example.exe',
      ),
    );

    expect(manifest, contains('Id="example"'));
    expect(manifest, contains('Executable="example.exe"'));
    expect(manifest, contains('Description="A Flutter desktop app"'));
  });

  test('renders a Homebrew Cask for a Flutter app archive', () {
    final cask = generateHomebrewCask(
      token: 'example',
      version: '1.2.3',
      sha256: 'abc',
      url: 'https://example.test/example.zip',
      appName: 'Example',
      description: 'Example app',
      homepage: 'https://example.test',
    );

    expect(cask, contains('cask "example"'));
    expect(cask, contains('app "Example.app"'));
  });
}
