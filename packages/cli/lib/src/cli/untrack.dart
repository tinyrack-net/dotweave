// Dart port of `packages/cli/src/cli/untrack.ts`.

import 'dart:io' as io;

import 'package:cliweave/cliweave.dart';
import 'package:dotweave/src/cli/command_logger.dart';
import 'package:dotweave/src/services/untrack.dart';

final Command untrackCommand = buildCommand(
  docs: const CommandDocs(
    brief: 'Stop tracking a synced path',
    fullDescription:
        'Remove a tracked root entry or a nested override from dotweave configuration. This only updates the sync config; actual file changes happen on the next push or pull. Use a local path to remove the main tracked target, or use a repository-relative child path inside a tracked directory to remove only that override.',
  ),
  func: (context, flags, positional) async {
    final logger = loggerFor(context);

    final target = positional[0] as String;
    final result = await untrackTarget(
      UntrackRequest(target: target),
      io.Directory.current.path,
    );

    logger.success('Stopped tracking ${result.repoPath}');
    logger.kv('plain', '${result.plainArtifactCount}');
    logger.kv('secret', '${result.secretArtifactCount}');
    return null;
  },
  parameters: const CommandParameters(
    flags: {},
    positional: TuplePositionalParameters([
      PositionalParameter(
        brief:
            'Tracked local path (including cwd-relative) or repository path to stop tracking',
        parse: stringParser,
        placeholder: 'target',
      ),
    ]),
  ),
);
