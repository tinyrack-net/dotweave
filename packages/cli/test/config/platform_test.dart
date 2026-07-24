import 'package:dotweave/src/config/platform.dart';
import 'package:test/test.dart';

void main() {
  group('detectCurrentPlatformKey', () {
    test('maps win32 to win', () {
      expect(detectCurrentPlatformKey('win32', '10.0.0', null, null), 'win');
    });

    test('maps darwin to mac', () {
      expect(detectCurrentPlatformKey('darwin', '24.0.0', null, null), 'mac');
    });

    test('maps linux to linux', () {
      expect(detectCurrentPlatformKey('linux', '6.6.0', null, null), 'linux');
    });

    test('maps linux with WSL markers to wsl', () {
      expect(
        detectCurrentPlatformKey(
          'linux',
          '6.6.87.2-microsoft-standard-WSL2',
          null,
          null,
        ),
        'wsl',
      );
    });

    test('maps unknown platforms to linux', () {
      expect(
        detectCurrentPlatformKey('freebsd', '14.0.0', null, null),
        'linux',
      );
    });
  });

  group('isWslEnvironment', () {
    test('accepts explicit WSL markers', () {
      expect(isWslEnvironment('6.6.0', 'Ubuntu', null), true);
      expect(isWslEnvironment('6.6.0', null, '/run/WSL/1_interop'), true);
    });

    test('detects WSL from os release', () {
      expect(
        isWslEnvironment('6.6.87.2-microsoft-standard-WSL2', null, null),
        true,
      );
    });
  });

  group('resolvePlatformValue', () {
    test('returns platform-specific path when available', () {
      const localPath = PlatformStringValue(
        defaultValue: '~/.config/app',
        linux: r'$XDG_CONFIG_HOME/app',
        mac: '~/Library/Application Support/app',
        win: '%LOCALAPPDATA%/app',
      );

      expect(resolvePlatformValue(localPath, 'linux'), r'$XDG_CONFIG_HOME/app');
      expect(
        resolvePlatformValue(localPath, 'mac'),
        '~/Library/Application Support/app',
      );
      expect(resolvePlatformValue(localPath, 'win'), '%LOCALAPPDATA%/app');
    });

    test('falls back to default when platform key is absent', () {
      const localPath = PlatformStringValue(
        defaultValue: '~/.config/app',
        linux: r'$XDG_CONFIG_HOME/app',
      );

      expect(resolvePlatformValue(localPath, 'win'), '~/.config/app');
      expect(resolvePlatformValue(localPath, 'mac'), '~/.config/app');
    });

    test('returns default when only default is specified', () {
      const localPath = PlatformStringValue(defaultValue: '~/.config/app');

      expect(resolvePlatformValue(localPath, 'linux'), '~/.config/app');
      expect(resolvePlatformValue(localPath, 'win'), '~/.config/app');
    });

    test('prefers wsl and falls back to linux on WSL', () {
      expect(
        resolvePlatformValue(
          const PlatformStringValue(
            defaultValue: '~/.config/app',
            linux: r'$XDG_CONFIG_HOME/app-linux',
            wsl: r'$XDG_CONFIG_HOME/app-wsl',
          ),
          'wsl',
        ),
        r'$XDG_CONFIG_HOME/app-wsl',
      );

      expect(
        resolvePlatformValue(
          const PlatformStringValue(
            defaultValue: '~/.config/app',
            linux: r'$XDG_CONFIG_HOME/app-linux',
          ),
          'wsl',
        ),
        r'$XDG_CONFIG_HOME/app-linux',
      );
    });

    test('resolves repo paths the same way as local paths', () {
      const repoPath = PlatformStringValue(
        defaultValue: '.config/app/config.json',
        linux: '.config/app/config.linux.json',
        mac: 'Library/Application Support/app/config.json',
        win: 'AppData/Local/app/config.json',
      );

      expect(
        resolvePlatformValue(repoPath, 'linux'),
        '.config/app/config.linux.json',
      );
      expect(
        resolvePlatformValue(repoPath, 'mac'),
        'Library/Application Support/app/config.json',
      );
      expect(
        resolvePlatformValue(repoPath, 'win'),
        'AppData/Local/app/config.json',
      );
    });

    test('prefers wsl and falls back to linux for repo paths on WSL', () {
      expect(
        resolvePlatformValue(
          const PlatformStringValue(
            defaultValue: '.gnupg/gpg-agent.conf',
            linux: '.gnupg/gpg-agent.linux.conf',
            wsl: '.gnupg/gpg-agent.wsl.conf',
          ),
          'wsl',
        ),
        '.gnupg/gpg-agent.wsl.conf',
      );

      expect(
        resolvePlatformValue(
          const PlatformStringValue(
            defaultValue: '.gnupg/gpg-agent.conf',
            linux: '.gnupg/gpg-agent.linux.conf',
          ),
          'wsl',
        ),
        '.gnupg/gpg-agent.linux.conf',
      );
    });
  });
}
