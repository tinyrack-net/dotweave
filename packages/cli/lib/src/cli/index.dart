// Dart port of `packages/cli/src/cli/index.ts`.

import 'package:dotweave/src/cli/autocomplete.dart';
import 'package:dotweave/src/cli/root_commands.dart';
import 'package:dotweave/src/config/constants.dart';
import 'package:tinyrack_cli/tinyrack_cli.dart';

RouteMap buildRootRoute() {
  final (:autocompleteRoute, :completeCommand) = buildAutocompleteRoute();

  return buildRouteMap(
    docs: RouteMapDocs(
      brief: 'A personal CLI tool for git-backed configuration sync.',
      fullDescription:
          'Manage tracked configuration files under your home directory, mirror them into a git-backed sync directory, and restore them later on other devices.',
      hideRoute: {AppConstants.autocomplete.completeSubcommand: true},
    ),
    routes: {
      AppConstants.autocomplete.completeSubcommand: completeCommand,
      'autocomplete': autocompleteRoute,
      ...rootCommandRoutes,
    },
  );
}
