import 'dart:io';

import 'package:dotweave_tools/src/application.dart';

Future<void> main(List<String> args) async {
  exitCode = await runTools(args);
  await stdout.flush();
  await stderr.flush();
}
