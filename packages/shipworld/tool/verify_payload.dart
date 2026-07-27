import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shipworld/shipworld.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln('Usage: verify_payload <payload-root> <launcher-relative>');
    exitCode = 64;
    return;
  }

  final temporary = await Directory.systemTemp.createTemp(
    'shipworld-flutter-payload-',
  );

  try {
    final payload = DirectoryPayload(
      directoryPath: args[0],
      launcherRelativePath: args[1],
    );
    await payload.stage(temporary.path);
    final launcher = File(p.join(temporary.path, args[1]));

    if (!await launcher.exists()) {
      throw ShipworldException(
        'Staged Flutter launcher not found: ${launcher.path}',
      );
    }

    stdout.writeln('Verified Flutter payload: ${launcher.path}');
  } finally {
    await temporary.delete(recursive: true);
  }
}
