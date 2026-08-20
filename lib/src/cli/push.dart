// Dart port of `src/cli/push.ts`.

import 'package:cliweave/cliweave.dart';
import 'package:dotweave/src/cli/command_logger.dart';
import 'package:dotweave/src/cli/shared_flags.dart';
import 'package:dotweave/src/services/push.dart';
import 'package:dotweave/src/util/error.dart';

String? _normalizeCommitMessage(String? value) {
  if (value == null) return null;
  final message = value.trim();
  if (message.isEmpty) {
    throw DotweaveError(
      'Commit message cannot be empty.',
      code: 'INVALID_COMMIT_MESSAGE',
      hint: 'Pass a non-empty value to --message.',
    );
  }
  return message;
}

final Command<ApplicationContext> pushCommand = buildCommand(
  docs: const CommandDocs(
    brief: 'Mirror local config into the git-backed sync directory',
    fullDescription:
        'Collect the current state of tracked local files and directories, then update the sync directory artifacts to match. Secret targets are encrypted before they are written into the repository. Pass --with-git to also commit the updated artifacts and push them to the configured git remote (customize the commit message with -m).',
  ),
  func: (context, flags, args) async {
    final logger = loggerFor(context);
    final defaults = (await loadSyncCommandDefaults())?.push;
    final dryRun = flags.dryRun ?? defaults?.dryRun ?? false;
    final profile = flags.profile ?? defaults?.profile;
    final withGit = flags.withGit ?? defaults?.withGit ?? false;
    final message = _normalizeCommitMessage(flags.message ?? defaults?.message);
    final request = PushRequest(
      dryRun: dryRun,
      profile: profile,
      withGit: withGit,
      commitMessage: message,
    );

    PushResult result;

    if (withGit && !dryRun) {
      // Skip the spinner so git owns the terminal for interactive auth: the
      // commit/push run inside pushChanges may prompt for credentials.
      logger.info('Pushing changes...');
      result = await pushChanges(request);
      logger.info('Synced to git remote');
    } else {
      final spin = logger.spinner('Pushing changes...');

      try {
        result = await pushChanges(request);
      } catch (error) {
        spin.stop();
        rethrow;
      }

      if (result.dryRun) {
        spin.stop();
        logger.info('Push preview (dry run)');
      } else {
        spin.succeed('Push complete');
      }
    }

    logger.kv('plain', '${result.plainFileCount}');
    logger.kv('encrypted', '${result.encryptedFileCount}');
    logger.kv('symlinks', '${result.symlinkCount}');
    logger.kv('dirs', '${result.directoryCount}');

    final removalAction = result.dryRun ? 'would be removed' : 'removed';
    logger.log(
      '  ${result.deletedArtifactCount} stale artifacts $removalAction',
    );

    for (final repoPath in result.nonPortableSymlinkTargets) {
      logger.warn(
        'Symlink target points outside your home directory and will not '
        'resolve on another machine: $repoPath',
      );
    }
  },
  parameters: CommandParameters(
    flags:
        FlagSet.one(
              BooleanFlag.optional<ApplicationContext>(
                name: 'dryRun',
                brief: 'Preview repository updates only',
              ),
            )
            .and(profileFlag)
            .and(
              BooleanFlag.optional<ApplicationContext>(
                name: 'withGit',
                brief: 'Also commit and push to the git remote',
              ),
            )
            .and(
              ParsedFlag.optional<String, ApplicationContext>(
                name: 'message',
                brief: 'Commit message for the git sync commit',
                parse: stringParser,
                placeholder: 'message',
              ),
            )
            .map(
              (v) => (
                dryRun: v.$1.$1.$1,
                profile: v.$1.$1.$2,
                withGit: v.$1.$2,
                message: v.$2,
              ),
            ),
    positional: PositionalSet.none(),
    aliases: {'m': 'message'},
  ),
);
