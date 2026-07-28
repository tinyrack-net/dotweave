import 'dart:io';

import 'package:dotweave/src/application.dart';

Future<void> main(List<String> args) async {
  exitCode = await runCli(args);
  await stdout.flush();
  await stderr.flush();
}
