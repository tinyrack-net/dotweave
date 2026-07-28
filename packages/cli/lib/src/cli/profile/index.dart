// Dart port of `packages/cli/src/cli/profile/index.ts`.

import 'package:cliweave/cliweave.dart';
import 'package:dotweave/src/cli/profile/add.dart';
import 'package:dotweave/src/cli/profile/list.dart';
import 'package:dotweave/src/cli/profile/remove.dart';
import 'package:dotweave/src/cli/profile/use.dart';

final RouteMap<ApplicationContext> profileRoute = buildRouteMap(
  docs: const RouteMapDocs(
    brief: 'Manage active and assigned sync profiles',
    fullDescription:
        'Inspect, add, remove, or select manifest-registered profiles.',
  ),
  routes: {
    'add': profileAddCommand,
    'list': profileListCommand,
    'remove': profileRemoveCommand,
    'use': profileUseCommand,
  },
);
