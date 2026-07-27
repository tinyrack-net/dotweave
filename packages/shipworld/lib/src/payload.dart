import 'dart:io';

import 'package:path/path.dart' as p;

import 'error.dart';

/// A prebuilt application payload that can be staged for a desktop package.
sealed class ArtifactPayload {
  const ArtifactPayload({required this.launcherRelativePath});

  /// Path to the executable relative to the staged payload root.
  final String launcherRelativePath;

  /// Copies this payload into [destination].
  Future<void> stage(String destination);

  void validateLauncher() {
    if (p.isAbsolute(launcherRelativePath) ||
        p.split(launcherRelativePath).contains('..') ||
        launcherRelativePath.trim().isEmpty) {
      throw ShipworldException(
        'Payload launcher must stay inside the payload: '
        '$launcherRelativePath',
        code: 'invalid_payload',
      );
    }
  }

  Future<void> verifyStagedLauncher(String destination) async {
    final launcher = File(p.join(destination, launcherRelativePath));
    if (!await launcher.exists()) {
      throw ShipworldException(
        'Payload launcher not found: $launcherRelativePath',
        code: 'invalid_payload',
      );
    }
  }
}

/// A payload containing one native executable.
final class ExecutablePayload extends ArtifactPayload {
  const ExecutablePayload({
    required this.executablePath,
    required this.executableName,
  }) : super(launcherRelativePath: executableName);

  /// Source executable.
  final String executablePath;

  /// Name used inside the package.
  final String executableName;

  @override
  Future<void> stage(String destination) async {
    validateLauncher();
    if (!await File(executablePath).exists()) {
      throw ShipworldException(
        'Payload executable not found: $executablePath',
        code: 'invalid_payload',
      );
    }
    await Directory(destination).create(recursive: true);
    await File(executablePath).copy(p.join(destination, executableName));
    await verifyStagedLauncher(destination);
  }
}

/// A payload containing a prebuilt directory such as a Flutter bundle.
final class DirectoryPayload extends ArtifactPayload {
  const DirectoryPayload({
    required this.directoryPath,
    required super.launcherRelativePath,
  });

  /// Source directory.
  final String directoryPath;

  @override
  Future<void> stage(String destination) async {
    validateLauncher();
    final source = Directory(directoryPath);

    if (!await source.exists()) {
      throw ShipworldException('Payload directory not found: $directoryPath');
    }

    await for (final entity in source.list(recursive: true)) {
      final relative = p.relative(entity.path, from: source.path);
      final target = p.join(destination, relative);

      if (entity is Directory) {
        await Directory(target).create(recursive: true);
      } else if (entity is File) {
        await Directory(p.dirname(target)).create(recursive: true);
        await entity.copy(target);
      } else if (entity is Link) {
        final rawTarget = await entity.target();
        final resolvedTarget = p.normalize(
          p.isAbsolute(rawTarget)
              ? rawTarget
              : p.join(p.dirname(entity.path), rawTarget),
        );
        final sourceRoot = p.normalize(p.absolute(source.path));
        final absoluteTarget = p.normalize(p.absolute(resolvedTarget));
        if (absoluteTarget != sourceRoot &&
            !p.isWithin(sourceRoot, absoluteTarget)) {
          throw ShipworldException(
            'Payload symlink escapes the payload root: ${entity.path}',
            code: 'invalid_payload',
          );
        }
        await Directory(p.dirname(target)).create(recursive: true);
        await Link(target).create(rawTarget);
      }
    }
    await verifyStagedLauncher(destination);
  }
}
