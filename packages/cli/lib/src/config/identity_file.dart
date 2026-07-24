import 'package:path/path.dart' as p;

import 'constants.dart';

/// Mirrors node:path `resolve` using the platform-native path context.
String _resolve(List<String> paths) {
  return p.normalize(p.joinAll([p.current, ...paths]));
}

String resolveDefaultIdentityFile(String dotweaveHomeDirectory) {
  return _resolve([
    dotweaveHomeDirectory,
    AppConstants.init.defaultIdentityFileName,
  ]);
}
