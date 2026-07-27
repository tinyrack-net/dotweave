import { readFileSync } from "node:fs";

// The CLI version's source of truth is the Dart package's pubspec. Shipworld
// updates it together with version.g.dart during release preparation.
const pubspec = readFileSync(
  new URL("../packages/cli/pubspec.yaml", import.meta.url),
  "utf8",
);

const match = pubspec.match(/^version:\s*(\S+)/m);

if (!match?.[1]) {
  throw new Error(
    "Could not read the CLI version from packages/cli/pubspec.yaml",
  );
}

export const cliVersion: string = match[1];
