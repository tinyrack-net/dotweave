// Dart port of `packages/cli/src/cli/root-commands.ts`.
//
// Later milestones add one import plus one map entry per command; keep the
// entries in the TS insertion order (cd, doctor, init, profile, pull, push,
// skill, status, track, untrack) so help output and completions list routes
// in the same order as the TS CLI.

import 'package:dotweave/src/cli/cd.dart';
import 'package:dotweave/src/cli/doctor.dart';
import 'package:dotweave/src/cli/init.dart';
import 'package:dotweave/src/cli/profile/index.dart';
import 'package:dotweave/src/cli/pull.dart';
import 'package:dotweave/src/cli/push.dart';
import 'package:dotweave/src/cli/skill/index.dart';
import 'package:dotweave/src/cli/status.dart';
import 'package:dotweave/src/cli/track.dart';
import 'package:dotweave/src/cli/untrack.dart';
import 'package:tinyrack_cli/tinyrack_cli.dart';

final Map<String, RoutingTarget> rootCommandRoutes = {
  'cd': cdCommand,
  'doctor': doctorCommand,
  'init': initCommand,
  'profile': profileRoute,
  'pull': pullCommand,
  'push': pushCommand,
  'skill': skillRoute,
  'status': statusCommand,
  'track': trackCommand,
  'untrack': untrackCommand,
};
