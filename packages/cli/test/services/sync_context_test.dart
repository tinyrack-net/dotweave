import 'package:dotweave/src/config/global_config.dart';
import 'package:dotweave/src/config/platform.dart';
import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/services/sync_context.dart';
import 'package:dotweave/src/util/error.dart';
import 'package:test/test.dart';

const RuntimeAgeConfig testAge = RuntimeAgeConfig(
  identityFile: '/tmp/keys.txt',
  recipients: ['age1example'],
);

ResolvedSyncConfigEntry createEntry(
  String repoPath, [
  List<String> profiles = const [],
]) {
  return ResolvedSyncConfigEntry(
    configuredMode: const PlatformSyncMode(defaultValue: 'normal'),
    configuredLocalPath: PlatformStringValue(defaultValue: '~/$repoPath'),
    kind: 'file',
    localPath: '/tmp/home/$repoPath',
    profiles: profiles,
    profilesExplicit: profiles.isNotEmpty,
    mode: 'normal',
    modeExplicit: false,
    permissionExplicit: false,
    repoPath: repoPath,
  );
}

void main() {
  group('sync runtime', () {
    test('attaches activeProfile from selection to the effective config', () {
      const config = ResolvedSyncConfig(
        entries: [
          ResolvedSyncConfigEntry(
            configuredMode: PlatformSyncMode(defaultValue: 'normal'),
            configuredLocalPath: PlatformStringValue(
              defaultValue: '~/.config/zsh',
            ),
            kind: 'directory',
            localPath: '/tmp/home/.config/zsh',
            profiles: ['default', 'work'],
            profilesExplicit: true,
            mode: 'normal',
            modeExplicit: false,
            permissionExplicit: false,
            repoPath: '.config/zsh',
          ),
        ],
        profiles: ['work'],
        version: 7,
      );

      final effective = buildEffectiveSyncConfig(
        config,
        const ActiveProfileSelection.single('work'),
        testAge,
      );

      expect(effective.activeProfile, 'work');
      expect(effective.age, equals(testAge));
      expect(effective.entries, hasLength(1));
      expect(effective.entries[0].mode, 'normal');
      expect(effective.entries[0].repoPath, '.config/zsh');
      expect(effective.entries[0].profiles, equals(['default', 'work']));
    });

    test('passes through all entries regardless of profile selection', () {
      const config = ResolvedSyncConfig(
        entries: [
          ResolvedSyncConfigEntry(
            configuredMode: PlatformSyncMode(defaultValue: 'secret'),
            configuredLocalPath: PlatformStringValue(
              defaultValue: '~/.gitconfig',
            ),
            kind: 'file',
            localPath: '/tmp/home/.gitconfig',
            profiles: ['default', 'work'],
            profilesExplicit: true,
            mode: 'secret',
            modeExplicit: true,
            permissionExplicit: false,
            repoPath: '.gitconfig',
          ),
        ],
        profiles: ['work'],
        version: 7,
      );

      expect(
        buildEffectiveSyncConfig(
          config,
          const ActiveProfileSelection.none(),
          testAge,
        ).entries,
        hasLength(1),
      );

      expect(
        buildEffectiveSyncConfig(
          config,
          const ActiveProfileSelection.single('work'),
          testAge,
        ).entries,
        hasLength(1),
      );
    });

    test(
      'filters entries by active profile when entries have explicit profiles',
      () {
        const config = ResolvedSyncConfig(
          entries: [
            ResolvedSyncConfigEntry(
              configuredMode: PlatformSyncMode(defaultValue: 'normal'),
              configuredLocalPath: PlatformStringValue(
                defaultValue: '~/.config/work-app',
              ),
              kind: 'directory',
              localPath: '/tmp/home/.config/work-app',
              profiles: ['work'],
              profilesExplicit: true,
              mode: 'normal',
              modeExplicit: false,
              permissionExplicit: false,
              repoPath: '.config/work-app',
            ),
            ResolvedSyncConfigEntry(
              configuredMode: PlatformSyncMode(defaultValue: 'normal'),
              configuredLocalPath: PlatformStringValue(
                defaultValue: '~/.config/personal-app',
              ),
              kind: 'directory',
              localPath: '/tmp/home/.config/personal-app',
              profiles: ['personal'],
              profilesExplicit: true,
              mode: 'normal',
              modeExplicit: false,
              permissionExplicit: false,
              repoPath: '.config/personal-app',
            ),
          ],
          profiles: ['work', 'personal'],
          version: 7,
        );

        final effective = buildEffectiveSyncConfig(
          config,
          const ActiveProfileSelection.single('work'),
          testAge,
        );

        expect(effective.entries, hasLength(1));
        expect(effective.entries[0].repoPath, '.config/work-app');
      },
    );

    test(
      'includes entries with empty profiles array regardless of profile',
      () {
        const config = ResolvedSyncConfig(
          entries: [
            ResolvedSyncConfigEntry(
              configuredMode: PlatformSyncMode(defaultValue: 'normal'),
              configuredLocalPath: PlatformStringValue(
                defaultValue: '~/.bashrc',
              ),
              kind: 'file',
              localPath: '/tmp/home/.bashrc',
              profiles: [],
              profilesExplicit: false,
              mode: 'normal',
              modeExplicit: false,
              permissionExplicit: false,
              repoPath: '.bashrc',
            ),
          ],
          profiles: ['work'],
          version: 7,
        );

        final effective = buildEffectiveSyncConfig(
          config,
          const ActiveProfileSelection.single('work'),
          testAge,
        );

        expect(effective.entries, hasLength(1));
        expect(effective.entries[0].repoPath, '.bashrc');
      },
    );

    test("sets activeProfile to undefined when selection mode is 'none'", () {
      const config = ResolvedSyncConfig(entries: [], profiles: [], version: 7);

      final effective = buildEffectiveSyncConfig(
        config,
        const ActiveProfileSelection.none(),
        testAge,
      );

      expect(effective.activeProfile, isNull);
    });

    test('propagates age config through to the effective config', () {
      const config = ResolvedSyncConfig(entries: [], profiles: [], version: 7);

      const customAge = RuntimeAgeConfig(
        identityFile: '/custom/identity',
        recipients: ['age1custom'],
      );

      final effective = buildEffectiveSyncConfig(
        config,
        const ActiveProfileSelection.none(),
        customAge,
      );

      expect(effective.age, equals(customAge));
    });

    test(
      'filters entries so only profile-matching or unprofiled entries remain',
      () {
        const config = ResolvedSyncConfig(
          entries: [
            ResolvedSyncConfigEntry(
              configuredMode: PlatformSyncMode(defaultValue: 'normal'),
              configuredLocalPath: PlatformStringValue(
                defaultValue: '~/.config/work-tool',
              ),
              kind: 'directory',
              localPath: '/tmp/home/.config/work-tool',
              profiles: ['work'],
              profilesExplicit: true,
              mode: 'normal',
              modeExplicit: false,
              permissionExplicit: false,
              repoPath: '.config/work-tool',
            ),
            ResolvedSyncConfigEntry(
              configuredMode: PlatformSyncMode(defaultValue: 'normal'),
              configuredLocalPath: PlatformStringValue(
                defaultValue: '~/.vimrc',
              ),
              kind: 'file',
              localPath: '/tmp/home/.vimrc',
              profiles: [],
              profilesExplicit: false,
              mode: 'normal',
              modeExplicit: false,
              permissionExplicit: false,
              repoPath: '.vimrc',
            ),
            ResolvedSyncConfigEntry(
              configuredMode: PlatformSyncMode(defaultValue: 'normal'),
              configuredLocalPath: PlatformStringValue(
                defaultValue: '~/.config/personal-tool',
              ),
              kind: 'directory',
              localPath: '/tmp/home/.config/personal-tool',
              profiles: ['personal'],
              profilesExplicit: true,
              mode: 'normal',
              modeExplicit: false,
              permissionExplicit: false,
              repoPath: '.config/personal-tool',
            ),
          ],
          profiles: ['work', 'personal'],
          version: 7,
        );

        final effective = buildEffectiveSyncConfig(
          config,
          const ActiveProfileSelection.single('work'),
          testAge,
        );

        expect(effective.entries, hasLength(2));
        expect(
          effective.entries.map((e) => e.repoPath).toList(),
          equals(['.config/work-tool', '.vimrc']),
        );
      },
    );

    test(
      'normalizes explicit runtime profile selections before validation',
      () {
        const config = ResolvedSyncConfig(
          entries: [
            ResolvedSyncConfigEntry(
              configuredMode: PlatformSyncMode(defaultValue: 'normal'),
              configuredLocalPath: PlatformStringValue(
                defaultValue: '~/.config/work-tool',
              ),
              kind: 'directory',
              localPath: '/tmp/home/.config/work-tool',
              profiles: ['Work'],
              profilesExplicit: true,
              mode: 'normal',
              modeExplicit: false,
              permissionExplicit: false,
              repoPath: '.config/work-tool',
            ),
          ],
          profiles: ['Work'],
          version: 7,
        );

        final effective = buildEffectiveSyncConfig(
          config,
          const ActiveProfileSelection.single(' Work '),
          testAge,
        );

        expect(effective.activeProfile, 'Work');
        expect(effective.entries, hasLength(1));
      },
    );

    test('rejects unknown runtime profile selections instead of silently '
        'dropping named entries', () {
      final config = ResolvedSyncConfig(
        entries: [
          createEntry('.vimrc'),
          createEntry('.config/work', ['work']),
        ],
        profiles: const ['work'],
        version: 7,
      );

      expect(
        () {
          buildEffectiveSyncConfig(
            config,
            const ActiveProfileSelection.single('personal'),
            testAge,
          );
        },
        throwsA(
          isA<DotweaveError>().having(
            (error) => error.message,
            'message',
            contains("Unknown profile 'personal'."),
          ),
        ),
      );
    });

    test(
      'treats explicit default profile selection like the default layer',
      () {
        final config = ResolvedSyncConfig(
          entries: [
            createEntry('.bashrc'),
            createEntry('.profile', ['default']),
            createEntry('.config/work', ['work']),
          ],
          profiles: const ['work'],
          version: 7,
        );

        final effective = buildEffectiveSyncConfig(
          config,
          const ActiveProfileSelection.single('default'),
          testAge,
        );

        expect(effective.activeProfile, 'default');
        expect(
          effective.entries.map((entry) => entry.repoPath).toList(),
          equals(['.bashrc', '.profile']),
        );
      },
    );
  });
}
