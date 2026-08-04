import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shipworld/release.dart';
import 'package:shipworld/shipworld.dart';

/// The only release target this repository publishes.
const String targetName = 'dotweave';

/// Drives Shipworld's release commands from any worktree of this repository.
///
/// Shipworld refuses to prepare or finalize a target from anywhere but its
/// configured branch (`main` here), and git refuses to check that branch out
/// in more than one worktree at a time. Working from a feature worktree
/// therefore means hopping to whichever worktree holds `main`, and prepare
/// leaves a commit there that has to be moved onto a release branch and then
/// unwound — a sequence that is only ever enforced by remembering it.
///
/// These commands find that worktree and run the sequence.

typedef ReleaseLogger = void Function(String message);

void _defaultLog(String message) {
  stdout.writeln('[release] $message');
}

/// Path of the worktree that currently has [branch] checked out.
///
/// Throws when no worktree holds it, which is the case worth reporting
/// clearly: the caller has to check the branch out somewhere before a release
/// can proceed.
Future<String> locateBranchWorktree({
  required String repoRoot,
  required String branch,
  GitClient git = const IoGitClient(),
}) async {
  final listing = await git.run(const [
    'worktree',
    'list',
    '--porcelain',
  ], workingDirectory: repoRoot);

  String? current;
  for (final line in listing.split('\n')) {
    if (line.startsWith('worktree ')) {
      current = line.substring('worktree '.length);
    } else if (line == 'branch refs/heads/$branch' && current != null) {
      return current;
    }
  }

  throw ShipworldException(
    'No worktree has $branch checked out. Check it out in one worktree, '
    'then run this command again.',
    code: 'branch_worktree_missing',
  );
}

/// Fails unless [worktree] is clean and level with `<remote>/<branch>`.
///
/// Prepare writes a commit into this worktree, so anything already sitting
/// there would be swept into the release branch or destroyed by the reset
/// that follows.
Future<void> _requireReleasableWorktree({
  required String worktree,
  required String remote,
  required String branch,
  required GitClient git,
}) async {
  final status = await git.run(const [
    'status',
    '--porcelain',
  ], workingDirectory: worktree);

  if (status.isNotEmpty) {
    throw ShipworldException(
      'The $branch worktree at $worktree has uncommitted changes. Commit or '
      'stash them before releasing.',
      code: 'worktree_dirty',
    );
  }

  await git.run(['fetch', remote, branch], workingDirectory: worktree);

  final head = await git.run(const [
    'rev-parse',
    'HEAD',
  ], workingDirectory: worktree);
  final upstream = await git.run([
    'rev-parse',
    '$remote/$branch',
  ], workingDirectory: worktree);

  if (head != upstream) {
    throw ShipworldException(
      'The $branch worktree at $worktree is not level with $remote/$branch '
      '($head vs $upstream). Pull or reset it first.',
      code: 'worktree_behind',
    );
  }
}

/// Prepares a [bump] release and leaves it on a pushed release branch.
///
/// With [dryRun] the Shipworld command only reports what it would change and
/// nothing is pushed.
Future<void> prepareRelease({
  required String repoRoot,
  required String bump,
  bool dryRun = false,
  GitClient git = const IoGitClient(),
  ProcessExecutor executor = defaultProcessExecutor,
  ReleaseLogger log = _defaultLog,
}) async {
  final config = await loadShipworldConfig(p.join(repoRoot, 'shipworld.yaml'));
  final target = config.target(targetName);
  final branch = target.branch;
  final remote = config.remote;

  final worktree = await locateBranchWorktree(
    repoRoot: repoRoot,
    branch: branch,
    git: git,
  );
  log('$branch worktree: $worktree');

  await _requireReleasableWorktree(
    worktree: worktree,
    remote: remote,
    branch: branch,
    git: git,
  );

  log('Preparing $targetName ($bump)${dryRun ? ' [dry run]' : ''}');
  await runInherited(
    'dart',
    [
      'run',
      'shipworld:shipworld',
      'release',
      'prepare',
      '$targetName=$bump',
      if (dryRun) '--dry-run',
    ],
    workingDirectory: worktree,
    executor: executor,
  );

  if (dryRun) {
    log('Dry run complete; nothing was committed or pushed.');
    return;
  }

  final version = await readPubspecVersion(target.versionPath(worktree));
  final tag = target.renderTag(version);
  final releaseBranch = 'release/$tag';

  log('Pushing the release commit to $remote/$releaseBranch');
  await git.run([
    'push',
    remote,
    'HEAD:refs/heads/$releaseBranch',
  ], workingDirectory: worktree);

  // Prepare committed onto the local branch, but the commit reaches the remote
  // through a squash merge. Leaving it here would strand a duplicate that
  // diverges from `<remote>/<branch>` on the next pull.
  log('Restoring $branch to $remote/$branch');
  await git.run([
    'reset',
    '--hard',
    '$remote/$branch',
  ], workingDirectory: worktree);

  log('Prepared $tag. Next:');
  log(
    '  gh pr create --base $branch --head $releaseBranch --title "release: $tag"',
  );
  log('  (merge the PR, then) dart run tool/release.dart finalize');
}

/// Tags the merged release commit and pushes the tag.
///
/// The tag is signed with the maintainer's local git signing key, which is why
/// this step stays on a workstation instead of moving into CI.
Future<void> finalizeRelease({
  required String repoRoot,
  GitClient git = const IoGitClient(),
  ProcessExecutor executor = defaultProcessExecutor,
  ReleaseLogger log = _defaultLog,
}) async {
  final config = await loadShipworldConfig(p.join(repoRoot, 'shipworld.yaml'));
  final target = config.target(targetName);
  final branch = target.branch;

  final worktree = await locateBranchWorktree(
    repoRoot: repoRoot,
    branch: branch,
    git: git,
  );
  log('$branch worktree: $worktree');

  log('Fast-forwarding $branch');
  await git.run(const ['pull', '--ff-only'], workingDirectory: worktree);

  log('Finalizing $targetName');
  await runInherited(
    'dart',
    const [
      'run',
      'shipworld:shipworld',
      'release',
      'finalize',
      targetName,
      '--push',
    ],
    workingDirectory: worktree,
    executor: executor,
  );
}

const Set<String> _bumps = {'major', 'minor', 'patch'};

const String usage =
    'Usage: dart run tool/release.dart prepare <major|minor|patch> [--dry-run]\n'
    '       dart run tool/release.dart finalize';

/// One recognized invocation of this tool.
sealed class ReleaseCommand {
  const ReleaseCommand();
}

final class PrepareCommand extends ReleaseCommand {
  const PrepareCommand({required this.bump, required this.dryRun});

  final String bump;
  final bool dryRun;
}

final class FinalizeCommand extends ReleaseCommand {
  const FinalizeCommand();
}

/// Parses [arguments], returning `null` when they do not name a command.
ReleaseCommand? parseReleaseCommand(List<String> arguments) {
  return switch (arguments) {
    ['prepare', final bump] when _bumps.contains(bump) => PrepareCommand(
      bump: bump,
      dryRun: false,
    ),
    ['prepare', final bump, '--dry-run'] when _bumps.contains(bump) =>
      PrepareCommand(bump: bump, dryRun: true),
    ['finalize'] => const FinalizeCommand(),
    _ => null,
  };
}

Future<String> _repoRoot() {
  return const IoGitClient().run(const [
    'rev-parse',
    '--show-toplevel',
  ], workingDirectory: Directory.current.path);
}

Future<void> main(List<String> arguments) async {
  final command = parseReleaseCommand(arguments);

  if (command == null) {
    stderr.writeln(usage);
    exitCode = 64;
    return;
  }

  final repoRoot = await _repoRoot();

  try {
    switch (command) {
      case PrepareCommand(:final bump, :final dryRun):
        await prepareRelease(repoRoot: repoRoot, bump: bump, dryRun: dryRun);
      case FinalizeCommand():
        await finalizeRelease(repoRoot: repoRoot);
    }
  } on ShipworldException catch (error) {
    stderr.writeln('[release] ${error.message}');
    exitCode = 1;
  }
}
