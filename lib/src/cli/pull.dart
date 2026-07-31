// Dart port of `src/cli/pull.ts`.

import 'dart:io' as io;

import 'package:cliweave/cliweave.dart';
import 'package:cliweave/terminal.dart';
import 'package:dotweave/src/cli/command_logger.dart';
import 'package:dotweave/src/cli/shared_flags.dart';
import 'package:dotweave/src/services/pull.dart';
import 'package:dotweave/src/util/error.dart';
import 'package:dotweave/src/util/prompt.dart';

void _logPullPlanChanges(
  CliLogger logger,
  List<String> updatedLocalPaths,
  List<String> deletedLocalPaths,
) {
  if (updatedLocalPaths.isNotEmpty) {
    logger.section('Update from repository (${updatedLocalPaths.length})');
    logger.list(updatedLocalPaths, bullet: '+');
  }

  if (deletedLocalPaths.isNotEmpty) {
    logger.section('Remove locally (${deletedLocalPaths.length})');
    logger.list(deletedLocalPaths, bullet: '-');
  }
}

final Command<ApplicationContext> pullCommand = buildCommand(
  docs: const CommandDocs(
    brief: 'Apply the git-backed sync directory to local config paths',
    fullDescription:
        'Read tracked artifacts from the sync directory and materialize them back onto local paths under your home directory. Secret artifacts are decrypted with the configured age identity before they are written locally. Pass --with-git to first pull the latest artifacts from the configured git remote.',
  ),
  func: (context, flags, args) async {
    final dryRun = flags.dryRun ?? false;
    final withGit = flags.withGit ?? false;
    final logger = loggerFor(context);

    final request = PullRequest(
      dryRun: dryRun,
      profile: flags.profile,
      withGit: withGit,
    );
    PreparedPull prepared;

    if (withGit && !dryRun) {
      // Skip the spinner so git owns the terminal for interactive auth: the
      // git pull run inside preparePull may prompt for credentials.
      logger.info('Pulling from remote...');
      prepared = await preparePull(request);
    } else {
      final spin = logger.spinner('Preparing pull...');

      try {
        prepared = await preparePull(request);
      } catch (error) {
        spin.stop();
        rethrow;
      }

      spin.stop();
    }

    final config = prepared.config;
    final plan = prepared.plan;

    if (plan.updatedLocalPaths.isEmpty && plan.deletedLocalPaths.isEmpty) {
      logger.info('Already up to date');
      return;
    }

    logger.info('Planned pull changes');
    _logPullPlanChanges(logger, plan.updatedLocalPaths, plan.deletedLocalPaths);

    // Applying under a spinner that must stop before an error propagates;
    // shared by the --yes path and the confirmed-prompt path below.
    Future<void> applyUnderSpinner() async {
      final applySpin = logger.spinner('Applying pull...');
      try {
        await applyPullPlan(config, plan);
      } catch (error) {
        applySpin.stop();
        rethrow;
      }
      applySpin.succeed('Pull complete');
    }

    if (dryRun) {
      logger.info('Pull preview (dry run)');
    } else if (flags.yes ?? false) {
      await applyUnderSpinner();
    } else {
      // Mirror of the TS `process.stdin.isTTY ?? false` check.
      if (!io.stdin.hasTerminal) {
        throw DotweaveError(
          'Pull confirmation requires an interactive terminal.',
          hint: "Re-run 'dotweave pull -y' to apply changes without a prompt.",
        );
      }

      final answer = await ask('Apply these changes? [y/N] ');

      if (answer.trim().toLowerCase() != 'y') {
        logger.info('Skipped pull changes');
        return;
      }

      await applyUnderSpinner();
    }

    final updateAction = dryRun ? 'would be updated' : 'updated';
    final removeAction = dryRun ? 'would be removed' : 'removed';

    logger.kv(
      'updated',
      '${plan.updatedLocalPaths.length} paths $updateAction',
    );
    logger.kv(
      'removed',
      '${plan.deletedLocalPaths.length} paths $removeAction',
    );
    return;
  },
  parameters: CommandParameters(
    flags:
        FlagSet.one(
              BooleanFlag.optional<ApplicationContext>(
                name: 'dryRun',
                brief: 'Preview local file updates only',
              ),
            )
            .and(profileFlag)
            .and(
              BooleanFlag.optional<ApplicationContext>(
                name: 'yes',
                brief: 'Apply pull changes without prompting',
                withNegated: false,
              ),
            )
            .and(
              BooleanFlag.optional<ApplicationContext>(
                name: 'withGit',
                brief: 'Also pull from the git remote before applying',
                withNegated: false,
              ),
            )
            .map(
              (v) => (
                dryRun: v.$1.$1.$1,
                profile: v.$1.$1.$2,
                yes: v.$1.$2,
                withGit: v.$2,
              ),
            ),
    positional: PositionalSet.none(),
    aliases: {'y': 'yes'},
  ),
);
