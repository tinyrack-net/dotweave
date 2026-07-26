// Dart port of `packages/cli/src/cli/skill/index.ts`.

import 'package:dotweave/src/cli/skill/install.dart';
import 'package:tinyrack_cli/tinyrack_cli.dart';

final RouteMap skillRoute = buildRouteMap(
  docs: const RouteMapDocs(
    brief: 'Manage portable agent skills',
    fullDescription: "Install Dotweave's bundled portable agent skill.",
  ),
  routes: {'install': skillInstallCommand},
);
