// Dart port of `packages/cli/src/cli/init.ts`.

import 'dart:io' as io;

import 'package:dotweave/src/cli/router.dart';
import 'package:dotweave/src/config/identity_file.dart';
import 'package:dotweave/src/config/runtime_env.dart';
import 'package:dotweave/src/lib/filesystem.dart';
import 'package:dotweave/src/lib/prompt.dart';
import 'package:dotweave/src/services/init.dart';
import 'package:dotweave/src/services/terminal/logger.dart';

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
    final logger = createCliLogger();
    final keyFile = flags['keyFile'] as String?;
    final keyFileContents = keyFile == null
        ? null
        : await io.File(keyFile).readAsString();
    final trimmedKeyFileContents = keyFileContents?.trim();
    final requestedKey =
        trimmedKeyFileContents == null || trimmedKeyFileContents.isEmpty
        ? null
        : trimmedKeyFileContents;
    final keyFileProvided = keyFile != null;
    final identityFile = resolveDefaultIdentityFile(
      resolveDotweaveHomeDirectoryFromEnv(),
    );
    final identityFileExists = await pathExists(identityFile);
    final force = flags['force'] as bool? ?? false;
    final effectiveIdentityFileExists = force ? false : identityFileExists;
    final repository = positional[0] as String?;
    final importingRepository =
        repository != null && repository.trim().isNotEmpty;
    final shouldPrompt =
        requestedKey == null &&
        !keyFileProvided &&
        !effectiveIdentityFileExists &&
        importingRepository;
    final promptedKey = shouldPrompt
        ? await ask(
            importingRepository
                ? 'Enter the age private key for the existing repository: '
                : 'Enter an age private key (leave empty to generate a new one): ',
          )
        : null;
    final trimmedPromptedKey = promptedKey?.trim();
    if (importingRepository &&
        requestedKey == null &&
        trimmedPromptedKey == '') {
      throw createMissingRepositoryAgeKeyError();
    }

    final spin = logger.spinner(
      importingRepository
          ? 'Cloning repository...'
          : 'Initializing sync directory...',
    );

    InitResult result;

    try {
      result = await initializeSyncDirectory(
        InitRequest(
          ageIdentity:
              requestedKey ??
              (trimmedPromptedKey != null && trimmedPromptedKey != ''
                  ? trimmedPromptedKey
                  : null),
          force: force,
          generateAgeIdentity:
              !importingRepository &&
              requestedKey == null &&
              (trimmedPromptedKey == '' ||
                  (trimmedPromptedKey == null && !effectiveIdentityFileExists)),
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
