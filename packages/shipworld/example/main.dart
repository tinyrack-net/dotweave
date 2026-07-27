import 'package:shipworld/shipworld.dart';

Future<void> main() async {
  final config = await loadShipworldConfig('shipworld.yaml');

  for (final target in config.targets.values) {
    print('${target.name}: ${target.kind.yamlName}');
  }
}
