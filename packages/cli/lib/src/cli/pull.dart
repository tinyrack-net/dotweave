// Dart port of `packages/cli/src/cli/pull.ts`.

import 'dart:io' as io;

import 'package:dotweave/src/cli/command_logger.dart';
import 'package:dotweave/src/cli/router.dart';
import 'package:dotweave/src/cli/shared_flags.dart';
import 'package:dotweave/src/services/pull.dart';
import 'package:dotweave/src/terminal/logger.dart';
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

final Command pullCommand = buildCommand(
  docs: const CommandDocs(
    brief: 'Apply the git-backed sync directory to local config paths',
    fullDescription:
        'Read tracked artifacts from the sync directory and materialize them back onto local paths under your home directory. Secret artifacts are decrypted with the configured age identity before they are written locally.',
  ),
  func: (context, flags, positional) async {
    final dryRun = flags['dryRun'] as bool? ?? false;
    final logger = loggerFor(context);

    final spin = logger.spinner('Preparing pull...');
    PreparedPull prepared;

    try {
      prepared = await preparePull(
        PullRequest(dryRun: dryRun, profile: flags['profile'] as String?),
      );
    } catch (error) {
      spin.stop();
      rethrow;
    }

    final config = prepared.config;
    final plan = prepared.plan;
    spin.stop();

    if (plan.updatedLocalPaths.isEmpty && plan.deletedLocalPaths.isEmpty) {
      logger.info('Already up to date');
      return null;
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
    } else if (flags['yes'] as bool? ?? false) {
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
        return null;
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
    return null;
  },
  parameters: const CommandParameters(
    flags: {
      'dryRun': BooleanFlag(
        brief: 'Preview local file updates only',
        optional: true,
      ),
      'profile': profileFlag,
      'yes': BooleanFlag(
        brief: 'Apply pull changes without prompting',
        optional: true,
        withNegated: false,
      ),
    },
    aliases: {'y': 'yes'},
  ),
);
