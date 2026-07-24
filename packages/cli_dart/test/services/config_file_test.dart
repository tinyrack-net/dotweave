import 'dart:io';

import 'package:dotweave/src/config/platform.dart';
import 'package:dotweave/src/config/sync_schema.dart';
import 'package:dotweave/src/lib/file_mode.dart';
import 'package:dotweave/src/services/config_file.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final temporaryDirectories = <String>[];

  Future<String> createTemporaryDirectory(String prefix) async {
    final directory = await Directory.systemTemp.createTemp(prefix);

    temporaryDirectories.add(directory.path);

    return directory.path;
  }

  tearDown(() async {
    while (temporaryDirectories.isNotEmpty) {
      final directory = temporaryDirectories.removeLast();

      if (await Directory(directory).exists()) {
        await Directory(directory).delete(recursive: true);
      }
    }
  });

  group('config-file', () {
    test('writes v8 directory entries', () {
      expect(
        buildSyncConfigDocument(
          const ResolvedSyncConfig(
            entries: [
              ResolvedSyncConfigEntry(
                configuredMode: PlatformSyncMode(defaultValue: 'normal'),
                configuredLocalPath: PlatformStringValue(
                  defaultValue: '~/.config/zsh',
                ),
                kind: 'directory',
                localPath: '/tmp/home/.config/zsh',
                profiles: [],
                profilesExplicit: false,
                mode: 'normal',
                modeExplicit: false,
                permissionExplicit: false,
                repoPath: '.config/zsh',
              ),
            ],
            profiles: [],
            version: 8,
          ),
        ).toJson(),
        equals({
          'entries': [
            {
              'kind': 'directory',
              'localPath': {'default': '~/.config/zsh'},
            },
          ],
          'profiles': <String>[],
          'version': 8,
        }),
      );
    });

    test('writes v8 file entries with mode and profiles', () {
      expect(
        buildSyncConfigDocument(
          const ResolvedSyncConfig(
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
            version: 8,
          ),
        ).toJson(),
        equals({
          'entries': [
            {
              'kind': 'file',
              'localPath': {'default': '~/.gitconfig'},
              'profiles': ['default', 'work'],
              'mode': {'default': 'secret'},
            },
          ],
          'profiles': ['work'],
          'version': 8,
        }),
      );
    });

    test('omits mode and profiles when not explicit', () {
      expect(
        buildSyncConfigDocument(
          const ResolvedSyncConfig(
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
            profiles: [],
            version: 8,
          ),
        ).toJson(),
        equals({
          'entries': [
            {
              'kind': 'file',
              'localPath': {'default': '~/.bashrc'},
            },
          ],
          'profiles': <String>[],
          'version': 8,
        }),
      );
    });

    test('writes explicit permissions unchanged', () {
      expect(
        buildSyncConfigDocument(
          ResolvedSyncConfig(
            entries: [
              ResolvedSyncConfigEntry(
                configuredMode: const PlatformSyncMode(defaultValue: 'normal'),
                configuredLocalPath: const PlatformStringValue(
                  defaultValue: '~/.ssh/id_rsa',
                ),
                configuredPermission: const PlatformPermission(
                  defaultValue: '0600',
                  linux: '0400',
                ),
                kind: 'file',
                localPath: '/tmp/home/.ssh/id_rsa',
                profiles: const [],
                profilesExplicit: false,
                mode: 'normal',
                modeExplicit: false,
                permission: parsePermissionOctal('0600'),
                permissionExplicit: true,
                repoPath: '.ssh/id_rsa',
              ),
            ],
            profiles: const [],
            version: 8,
          ),
        ).toJson(),
        equals({
          'entries': [
            {
              'kind': 'file',
              'localPath': {'default': '~/.ssh/id_rsa'},
              'permission': {'default': '0600', 'linux': '0400'},
            },
          ],
          'profiles': <String>[],
          'version': 8,
        }),
      );
    });

    test('sorts entries by default path', () {
      final sorted = sortSyncConfigEntries(const [
        SyncConfigEntry(
          kind: 'file',
          localPath: PlatformStringValue(defaultValue: '~/.zshrc'),
        ),
        SyncConfigEntry(
          kind: 'directory',
          localPath: PlatformStringValue(
            defaultValue: '~/.config/app',
            linux: r'$XDG_CONFIG_HOME/app',
          ),
        ),
        SyncConfigEntry(
          kind: 'file',
          localPath: PlatformStringValue(defaultValue: '~/.bashrc'),
        ),
      ]);

      expect(
        sorted.map((e) => e.localPath).toList(),
        equals(const [
          PlatformStringValue(defaultValue: '~/.bashrc'),
          PlatformStringValue(
            defaultValue: '~/.config/app',
            linux: r'$XDG_CONFIG_HOME/app',
          ),
          PlatformStringValue(defaultValue: '~/.zshrc'),
        ]),
      );
    });

    test('writes explicit mode even when normal', () {
      expect(
        buildSyncConfigDocument(
          const ResolvedSyncConfig(
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
                modeExplicit: true,
                permissionExplicit: false,
                repoPath: '.bashrc',
              ),
            ],
            profiles: [],
            version: 8,
          ),
        ).toJson(),
        equals({
          'entries': [
            {
              'kind': 'file',
              'localPath': {'default': '~/.bashrc'},
              'mode': {'default': 'normal'},
            },
          ],
          'profiles': <String>[],
          'version': 8,
        }),
      );
    });

    test('writes explicit platform-aware modes unchanged', () {
      expect(
        buildSyncConfigDocument(
          const ResolvedSyncConfig(
            entries: [
              ResolvedSyncConfigEntry(
                configuredMode: PlatformSyncMode(
                  defaultValue: 'normal',
                  linux: 'ignore',
                  mac: 'secret',
                  win: 'ignore',
                  wsl: 'secret',
                ),
                configuredLocalPath: PlatformStringValue(
                  defaultValue: '~/.gitconfig',
                  linux: '~/.config/git/config',
                  wsl: '~/.config/git/config-wsl',
                ),
                kind: 'file',
                localPath: '/tmp/home/.gitconfig',
                profiles: [],
                profilesExplicit: false,
                mode: 'normal',
                modeExplicit: true,
                permissionExplicit: false,
                repoPath: '.gitconfig',
              ),
            ],
            profiles: [],
            version: 8,
          ),
        ).toJson(),
        equals({
          'entries': [
            {
              'kind': 'file',
              'localPath': {
                'default': '~/.gitconfig',
                'linux': '~/.config/git/config',
                'wsl': '~/.config/git/config-wsl',
              },
              'mode': {
                'default': 'normal',
                'linux': 'ignore',
                'mac': 'secret',
                'win': 'ignore',
                'wsl': 'secret',
              },
            },
          ],
          'profiles': <String>[],
          'version': 8,
        }),
      );
    });

    test('writes explicit platform-aware repo paths unchanged', () {
      expect(
        buildSyncConfigDocument(
          const ResolvedSyncConfig(
            entries: [
              ResolvedSyncConfigEntry(
                configuredMode: PlatformSyncMode(defaultValue: 'normal'),
                configuredLocalPath: PlatformStringValue(
                  defaultValue: '~/.gnupg/gpg-agent.conf',
                ),
                configuredRepoPath: PlatformStringValue(
                  defaultValue: '.gnupg/gpg-agent.conf',
                  linux: '.gnupg/gpg-agent.linux.conf',
                  wsl: '.gnupg/gpg-agent.wsl.conf',
                ),
                kind: 'file',
                localPath: '/tmp/home/.gnupg/gpg-agent.conf',
                profiles: [],
                profilesExplicit: false,
                mode: 'normal',
                modeExplicit: false,
                permissionExplicit: false,
                repoPath: '.gnupg/gpg-agent.linux.conf',
              ),
            ],
            profiles: [],
            version: 8,
          ),
        ).toJson(),
        equals({
          'entries': [
            {
              'kind': 'file',
              'localPath': {'default': '~/.gnupg/gpg-agent.conf'},
              'repoPath': {
                'default': '.gnupg/gpg-agent.conf',
                'linux': '.gnupg/gpg-agent.linux.conf',
                'wsl': '.gnupg/gpg-agent.wsl.conf',
              },
            },
          ],
          'profiles': <String>[],
          'version': 8,
        }),
      );
    });

    test('rejects top-level default profile without writing', () async {
      final syncDirectory = await createTemporaryDirectory(
        'dotweave-config-file-',
      );
      final manifestPath = p.join(syncDirectory, 'manifest.jsonc');

      await expectLater(
        writeValidatedSyncConfig(
          syncDirectory,
          const RawSyncConfig(version: 8, profiles: ['default'], entries: []),
        ),
        throwsA(predicate((error) => error.toString().contains('default'))),
      );
      await expectLater(File(manifestPath).readAsString(), throwsA(anything));
    });

    test(
      'rejects duplicate normalized profile registry values without writing',
      () async {
        final syncDirectory = await createTemporaryDirectory(
          'dotweave-config-file-',
        );
        final manifestPath = p.join(syncDirectory, 'manifest.jsonc');

        await expectLater(
          writeValidatedSyncConfig(
            syncDirectory,
            const RawSyncConfig(
              version: 8,
              profiles: ['work', ' work '],
              entries: [],
            ),
          ),
          throwsA(
            predicate(
              (error) => error.toString().contains('Duplicate profile'),
            ),
          ),
        );
        await expectLater(File(manifestPath).readAsString(), throwsA(anything));
      },
    );

    test('rejects unknown entry profile references without writing', () async {
      final syncDirectory = await createTemporaryDirectory(
        'dotweave-config-file-',
      );
      final manifestPath = p.join(syncDirectory, 'manifest.jsonc');

      await expectLater(
        writeValidatedSyncConfig(
          syncDirectory,
          const RawSyncConfig(
            version: 8,
            profiles: ['work'],
            entries: [
              SyncConfigEntry(
                kind: 'file',
                localPath: PlatformStringValue(defaultValue: '~/.gitconfig'),
                profiles: ['ghost'],
              ),
            ],
          ),
        ),
        throwsA(
          predicate(
            (error) => error.toString().contains("Unknown profile 'ghost'"),
          ),
        ),
      );
      await expectLater(File(manifestPath).readAsString(), throwsA(anything));
    });
  });
}
