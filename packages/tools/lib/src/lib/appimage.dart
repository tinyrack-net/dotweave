import 'dart:io';

import 'package:path/path.dart' as p;

import 'exec.dart';

String getAppImageIconPath(String repoRoot) {
  return p.join(repoRoot, 'homepage/public/favicon.svg');
}

const String _desktopEntry = '''
[Desktop Entry]
Name=Dotweave
Exec=dotweave %F
Icon=dotweave
Type=Application
Categories=Utility;
Terminal=true
''';

const String _appRun = r'''
#!/bin/sh
HERE="$(dirname "$(readlink -f "${0}")")"
export PATH="${HERE}/usr/bin:${PATH}"
exec dotweave "$@"
''';

Future<void> _makeExecutable(String path) async {
  if (Platform.isWindows) {
    return;
  }

  await runChecked('chmod', ['755', path]);
}

Future<void> performAppImageBuild({
  required String repoRoot,
  required String executablePath,
  required String outputPath,
  required String arch,
}) async {
  final appDir = p.join(repoRoot, 'AppDir');
  final binPath = p.join(repoRoot, executablePath);
  final appImageToolPath = p.join(repoRoot, 'appimagetool');
  final artifactPath = p.join(repoRoot, outputPath);

  final appDirectory = Directory(appDir);

  if (appDirectory.existsSync()) {
    await appDirectory.delete(recursive: true);
  }

  await Directory(p.join(appDir, 'usr/bin')).create(recursive: true);
  await File(binPath).copy(p.join(appDir, 'usr/bin/dotweave'));
  await _makeExecutable(p.join(appDir, 'usr/bin/dotweave'));

  await File(p.join(appDir, 'dotweave.desktop')).writeAsString(_desktopEntry);

  await File(
    getAppImageIconPath(repoRoot),
  ).copy(p.join(appDir, 'dotweave.svg'));

  await File(p.join(appDir, 'AppRun')).writeAsString(_appRun);
  await _makeExecutable(p.join(appDir, 'AppRun'));

  final appImageToolName = 'appimagetool-$arch.AppImage';
  final appImageToolUrl =
      'https://github.com/AppImage/AppImageKit/releases/download/continuous/$appImageToolName';

  stdout.writeln('Downloading $appImageToolName...');
  await runChecked('wget', [appImageToolUrl, '-O', appImageToolPath]);
  await _makeExecutable(appImageToolPath);

  stdout.writeln('Building AppImage...');
  await runChecked(
    appImageToolPath,
    ['--appimage-extract-and-run', appDir, artifactPath],
    workingDirectory: repoRoot,
    environment: {'ARCH': arch},
  );
}
