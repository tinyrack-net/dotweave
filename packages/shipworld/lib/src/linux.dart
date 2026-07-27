import 'dart:io';

import 'package:path/path.dart' as p;

import 'context.dart';
import 'payload.dart';
import 'process.dart';

/// Product metadata used to stage an AppImage.
final class AppImageConfig {
  const AppImageConfig({
    required this.name,
    required this.displayName,
    required this.iconPath,
    required this.categories,
    this.terminal = false,
  });

  final String name;
  final String displayName;
  final String iconPath;
  final List<String> categories;
  final bool terminal;
}

String _desktopEntry(AppImageConfig config, String launcher) =>
    '''
[Desktop Entry]
Name=${config.displayName}
Exec=$launcher %F
Icon=${config.name}
Type=Application
Categories=${config.categories.join(';')};
Terminal=${config.terminal}
''';

String _appRun(String launcherRelativePath) =>
    '''
#!/bin/sh
HERE="\$(dirname "\$(readlink -f "\${0}")")"
exec "\${HERE}/usr/bin/$launcherRelativePath" "\$@"
''';

Future<void> _makeExecutable(String path) async {
  if (Platform.isWindows) {
    return;
  }

  await runChecked('chmod', ['755', path]);
}

/// Builds an AppImage from a prebuilt [payload].
Future<void> buildAppImage({
  required String repoRoot,
  required ArtifactPayload payload,
  required AppImageConfig config,
  required String outputPath,
  required String arch,
  required String appImageToolPath,
}) async {
  final appDir = p.join(repoRoot, '.shipworld', 'appimage', config.name);
  final artifactPath = p.join(repoRoot, outputPath);

  final appDirectory = Directory(appDir);

  if (appDirectory.existsSync()) {
    await appDirectory.delete(recursive: true);
  }

  await Directory(p.join(appDir, 'usr/bin')).create(recursive: true);
  await Directory(p.dirname(artifactPath)).create(recursive: true);
  await payload.stage(p.join(appDir, 'usr/bin'));
  await _makeExecutable(
    p.join(appDir, 'usr/bin', payload.launcherRelativePath),
  );

  await File(
    p.join(appDir, '${config.name}.desktop'),
  ).writeAsString(_desktopEntry(config, payload.launcherRelativePath));

  await File(config.iconPath).copy(p.join(appDir, '${config.name}.svg'));

  await File(
    p.join(appDir, 'AppRun'),
  ).writeAsString(_appRun(payload.launcherRelativePath));
  await _makeExecutable(p.join(appDir, 'AppRun'));

  stdout.writeln('Building AppImage...');
  await runChecked(
    appImageToolPath,
    ['--appimage-extract-and-run', appDir, artifactPath],
    workingDirectory: repoRoot,
    environment: {'ARCH': arch},
  );
}

/// Context-bound Linux AppImage packaging API.
final class LinuxPackagingService {
  const LinuxPackagingService(this.context);

  final ShipworldContext context;

  Future<void> build({
    required String repoRoot,
    required ArtifactPayload payload,
    required AppImageConfig config,
    required String outputPath,
    required String arch,
    required String appImageToolPath,
  }) {
    return context.run(
      () => buildAppImage(
        repoRoot: repoRoot,
        payload: payload,
        config: config,
        outputPath: outputPath,
        arch: arch,
        appImageToolPath: appImageToolPath,
      ),
    );
  }
}
