// Dart port of `src/cli/push.ts`.

import 'package:cliweave/cliweave.dart';
import 'package:dotweave/src/cli/command_logger.dart';
import 'package:dotweave/src/cli/shared_flags.dart';
import 'package:dotweave/src/services/push.dart';

final Command<ApplicationContext> pushCommand = buildCommand(
  docs: const CommandDocs(
    brief: 'Mirror local config into the git-backed sync directory',
    fullDescription:
        'Collect the current state of tracked local files and directories, then update the sync directory artifacts to match. Secret targets are encrypted before they are written into the repository.',
  ),
  func: (context, flags, args) async {
    final logger = loggerFor(context);

    final spin = logger.spinner('Pushing changes...');

    PushResult result;

    try {
      result = await pushChanges(
        PushRequest(dryRun: flags.dryRun ?? false, profile: flags.profile),
      );
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

    logger.kv('plain', '${result.plainFileCount}');
    logger.kv('encrypted', '${result.encryptedFileCount}');
    logger.kv('symlinks', '${result.symlinkCount}');
    logger.kv('dirs', '${result.directoryCount}');

    final removalAction = result.dryRun ? 'would be removed' : 'removed';
    logger.log(
      '  ${result.deletedArtifactCount} stale artifacts $removalAction',
    );
  },
  parameters: CommandParameters(
    flags: FlagSet.one(
      BooleanFlag.optional<ApplicationContext>(
        name: 'dryRun',
        brief: 'Preview repository updates only',
      ),
    ).and(profileFlag).map((v) => (dryRun: v.$1, profile: v.$2)),
    positional: PositionalSet.none(),
  ),
);
