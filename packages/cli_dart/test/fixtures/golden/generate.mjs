// Regenerates pretty-json.json, the Node JSON.stringify golden fixture that
// pins Dart formatJsonPretty to byte-identical output.
// Run from packages/cli_dart: node test/fixtures/golden/generate.mjs
// Keep this value in sync with test/lib/json_format_test.dart.
import { writeFileSync } from "node:fs";

const value = {
  version: 8,
  repositoryFormat: 1,
  age: {
    recipients: [
      "age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq",
    ],
  },
  profiles: ["default", "work"],
  entries: [
    {
      kind: "file",
      localPath: { default: "~/.zshrc", win: "%USERPROFILE%\\.zshrc" },
      repoPath: "zshrc",
      mode: "normal",
      permission: "0600",
      profiles: [],
    },
    {
      kind: "directory",
      localPath: { default: "~/테스트/config dir" },
      empty: {},
      floaty: 0.5,
      negative: -3,
      escaped: 'line1\nline2\ttab "quoted" back\\slash / emoji 🎉',
    },
  ],
};

writeFileSync(
  new URL("pretty-json.json", import.meta.url),
  JSON.stringify(value, null, 2) + "\n",
);
console.log("written");
