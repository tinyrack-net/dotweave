// Dart port of `packages/cli/src/cli/skill/index.ts`.

import 'package:cliweave/cliweave.dart';
import 'package:dotweave/src/cli/skill/install.dart';

final RouteMap<ApplicationContext> skillRoute = buildRouteMap(
  docs: const RouteMapDocs(
    brief: 'Manage portable agent skills',
    fullDescription: "Install Dotweave's bundled portable agent skill.",
  ),
  routes: {'install': skillInstallCommand},
);
