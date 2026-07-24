// Dart port of `packages/cli/src/cli/track.ts`.
//
// The TS `normalizeFlagValues` helper defends against stricli handing a bare
// string for a variadic flag; the Dart router always yields `List<Object?>`
// for parsed variadic flags, so the helper reduces to a cast here.

import 'dart:io' as io;

import 'package:dotweave/src/cli/platform_flags.dart';
import 'package:dotweave/src/cli/router.dart';
import 'package:dotweave/src/config/constants.dart';
import 'package:dotweave/src/lib/error.dart';
import 'package:dotweave/src/services/profile.dart';
import 'package:dotweave/src/services/sync_mode.dart';
import 'package:dotweave/src/services/terminal/logger.dart';
import 'package:dotweave/src/services/terminal/path_completion.dart';
import 'package:dotweave/src/services/track.dart';

List<String>? _normalizeFlagValues(Object? values) {
  return (values as List<Object?>?)?.cast<String>();
}

final Command trackCommand = buildCommand(
  docs: const CommandDocs(
    brief: 'Track local files or directories for syncing',
    fullDescription:
        'Register a file or directory inside your home directory so dotweave can mirror it into the sync directory. If a target is already tracked, specified manifest fields are updated and unspecified fields are preserved.',
  ),
  func: (context, flags, positional) async {
    final logger = createCliLogger();
    final profiles = [...?_normalizeFlagValues(flags['profile'])];
    final cwd = io.Directory.current.path;
    final targets = positional.cast<String>();

    if (flags['repo'] != null && targets.length != 1) {
      throw DotweaveError(
        'The --repo flag can only be used with a single sync target.',
        code: 'REPO_PATH_TARGET_COUNT',
        hint: 'Track one target at a time when overriding its repository path.',
      );
    }

    final mode = parsePlatformModeFlags(
      'mode',
      _normalizeFlagValues(flags['mode']),
    );
    final fallbackMode = mode?.defaultValue ?? AppConstants.sync.modes[0];
    final repoPath = parsePlatformStringFlags(
      'repo',
      _normalizeFlagValues(flags['repo']),
    );
    final localPathOverrides = parsePlatformStringOverrideFlags(
      'local',
      _normalizeFlagValues(flags['local']),
    );
    final permission = parsePlatformPermissionFlags(
      'permission',
      _normalizeFlagValues(flags['permission']),
    );

    for (final target in targets) {
      try {
        final result = await trackTarget(
          TrackRequest(
            kind: flags['kind'] as String?,
            localPathOverrides: localPathOverrides,
            mode: mode,
            permission: permission,
            profiles: profiles.isNotEmpty ? profiles : null,
            repoPath: repoPath,
            target: target,
          ),
          cwd,
        );

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
      } catch (error) {
        if (repoPath == null &&
            error is DotweaveError &&
            error.code == 'TARGET_NOT_FOUND') {
          final isProfileClear = profiles.length == 1 && profiles[0] == '';

          if (profiles.isNotEmpty && !isProfileClear) {
            await validateProfilesExist(profiles);
          }

          final setResult = await setTargetMode(
            SetModeRequest(mode: fallbackMode, target: target),
            cwd,
          );

          if (profiles.isNotEmpty) {
            await assignProfiles(
              AssignProfilesRequest(
                profiles: isProfileClear ? [] : profiles,
                target: target,
              ),
              cwd,
            );
          }

          if (setResult.action == 'unchanged') {
            logger.info('Sync mode unchanged for ${setResult.repoPath}');
          } else {
            logger.success('Updated sync mode for ${setResult.repoPath}');
          }

          logger.listKeyValue([(key: 'mode', value: setResult.mode)]);

          if (setResult.reason == 'already-set') {
            logger.log('  already ${setResult.mode}');
          }

          continue;
        }

        rethrow;
      }
    }
    return null;
  },
  parameters: const CommandParameters(
    flags: {
      'kind': EnumFlag(
        brief: 'Target kind to use when the path does not exist yet',
        optional: true,
        values: ['file', 'directory'],
      ),
      'mode': ParsedFlag(
        brief: 'Sync mode for the tracked targets',
        optional: true,
        parse: stringParser,
        placeholder: 'mode|platform=mode',
        variadic: true,
      ),
      'permission': ParsedFlag(
        brief: 'File permission to restore, as a 4-character octal value',
        optional: true,
        parse: stringParser,
        placeholder: 'octal|platform=octal',
        variadic: true,
      ),
      'profile': ParsedFlag(
        brief:
            "Restrict syncing to registered profiles (add non-default profiles with 'dotweave profile add')",
        optional: true,
        parse: stringParser,
        placeholder: 'profile',
        variadic: true,
      ),
      'local': ParsedFlag(
        brief: 'Platform-specific local path override',
        optional: true,
        parse: stringParser,
        placeholder: 'platform=path',
        variadic: true,
      ),
      'repo': ParsedFlag(
        brief: 'Repository-relative path under the profile namespace',
        optional: true,
        parse: stringParser,
        placeholder: 'path|platform=path',
        variadic: true,
      ),
    },
    positional: ArrayPositionalParameters(
      parameter: PositionalParameter(
        brief:
            'Local files or directories under your home directory to track, including cwd-relative paths or repository paths inside tracked directories',
        parse: stringParser,
        placeholder: 'target',
        proposeCompletions: proposePathCompletions,
      ),
      minimum: 1,
    ),
  ),
);
