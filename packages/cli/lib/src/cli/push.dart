// Dart port of `packages/cli/src/cli/push.ts`.

import 'package:dotweave/src/cli/command_logger.dart';
import 'package:dotweave/src/cli/shared_flags.dart';
import 'package:dotweave/src/services/push.dart';
import 'package:tinyrack_cli/tinyrack_cli.dart';

final Command pushCommand = buildCommand(
  docs: const CommandDocs(
    brief: 'Mirror local config into the git-backed sync directory',
    fullDescription:
        'Collect the current state of tracked local files and directories, then update the sync directory artifacts to match. Secret targets are encrypted before they are written into the repository.',
  ),
  func: (context, flags, positional) async {
    final logger = loggerFor(context);

    final spin = logger.spinner('Pushing changes...');

    PushResult result;

    try {
      result = await pushChanges(
        PushRequest(
          dryRun: flags['dryRun'] as bool? ?? false,
          profile: flags['profile'] as String?,
        ),
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
    return null;
  },
  parameters: const CommandParameters(
    flags: {
      'dryRun': BooleanFlag(
        brief: 'Preview repository updates only',
        optional: true,
      ),
      'profile': profileFlag,
    },
  ),
);
