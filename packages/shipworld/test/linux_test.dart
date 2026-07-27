import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shipworld/linux.dart';
import 'package:shipworld/shipworld.dart';
import 'package:test/test.dart';

final class _LinuxExecutor implements ProcessExecutor {
  final calls = <List<String>>[];

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    calls.add([executable, ...arguments]);
    return ProcessResult(0, 0, '', '');
  }

  @override
  Future<int> runInherited(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) {
    throw UnimplementedError();
  }
}

void main() {
  test(
    'stages a directory payload and invokes only the configured tool',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'shipworld-linux-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final payload = Directory(p.join(temporary.path, 'payload'));
      await payload.create();
      await File(p.join(payload.path, 'example')).writeAsString('binary');
      final icon = File(p.join(temporary.path, 'icon.svg'));
      await icon.writeAsString('<svg/>');
      final executor = _LinuxExecutor();

      await LinuxPackagingService(ShipworldContext(process: executor)).build(
        repoRoot: temporary.path,
        payload: DirectoryPayload(
          directoryPath: payload.path,
          launcherRelativePath: 'example',
        ),
        config: AppImageConfig(
          name: 'example',
          displayName: 'Example',
          iconPath: icon.path,
          categories: const ['Utility'],
        ),
        outputPath: p.join('dist', 'Example.AppImage'),
        arch: 'x86_64',
        appImageToolPath: '/opt/appimagetool',
      );

      expect(
        executor.calls,
        contains(
          equals([
            '/opt/appimagetool',
            '--appimage-extract-and-run',
            p.join(temporary.path, '.shipworld', 'appimage', 'example'),
            p.join(temporary.path, 'dist', 'Example.AppImage'),
          ]),
        ),
      );
      expect(
        await File(
          p.join(temporary.path, '.shipworld', 'appimage', 'example', 'AppRun'),
        ).readAsString(),
        contains('usr/bin/example'),
      );
    },
  );
}
