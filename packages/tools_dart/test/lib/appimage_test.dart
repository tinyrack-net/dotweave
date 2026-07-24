import 'dart:io';

import 'package:dotweave_tools/src/lib/appimage.dart';
import 'package:dotweave_tools/src/lib/git.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('getAppImageIconPath', () {
    test('resolves the homepage logo from its public asset location', () async {
      final repoRoot = await getRepoRoot(Directory.current.path);
      final iconPath = getAppImageIconPath(repoRoot);

      expect(iconPath, p.join(repoRoot, 'packages/homepage/public/logo.svg'));
      expect(File(iconPath).existsSync(), isTrue);
    });
  });
}
