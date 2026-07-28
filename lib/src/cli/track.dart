// Dart port of `src/cli/track.ts`.
//
// Variadic flags decode to `List<String>` (empty when the flag is absent),
// which the platform-flag parsers treat the same as a null value.

import 'dart:io' as io;

import 'package:cliweave/cliweave.dart';
import 'package:dotweave/src/cli/command_logger.dart';
import 'package:dotweave/src/cli/platform_flags.dart';
import 'package:dotweave/src/config/constants.dart';
import 'package:dotweave/src/services/path_completion.dart';
import 'package:dotweave/src/services/track.dart';
import 'package:dotweave/src/util/error.dart';

final Command<ApplicationContext> trackCommand = buildCommand(
  docs: const CommandDocs(
    brief: 'Track local files or directories for syncing',
    fullDescription:
        'Register a file or directory inside your home directory so dotweave can mirror it into the sync directory. If a target is already tracked, specified manifest fields are updated and unspecified fields are preserved.',
  ),
  func: (context, flags, args) async {
    final logger = loggerFor(context);
    final profiles = [...flags.profile];
    final cwd = io.Directory.current.path;
    final targets = args;

    if (flags.repo.isNotEmpty && targets.length != 1) {
      throw DotweaveError(
        'The --repo flag can only be used with a single sync target.',
        code: 'REPO_PATH_TARGET_COUNT',
        hint: 'Track one target at a time when overriding its repository path.',
      );
    }

    final mode = parsePlatformModeFlags('mode', flags.mode);
    final fallbackMode = mode?.defaultValue ?? AppConstants.sync.modes[0];
    final repoPath = parsePlatformStringFlags('repo', flags.repo);
    final localPathOverrides = parsePlatformStringOverrideFlags(
      'local',
      flags.local,
    );
    final permission = parsePlatformPermissionFlags(
      'permission',
      flags.permission,
    );

    for (final target in targets) {
      final outcome = await trackOrSetMode(
        TrackRequest(
          kind: flags.kind,
          localPathOverrides: localPathOverrides,
          mode: mode,
          permission: permission,
          profiles: profiles.isNotEmpty ? profiles : null,
          repoPath: repoPath,
          target: target,
        ),
        cwd,
        fallbackMode: fallbackMode,
      );

      switch (outcome) {
        case TrackedOutcome(:final result):
          if (!result.alreadyTracked) {
            logger.success('Started tracking ${result.repoPath}');
          } else if (result.changed) {
            logger.success('Updated tracking for ${result.repoPath}');
          } else {
            logger.info('${result.repoPath} already tracked');
          }

          final details = <({String key, String? value})>[
            (key: 'kind', value: result.kind),
            (key: 'path', value: result.localPath),
            (key: 'repo', value: result.repoPath),
            (key: 'mode', value: result.mode),
          ];
          final configuredPermission = result.configuredPermission;
          if (configuredPermission != null) {
            details.add((
              key: 'permission',
              value: configuredPermission.defaultValue,
            ));
          }
          if (result.profiles.isNotEmpty) {
            details.add((key: 'profiles', value: result.profiles.join(', ')));
          }
          logger.listKeyValue(details);

        case ModeSetOutcome(:final result):
          if (result.action == 'unchanged') {
            logger.info('Sync mode unchanged for ${result.repoPath}');
          } else {
            logger.success('Updated sync mode for ${result.repoPath}');
          }

          logger.listKeyValue([(key: 'mode', value: result.mode)]);

          if (result.reason == 'already-set') {
            logger.log('  already ${result.mode}');
          }
      }
    }
  },
  parameters: CommandParameters(
    flags:
        FlagSet.one(
              EnumFlag.optional<String, ApplicationContext>(
                name: 'kind',
                brief: 'Target kind to use when the path does not exist yet',
                values: const {'file': 'file', 'directory': 'directory'},
              ),
            )
            .and(
              ParsedFlag.variadic<String, ApplicationContext>(
                name: 'mode',
                brief: 'Sync mode for the tracked targets',
                parse: stringParser,
                placeholder: 'mode|platform=mode',
              ),
            )
            .and(
              ParsedFlag.variadic<String, ApplicationContext>(
                name: 'permission',
                brief:
                    'File permission to restore, as a 4-character octal value',
                parse: stringParser,
                placeholder: 'octal|platform=octal',
              ),
            )
            .and(
              ParsedFlag.variadic<String, ApplicationContext>(
                name: 'profile',
                brief:
                    "Restrict syncing to registered profiles (add non-default profiles with 'dotweave profile add')",
                parse: stringParser,
                placeholder: 'profile',
              ),
            )
            .and(
              ParsedFlag.variadic<String, ApplicationContext>(
                name: 'local',
                brief: 'Platform-specific local path override',
                parse: stringParser,
                placeholder: 'platform=path',
              ),
            )
            .and(
              ParsedFlag.variadic<String, ApplicationContext>(
                name: 'repo',
                brief: 'Repository-relative path under the profile namespace',
                parse: stringParser,
                placeholder: 'path|platform=path',
              ),
            )
            .map((v) {
              final (((((kind, mode), permission), profile), local), repo) = v;
              return (
                kind: kind,
                mode: mode,
                permission: permission,
                profile: profile,
                local: local,
                repo: repo,
              );
            }),
    positional: PositionalSet.array(
      Positional.required<String, ApplicationContext>(
        brief:
            'Local files or directories under your home directory to track, including cwd-relative paths or repository paths inside tracked directories',
        parse: stringParser,
        placeholder: 'target',
        proposeCompletions: (context, partial) =>
            proposePathCompletions(partial),
      ),
      minimum: 1,
    ),
  ),
);
