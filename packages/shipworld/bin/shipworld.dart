import 'dart:io';

import 'package:shipworld/src/application.dart';

Future<void> main(List<String> args) async {
  exitCode = await runShipworld(args);
  await stdout.flush();
  await stderr.flush();
}
