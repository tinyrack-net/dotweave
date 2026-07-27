import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shipworld/shipworld.dart';
import 'package:shipworld/windows.dart';
import 'package:test/test.dart';

const _config = MsixConfig(
  applicationId: 'ExampleApp',
  displayName: 'Example App',
  description: 'Example desktop application',
  executableName: 'example.exe',
);

Matcher _throwsMessage(Pattern pattern) {
  return throwsA(predicate((Object? error) => '$error'.contains(pattern)));
}

final class _WindowsExecutor implements ProcessExecutor {
  final inheritedCalls = <List<String>>[];

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    return ProcessResult(0, 0, '', '');
  }

  @override
  Future<int> runInherited(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    inheritedCalls.add([executable, ...arguments]);
    return 0;
  }
}

void main() {
  group('msix helpers', () {
    test('converts package semver to a four-part MSIX version', () {
      expect(convertVersionToMsixVersion('0.42.14'), '0.42.14.0');
    });

    test('strips prerelease suffix from version', () {
      expect(convertVersionToMsixVersion('1.0.0-beta.1'), '1.0.0.0');
    });

    test('rejects non-MSIX-compatible package versions', () {
      expect(
        () => convertVersionToMsixVersion('1.2'),
        _throwsMessage('Invalid package version'),
      );
      expect(
        () => convertVersionToMsixVersion('1.2.70000'),
        _throwsMessage('MSIX version segment out of range'),
      );
    });

    test('rejects version with non-numeric segments', () {
      expect(
        () => convertVersionToMsixVersion('1.x.3'),
        _throwsMessage('Invalid package version'),
      );
    });

    test('generates a packaged desktop manifest with an execution alias', () {
      final manifest = buildMsixManifest(
        arch: 'x64',
        config: _config,
        identity: const MsixIdentity(
          identityName: 'example.publisher.app',
          publisher: 'CN=Example',
          publisherDisplayName: 'Example Publisher',
        ),
        version: '0.42.14.0',
      );

      expect(
        manifest,
        contains(
          'xmlns:uap5='
          '"http://schemas.microsoft.com/appx/manifest/uap/windows10/5"',
        ),
      );
      expect(manifest, contains('Name="Windows.Desktop"'));
      expect(manifest, contains('<rescap:Capability Name="runFullTrust" />'));
      expect(manifest, contains('uap10:RuntimeBehavior="packagedClassicApp"'));
      expect(
        manifest,
        contains('<uap5:Extension Category="windows.appExecutionAlias">'),
      );
      expect(
        manifest,
        contains('<uap5:AppExecutionAlias desktop4:Subsystem="console">'),
      );
      expect(manifest, contains('<uap5:ExecutionAlias Alias="example.exe" />'));
    });

    test('escapes XML special characters in identity fields', () {
      final manifest = buildMsixManifest(
        arch: 'x64',
        config: _config,
        identity: const MsixIdentity(
          identityName: 'foo&bar<baz',
          publisher: 'CN="Test"',
          publisherDisplayName: 'test',
        ),
        version: '1.0.0.0',
      );

      expect(manifest, contains('Name="foo&amp;bar&lt;baz"'));
      expect(manifest, contains('Publisher="CN=&quot;Test&quot;"'));
    });

    test('generates a byte-exact manifest for known inputs', () {
      final manifest = buildMsixManifest(
        arch: 'x64',
        config: _config,
        identity: const MsixIdentity(
          identityName: 'example.publisher.app',
          publisher: 'CN=Example',
          publisherDisplayName: 'Example Publisher',
        ),
        version: '0.42.14.0',
      );

      const expected = '''
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
    Name="example.publisher.app"
    Publisher="CN=Example"
    Version="0.42.14.0"
    ProcessorArchitecture="x64" />
  <Properties>
    <DisplayName>Example App</DisplayName>
    <PublisherDisplayName>Example Publisher</PublisherDisplayName>
    <Logo>Assets\\StoreLogo.png</Logo>
  </Properties>
  <Resources>
    <Resource Language="en-US" />
  </Resources>
  <Dependencies>
    <TargetDeviceFamily
      Name="Windows.Desktop"
      MinVersion="10.0.19041.0"
      MaxVersionTested="10.0.26100.0" />
  </Dependencies>
  <Capabilities>
    <rescap:Capability Name="runFullTrust" />
  </Capabilities>
  <Applications>
    <Application
      Id="ExampleApp"
      Executable="example.exe"
      EntryPoint="Windows.FullTrustApplication"
      uap10:RuntimeBehavior="packagedClassicApp"
      uap10:TrustLevel="mediumIL"
      desktop4:SupportsMultipleInstances="true">
      <uap:VisualElements
        DisplayName="Example App"
        Description="Example desktop application"
        Square150x150Logo="Assets\\Square150x150Logo.png"
        Square44x44Logo="Assets\\Square44x44Logo.png"
        BackgroundColor="#102A43" />
      <Extensions>
        <uap5:Extension Category="windows.appExecutionAlias">
          <uap5:AppExecutionAlias desktop4:Subsystem="console">
            <uap5:ExecutionAlias Alias="example.exe" />
          </uap5:AppExecutionAlias>
        </uap5:Extension>
      </Extensions>
    </Application>
  </Applications>
</Package>
''';

      expect(manifest, expected);
    });
  });

  group('readMsixIdentityFromEnv', () {
    const baseEnv = {
      'MSIX_IDENTITY_NAME': 'example.publisher.app',
      'MSIX_PUBLISHER': 'CN=Example',
      'MSIX_PUBLISHER_DISPLAY_NAME': 'Example Publisher',
    };

    test('returns full identity when all required env vars present', () {
      final result = readMsixIdentityFromEnv(baseEnv);

      expect(result.identityName, 'example.publisher.app');
      expect(result.publisher, 'CN=Example');
      expect(result.publisherDisplayName, 'Example Publisher');
      expect(result.displayName, isNull);
    });

    test('includes displayName when MSIX_DISPLAY_NAME is non-empty', () {
      final result = readMsixIdentityFromEnv({
        ...baseEnv,
        'MSIX_DISPLAY_NAME': 'Example App',
      });

      expect(result.displayName, 'Example App');
    });

    test('omits displayName when MSIX_DISPLAY_NAME is empty string', () {
      final result = readMsixIdentityFromEnv({
        ...baseEnv,
        'MSIX_DISPLAY_NAME': '',
      });

      expect(result.displayName, isNull);
    });

    test('omits displayName when MSIX_DISPLAY_NAME is whitespace-only', () {
      final result = readMsixIdentityFromEnv({
        ...baseEnv,
        'MSIX_DISPLAY_NAME': '   ',
      });

      expect(result.displayName, isNull);
    });

    test('throws when MSIX_IDENTITY_NAME is missing', () {
      final envWithoutName = Map.of(baseEnv)..remove('MSIX_IDENTITY_NAME');

      expect(
        () => readMsixIdentityFromEnv(envWithoutName),
        _throwsMessage(RegExp('MSIX_IDENTITY_NAME.*required')),
      );
    });

    test('throws when MSIX_PUBLISHER is missing', () {
      final envWithoutPublisher = Map.of(baseEnv)..remove('MSIX_PUBLISHER');

      expect(
        () => readMsixIdentityFromEnv(envWithoutPublisher),
        _throwsMessage(RegExp('MSIX_PUBLISHER.*required')),
      );
    });

    test('throws when MSIX_PUBLISHER_DISPLAY_NAME is missing', () {
      final envWithoutDisplay = Map.of(baseEnv)
        ..remove('MSIX_PUBLISHER_DISPLAY_NAME');

      expect(
        () => readMsixIdentityFromEnv(envWithoutDisplay),
        _throwsMessage(RegExp('MSIX_PUBLISHER_DISPLAY_NAME.*required')),
      );
    });

    test('throws when required env var is empty string', () {
      expect(
        () => readMsixIdentityFromEnv({...baseEnv, 'MSIX_IDENTITY_NAME': ''}),
        _throwsMessage(RegExp('MSIX_IDENTITY_NAME.*required')),
      );
    });
  });

  test(
    'builds a directory payload through injected Windows SDK tools',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'shipworld-windows-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final payload = Directory(p.join(temporary.path, 'payload'));
      await payload.create();
      await File(p.join(payload.path, 'example.exe')).writeAsString('binary');
      final executor = _WindowsExecutor();
      final result =
          await WindowsPackagingService(
            ShipworldContext(
              process: executor,
              environment: const {
                'MAKEPRI_PATH': 'makepri-test',
                'MAKEAPPX_PATH': 'makeappx-test',
              },
            ),
          ).buildPackage(
            arch: 'arm64',
            payload: DirectoryPayload(
              directoryPath: payload.path,
              launcherRelativePath: 'example.exe',
            ),
            config: const MsixConfig(
              applicationId: 'Example',
              displayName: 'Example',
              description: 'Example application',
              executableName: 'example.exe',
            ),
            identity: const MsixIdentity(
              identityName: 'example.app',
              publisher: 'CN=Example',
              publisherDisplayName: 'Example',
            ),
            version: '1.2.3+4',
            repoRoot: temporary.path,
            outputPath: p.join('dist', 'example.msix'),
            packageRoot: p.join('.shipworld', 'msix'),
          );

      expect(result.outputPath, p.join(temporary.path, 'dist', 'example.msix'));
      expect(executor.inheritedCalls.first.first, 'makepri-test');
      expect(executor.inheritedCalls.last.first, 'makeappx-test');
      expect(
        await File(
          p.join(result.packageRoot, 'AppxManifest.xml'),
        ).readAsString(),
        allOf(
          contains('ProcessorArchitecture="arm64"'),
          contains('example.exe'),
        ),
      );
    },
  );
}
