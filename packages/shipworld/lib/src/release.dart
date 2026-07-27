import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart' as semver;

import 'config.dart';
import 'context.dart';
import 'error.dart';
import 'version.dart';
import 'version_files.dart';

/// One target included in a prepared release set.
final class PreparedReleaseTarget {
  const PreparedReleaseTarget({
    required this.name,
    required this.previousVersion,
    required this.version,
    required this.tag,
  });

  final String name;
  final String previousVersion;
  final String version;
  final String tag;
}

/// Result of an atomic release preparation.
final class PreparedReleaseSet {
  const PreparedReleaseSet({
    required this.dryRun,
    required this.targets,
    required this.commitMessage,
  });

  final bool dryRun;
  final List<PreparedReleaseTarget> targets;
  final String commitMessage;
}

/// Result of creating one or more signed tags at a verified remote HEAD.
final class FinalizedReleaseSet {
  const FinalizedReleaseSet({
    required this.tags,
    required this.head,
    required this.pushed,
  });

  final List<String> tags;
  final String head;
  final bool pushed;
}

String _bumpConfiguredVersion(
  String input,
  ReleaseType releaseType, {
  required bool incrementBuild,
}) {
  final parsed = semver.Version.parse(input);
  final core = switch (releaseType) {
    ReleaseType.patch => semver.Version(
      parsed.major,
      parsed.minor,
      parsed.patch + 1,
    ),
    ReleaseType.minor => semver.Version(parsed.major, parsed.minor + 1, 0),
    ReleaseType.major => semver.Version(parsed.major + 1, 0, 0),
  };
  if (!incrementBuild) return core.toString();
  final firstBuild = parsed.build.isEmpty ? null : parsed.build.first;
  final number = firstBuild == null ? 0 : int.tryParse(firstBuild.toString());
  if (number == null) {
    throw ShipworldException(
      'Flutter build metadata must start with a number: $input',
      code: 'invalid_version',
    );
  }
  return '$core+${number + 1}';
}

Future<void> _validateChangelog(
  String repoRoot,
  ReleaseTargetConfig target,
  String version,
) async {
  final changelog = target.changelog;
  if (changelog == null) return;
  final path = target.targetPath(repoRoot, changelog, 'changelog');
  final file = File(path);
  if (!await file.exists()) {
    throw ShipworldException(
      '${target.name} changelog not found: $changelog',
      code: 'invalid_changelog',
    );
  }
  final content = await file.readAsString();
  final core = version.split('+').first;
  final heading = RegExp(
    '^##\\s+${RegExp.escape(core)}\\s*\$',
    multiLine: true,
  ).firstMatch(content);
  if (heading == null) {
    throw ShipworldException(
      '${target.name} changelog must contain "## $core"',
      code: 'invalid_changelog',
    );
  }
  final remainder = content.substring(heading.end);
  final nextHeading = RegExp(r'^##\s+', multiLine: true).firstMatch(remainder);
  final body = nextHeading == null
      ? remainder
      : remainder.substring(0, nextHeading.start);
  if (body.trim().isEmpty) {
    throw ShipworldException(
      '${target.name} changelog section for $core is empty',
      code: 'invalid_changelog',
    );
  }
}

String _repoRelative(String repoRoot, String path) =>
    p.relative(path, from: repoRoot).replaceAll(p.separator, '/');

/// Release orchestration using immutable injected external boundaries.
final class ReleaseService {
  const ReleaseService({required this.config, required this.context});

  final ShipworldConfig config;
  final ShipworldContext context;

  Future<String> _git(List<String> arguments) =>
      context.git.run(arguments, workingDirectory: config.repoRoot);

  Future<bool> _hasLocalTag(String tag) async =>
      await _git(['tag', '--list', tag]) == tag;

  Future<bool> _hasRemoteTag(String tag) async => (await _git([
    'ls-remote',
    '--tags',
    config.remote,
    'refs/tags/$tag',
  ])).isNotEmpty;

  /// Preflights every target, then writes and commits the release as one unit.
  Future<PreparedReleaseSet> prepare({
    required Map<String, ReleaseType> bumps,
    bool dryRun = false,
  }) async {
    if (bumps.isEmpty) {
      throw const ShipworldException(
        'At least one release target is required',
        code: 'missing_target',
      );
    }
    final staged = await _git(['diff', '--cached', '--name-only']);
    if (staged.isNotEmpty && !dryRun) {
      throw const ShipworldException(
        'Staged changes are not allowed before release preparation',
        code: 'dirty_worktree',
      );
    }
    final branch = await _git(['branch', '--show-current']);
    final allowedDirtyPaths = <String>{
      for (final name in bumps.keys)
        if (config.target(name).changelog case final changelog?)
          _repoRelative(
            config.repoRoot,
            config
                .target(name)
                .targetPath(config.repoRoot, changelog, 'changelog'),
          ),
    };
    final status = await _git(['status', '--porcelain']);
    if (status.isNotEmpty && !dryRun) {
      final dirtyPaths = status
          .split('\n')
          .where((line) => line.trim().isNotEmpty)
          .map((line) => line.length > 3 ? line.substring(3).trim() : line)
          .toSet();
      final unexpected = dirtyPaths.difference(allowedDirtyPaths);
      if (unexpected.isNotEmpty) {
        throw ShipworldException(
          'Git worktree contains unrelated changes: ${unexpected.join(', ')}',
          code: 'dirty_worktree',
        );
      }
    }

    final prepared = <PreparedReleaseTarget>[];
    final renderedFiles = <String, String>{};
    final originalFiles = <String, String>{};
    final stagePaths = <String>{};
    for (final entry in bumps.entries) {
      final target = config.target(entry.key);
      if (!dryRun && branch != target.branch) {
        throw ShipworldException(
          'Target ${target.name} must be prepared from ${target.branch}; '
          'current branch is $branch',
          code: 'wrong_branch',
        );
      }
      final pubspecPath = target.versionPath(config.repoRoot);
      final pubspecContent = await File(pubspecPath).readAsString();
      final previousVersion = await readPubspecVersion(pubspecPath);
      final version = _bumpConfiguredVersion(
        previousVersion,
        entry.value,
        incrementBuild: target.kind == ShipworldTargetKind.flutterApplication,
      );
      final tag = target.renderTag(version);
      if (await _hasLocalTag(tag) || await _hasRemoteTag(tag)) {
        throw ShipworldException(
          'Release tag already exists: $tag',
          code: 'tag_exists',
        );
      }
      await _validateChangelog(config.repoRoot, target, version);
      originalFiles[pubspecPath] = pubspecContent;
      renderedFiles[pubspecPath] = renderPubspecVersion(
        pubspecContent,
        version,
      );
      stagePaths.add(_repoRelative(config.repoRoot, pubspecPath));
      for (final writer in target.version.synchronized) {
        final writerPath = target.targetPath(
          config.repoRoot,
          writer.path,
          'synchronized version file',
        );
        final content = await File(writerPath).readAsString();
        originalFiles[writerPath] = content;
        renderedFiles[writerPath] = switch (writer.kind) {
          VersionWriterKind.dartConstant => renderVersionConstant(
            version,
            constant: writer.constant,
          ),
        };
        stagePaths.add(_repoRelative(config.repoRoot, writerPath));
      }
      if (target.changelog case final changelog?) {
        stagePaths.add(
          _repoRelative(
            config.repoRoot,
            target.targetPath(config.repoRoot, changelog, 'changelog'),
          ),
        );
      }
      prepared.add(
        PreparedReleaseTarget(
          name: target.name,
          previousVersion: previousVersion,
          version: version,
          tag: tag,
        ),
      );
    }
    final commitMessage = prepared.length == 1
        ? config
              .target(prepared.single.name)
              .renderCommit(prepared.single.version)
        : config.renderBatchCommit([
            for (final item in prepared)
              (name: item.name, version: item.version),
          ]);
    if (dryRun) {
      for (final item in prepared) {
        context.logger.info('Would update ${item.name} to ${item.version}');
      }
      return PreparedReleaseSet(
        dryRun: true,
        targets: List.unmodifiable(prepared),
        commitMessage: commitMessage,
      );
    }

    try {
      for (final entry in renderedFiles.entries) {
        await File(entry.key).writeAsString(entry.value);
      }
      await _git(['add', '--', ...stagePaths]);
      await _git(['commit', '-m', commitMessage]);
    } catch (error) {
      try {
        await _git(['restore', '--staged', '--', ...stagePaths]);
      } on Object {
        // Preserve the original error; file restoration below is authoritative.
      }
      for (final entry in originalFiles.entries) {
        await File(entry.key).writeAsString(entry.value);
      }
      rethrow;
    }
    return PreparedReleaseSet(
      dryRun: false,
      targets: List.unmodifiable(prepared),
      commitMessage: commitMessage,
    );
  }

  /// Creates signed tags only when local HEAD equals the configured remote.
  Future<FinalizedReleaseSet> finalize({
    required List<String> targetNames,
    bool push = false,
  }) async {
    if (targetNames.isEmpty) {
      throw const ShipworldException(
        'At least one release target is required',
        code: 'missing_target',
      );
    }
    if ((await _git(['status', '--porcelain'])).isNotEmpty) {
      throw const ShipworldException(
        'Git worktree must be clean before finalizing a release',
        code: 'dirty_worktree',
      );
    }
    final branch = await _git(['branch', '--show-current']);
    final branches = {
      for (final name in targetNames) config.target(name).branch,
    };
    if (branches.length != 1 || branch != branches.single) {
      throw ShipworldException(
        'Targets must be finalized together from ${branches.join(', ')}; '
        'current branch is $branch',
        code: 'wrong_branch',
      );
    }
    await _git(['fetch', '--tags', config.remote, branch]);
    final head = await _git(['rev-parse', 'HEAD']);
    final remoteHead = await _git([
      'rev-parse',
      'refs/remotes/${config.remote}/$branch',
    ]);
    if (head != remoteHead) {
      throw ShipworldException(
        'HEAD must equal ${config.remote}/$branch before finalizing',
        code: 'unmerged_head',
      );
    }

    final tags = <String>[];
    for (final name in targetNames) {
      final target = config.target(name);
      final version = await readPubspecVersion(
        target.versionPath(config.repoRoot),
      );
      await _validateChangelog(config.repoRoot, target, version);
      final tag = target.renderTag(version);
      if (await _hasLocalTag(tag) || await _hasRemoteTag(tag)) {
        throw ShipworldException(
          'Release tag already exists: $tag',
          code: 'tag_exists',
        );
      }
      tags.add(tag);
    }

    final created = <String>[];
    try {
      for (var index = 0; index < tags.length; index++) {
        final target = config.target(targetNames[index]);
        final version = await readPubspecVersion(
          target.versionPath(config.repoRoot),
        );
        final tag = tags[index];
        await _git([
          'tag',
          '-s',
          tag,
          '-m',
          '${target.name} ${version.split('+').first}',
        ]);
        created.add(tag);
        final taggedHead = await _git(['rev-list', '-n', '1', tag]);
        if (taggedHead != head) {
          throw ShipworldException(
            'Tag $tag does not point to release HEAD',
            code: 'tag_target_mismatch',
          );
        }
      }
      if (push) {
        await _git(['push', '--atomic', config.remote, ...tags]);
      }
    } catch (error) {
      for (final tag in created.reversed) {
        try {
          await _git(['tag', '-d', tag]);
        } on Object {
          // Preserve the operation error and attempt all local cleanup.
        }
      }
      rethrow;
    }
    return FinalizedReleaseSet(
      tags: List.unmodifiable(tags),
      head: head,
      pushed: push,
    );
  }

  /// Checks that a CI ref matches the configured target version.
  Future<String> verify(String targetName) async {
    final target = config.target(targetName);
    final version = await readPubspecVersion(
      target.versionPath(config.repoRoot),
    );
    final expected = target.renderTag(version);
    final actual = context.environment['GITHUB_REF_NAME'];
    if (actual != expected) {
      throw ShipworldException(
        'Tag ${actual ?? '(missing)'} does not match $targetName version '
        '$expected',
        code: 'tag_mismatch',
      );
    }
    return expected;
  }
}
