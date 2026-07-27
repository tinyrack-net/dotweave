// Dart port of `packages/cli/src/cli/status.ts`.

import 'package:cliweave/cliweave.dart';
import 'package:cliweave/terminal.dart';
import 'package:dotweave/src/cli/command_logger.dart';
import 'package:dotweave/src/cli/shared_flags.dart';
import 'package:dotweave/src/config/constants.dart';
import 'package:dotweave/src/services/status.dart';

const int _maxDisplayItems = 10;

void _logPushChanges(CliLogger logger, PushChanges changes) {
  final hasChanges =
      changes.added.isNotEmpty ||
      changes.modified.isNotEmpty ||
      changes.deleted.isNotEmpty;

  if (!hasChanges) {
    logger.log('  No push changes');
    return;
  }

  if (changes.added.isNotEmpty) {
    logger.section('Add (${changes.added.length})');
    final displayItems = changes.added.take(_maxDisplayItems).toList();
    final remainingCount = changes.added.length - displayItems.length;

    for (final path in displayItems) {
      logger.log('  ${color.action.add(SYMBOLS.add)} ${color.path(path)}');
    }

    if (remainingCount > 0) {
      logger.log(color.dim('  ... and $remainingCount more'));
    }
  }

  if (changes.modified.isNotEmpty) {
    logger.section('Modify (${changes.modified.length})');
    final displayItems = changes.modified.take(_maxDisplayItems).toList();
    final remainingCount = changes.modified.length - displayItems.length;

    for (final path in displayItems) {
      logger.log(
        '  ${color.action.modify(SYMBOLS.modify)} ${color.path(path)}',
      );
    }

    if (remainingCount > 0) {
      logger.log(color.dim('  ... and $remainingCount more'));
    }
  }

  if (changes.deleted.isNotEmpty) {
    logger.section('Delete (${changes.deleted.length})');
    final displayItems = changes.deleted.take(_maxDisplayItems).toList();
    final remainingCount = changes.deleted.length - displayItems.length;

    for (final path in displayItems) {
      logger.log(
        '  ${color.action.delete(SYMBOLS.delete)} ${color.path(path)}',
      );
    }

    if (remainingCount > 0) {
      logger.log(color.dim('  ... and $remainingCount more'));
    }
  }
}

void _logPullChanges(CliLogger logger, PullChanges changes) {
  final hasChanges = changes.updated.isNotEmpty || changes.deleted.isNotEmpty;

  if (!hasChanges) {
    logger.log('  No pull changes');
    return;
  }

  if (changes.updated.isNotEmpty) {
    logger.section('Changed (${changes.updated.length})');
    final displayItems = changes.updated.take(_maxDisplayItems).toList();
    final remainingCount = changes.updated.length - displayItems.length;

    for (final path in displayItems) {
      logger.log('  ${color.action.add(SYMBOLS.add)} ${color.path(path)}');
    }

    if (remainingCount > 0) {
      logger.log(color.dim('  ... and $remainingCount more'));
    }
  }

  if (changes.deleted.isNotEmpty) {
    logger.section('Remove (${changes.deleted.length})');
    final displayItems = changes.deleted.take(_maxDisplayItems).toList();
    final remainingCount = changes.deleted.length - displayItems.length;

    for (final path in displayItems) {
      logger.log(
        '  ${color.action.delete(SYMBOLS.delete)} ${color.path(path)}',
      );
    }

    if (remainingCount > 0) {
      logger.log(color.dim('  ... and $remainingCount more'));
    }
  }
}

final Command statusCommand = buildCommand(
  docs: const CommandDocs(
    brief: 'Show planned push and pull changes for the current sync config',
    fullDescription:
        'Compare the tracked local files with the sync directory and report what push would write to the repository and what pull would write back locally.',
  ),
  func: (context, flags, positional) async {
    final logger = loggerFor(context);

    final spin = logger.spinner('Checking sync status...');
    StatusResult result;

    try {
      result = await getStatus(profile: flags['profile'] as String?);
    } catch (error) {
      spin.stop();
      rethrow;
    }

    spin.stop();

    logger.info(
      'Sync status — ${result.entryCount} entries, ${result.recipientCount} recipients, profile: ${result.activeProfile ?? AppConstants.sync.defaultProfile}',
    );

    logger.section('Push changes (repository)');
    _logPushChanges(logger, result.push.changes);

    logger.section('Pull changes (local)');
    _logPullChanges(logger, result.pull.changes);
    return null;
  },
  parameters: const CommandParameters(flags: {'profile': profileFlag}),
);
