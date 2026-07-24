import 'package:dotweave_tools/src/lib/msix.dart';
import 'package:test/test.dart';

Matcher _throwsMessage(Pattern pattern) {
  return throwsA(predicate((Object? error) => '$error'.contains(pattern)));
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

    test(
      'generates a packaged desktop manifest with a dotweave execution alias',
      () {
        final manifest = buildMsixManifest(
          arch: 'x64',
          identity: const MsixIdentity(
            identityName: 'tinyrack.dotweave',
            publisher: 'CN=tinyrack',
            publisherDisplayName: 'tinyrack',
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
        expect(
          manifest,
          contains('uap10:RuntimeBehavior="packagedClassicApp"'),
        );
        expect(
          manifest,
          contains('<uap5:Extension Category="windows.appExecutionAlias">'),
        );
        expect(
          manifest,
          contains('<uap5:AppExecutionAlias desktop4:Subsystem="console">'),
        );
        expect(
          manifest,
          contains('<uap5:ExecutionAlias Alias="dotweave.exe" />'),
        );
      },
    );

    test('escapes XML special characters in identity fields', () {
      final manifest = buildMsixManifest(
        arch: 'x64',
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
        identity: const MsixIdentity(
          identityName: 'tinyrack.dotweave',
          publisher: 'CN=tinyrack',
          publisherDisplayName: 'tinyrack',
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
    Name="tinyrack.dotweave"
    Publisher="CN=tinyrack"
    Version="0.42.14.0"
    ProcessorArchitecture="x64" />
  <Properties>
    <DisplayName>dotweave</DisplayName>
    <PublisherDisplayName>tinyrack</PublisherDisplayName>
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
      Id="dotweave"
      Executable="dotweave.exe"
      EntryPoint="Windows.FullTrustApplication"
      uap10:RuntimeBehavior="packagedClassicApp"
      uap10:TrustLevel="mediumIL"
      desktop4:SupportsMultipleInstances="true">
      <uap:VisualElements
        DisplayName="dotweave"
        Description="Git-backed configuration synchronization tool for dotfiles"
        Square150x150Logo="Assets\\Square150x150Logo.png"
        Square44x44Logo="Assets\\Square44x44Logo.png"
        BackgroundColor="#102A43" />
      <Extensions>
        <uap5:Extension Category="windows.appExecutionAlias">
          <uap5:AppExecutionAlias desktop4:Subsystem="console">
            <uap5:ExecutionAlias Alias="dotweave.exe" />
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
      'MSIX_IDENTITY_NAME': 'tinyrack.dotweave',
      'MSIX_PUBLISHER': 'CN=tinyrack',
      'MSIX_PUBLISHER_DISPLAY_NAME': 'tinyrack',
    };

    test('returns full identity when all required env vars present', () {
      final result = readMsixIdentityFromEnv(baseEnv);

      expect(result.identityName, 'tinyrack.dotweave');
      expect(result.publisher, 'CN=tinyrack');
      expect(result.publisherDisplayName, 'tinyrack');
      expect(result.displayName, isNull);
    });

    test('includes displayName when MSIX_DISPLAY_NAME is non-empty', () {
      final result = readMsixIdentityFromEnv({
        ...baseEnv,
        'MSIX_DISPLAY_NAME': 'Dotweave',
      });

      expect(result.displayName, 'Dotweave');
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
}
