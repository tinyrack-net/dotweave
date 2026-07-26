// Dart port of `packages/cli/src/cli/init.ts`.

import 'package:dotweave/src/cli/command_logger.dart';
import 'package:dotweave/src/cli/router.dart';
import 'package:dotweave/src/services/init.dart';
import 'package:dotweave/src/util/prompt.dart';

String _formatGitSummary(InitResult result) {
  switch (result.gitAction) {
    case 'cloned':
      return 'cloned from ${result.gitSource}';
    case 'initialized':
      return 'initialized new repository';
    default:
      return 'using existing repository';
  }
}

String _formatAgeSummary(InitResult result) {
  return result.generatedIdentity
      ? 'generated a new local identity'
      : 'using existing identity';
}

final Command initCommand = buildCommand(
  docs: const CommandDocs(
    brief: 'Initialize the git-backed sync directory',
    fullDescription:
        'Create or connect the local dotweave repository under your dotweave app-data directory, then store the sync settings used by later pull and push operations. If local sync repository data already exists, init fails unless --force is provided. If you omit the repository argument, dotweave initializes a local git repository in the sync directory.',
  ),
  func: (context, flags, positional) async {
    final logger = loggerFor(context);
    final force = flags['force'] as bool? ?? false;
    final repository = positional[0] as String?;

    final plan = await planAgeIdentity(
      keyFile: flags['keyFile'] as String?,
      repository: repository,
      force: force,
    );
    final promptAnswer = plan.shouldPrompt
        ? await ask(
            plan.importingRepository
                ? 'Enter the age private key for the existing repository: '
                : 'Enter an age private key (leave empty to generate a new one): ',
          )
        : null;
    final identity = resolveAgeIdentity(plan, promptAnswer);
    final importingRepository = plan.importingRepository;

    final spin = logger.spinner(
      importingRepository
          ? 'Cloning repository...'
          : 'Initializing sync directory...',
    );

    InitResult result;

    try {
      result = await initializeSyncDirectory(
        InitRequest(
          ageIdentity: identity.ageIdentity,
          force: force,
          generateAgeIdentity: identity.generateAgeIdentity,
          recipients: const [],
          repository: repository,
        ),
      );
    } catch (error) {
      spin.stop();
      rethrow;
    }

    if (result.alreadyInitialized) {
      spin.stop();
      logger.info('Sync directory already initialized');
    } else {
      spin.succeed('Sync directory initialized');
    }

    logger.kv('git', _formatGitSummary(result));
    logger.kv('age', _formatAgeSummary(result));
    logger.log(
      '  ${result.entryCount} entries · ${result.recipientCount} recipients',
    );
    return null;
  },
  parameters: const CommandParameters(
    flags: {
      'force': BooleanFlag(
        brief:
            'Replace existing local sync repository, identity, and settings before initializing',
        optional: true,
      ),
      'keyFile': ParsedFlag(
        brief: 'Read an age private key from a file',
        optional: true,
        parse: stringParser,
        placeholder: 'path',
      ),
    },
    positional: TuplePositionalParameters([
      PositionalParameter(
        brief: 'Remote URL or local git repository path to clone',
        optional: true,
        parse: stringParser,
        placeholder: 'repository',
      ),
    ]),
  ),
);
