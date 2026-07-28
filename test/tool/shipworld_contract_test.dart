import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shipworld/shipworld.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Dotweave configuration satisfies the public Shipworld schema',
    () async {
      var root = Directory.current;
      while (!File(p.join(root.path, 'shipworld.yaml')).existsSync()) {
        final parent = root.parent;
        if (parent.path == root.path) {
          fail('Could not locate shipworld.yaml');
        }
        root = parent;
      }

      final config = await loadShipworldConfig(
        p.join(root.path, 'shipworld.yaml'),
      );
      final target = config.target('dotweave');

      expect(target.kind, ShipworldTargetKind.cliApplication);
      expect(target.product?.executable, 'dotweave');
      expect(target.windows, isNotNull);
      expect(target.linux, isNotNull);
      expect(File(target.versionPath(config.repoRoot)).existsSync(), isTrue);
    },
  );
}
