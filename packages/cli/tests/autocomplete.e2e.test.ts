import {
  chmod,
  mkdir,
  mkdtemp,
  realpath,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";

import { execa } from "execa";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { rootCommandRoutes } from "../src/cli/root-commands.ts";
import {
  cliHookUrl,
  cliNodeOptions,
  cliPath,
} from "../src/test/helpers/cli-entry.ts";
import {
  fishPath,
  isBashAvailable,
  isFishAvailable,
  isPowerShellAvailable,
  isZshAvailable,
  powerShellPath,
} from "../src/test/helpers/shell-availability.ts";
import { stripAnsi } from "../src/test/helpers/sync-fixture.ts";

const COMPLETE_COMMAND = 'env -u COMP_LINE dotweave __complete "${inputs[@]}"';
const rootCommandNames = ["autocomplete", ...Object.keys(rootCommandRoutes)];
const autocompleteEnvironment: NodeJS.ProcessEnv & {
  DOTWEAVE_AUTOCOMPLETE_SHELL?: string;
} = process.env;
const selectedAutocompleteShell =
  autocompleteEnvironment.DOTWEAVE_AUTOCOMPLETE_SHELL;
const supportedAutocompleteShells = [
  "bash",
  "zsh",
  "fish",
  "powershell",
] as const;
type SupportedAutocompleteShell = (typeof supportedAutocompleteShells)[number];

const runForShell = (shell: SupportedAutocompleteShell, available: boolean) => {
  if (
    selectedAutocompleteShell !== undefined &&
    selectedAutocompleteShell !== shell
  ) {
    return it.skip;
  }

  if (selectedAutocompleteShell === shell) {
    return it;
  }

  if (shell === "powershell" && process.platform !== "win32") {
    return it.skip;
  }

  if (available) {
    return it;
  }

  return it.skip;
};

const requireSelectedShellAvailability = (
  shell: SupportedAutocompleteShell,
  available: boolean,
) => {
  if (selectedAutocompleteShell === shell) {
    expect(
      available,
      `${shell} must be available for selected autocomplete CI shell`,
    ).toBe(true);
  }
};

const runCli = async (
  args: readonly string[],
  options?: Readonly<{
    cwd?: string;
    env?: Readonly<Record<string, string>>;
  }>,
) => {
  return execa(process.execPath, [...cliNodeOptions, ...args], {
    cwd: options?.cwd,
    env: {
      FORCE_COLOR: "0",
      NODE_NO_WARNINGS: "1",
      NO_COLOR: "1",
      ...options?.env,
    },
  });
};

const completionNames = (stdout: string) =>
  stdout.split("\n").map((line) => line.split("\t")[0] ?? line);

const powerShellLines = (stdout: string) =>
  stdout.replaceAll("\r", "").split("\n");

const bashRootCommandNames = [
  "autocomplete",
  ...Object.keys(rootCommandRoutes),
].map((commandName) => {
  return `${commandName} `;
});

const shellQuote = (value: string) => {
  return `'${value.replaceAll("'", "'\\''")}'`;
};

const cleanShellStderr = (stderr: string) => {
  return stripAnsi(stderr)
    .split(/\r?\n/u)
    .filter((line) => {
      const trimmed = line.trim();

      return (
        trimmed.length > 0 &&
        trimmed !==
          "MSYS2 is starting for the first time. Executing the initial setup." &&
        trimmed !== "Initial setup complete. MSYS2 is now ready to use."
      );
    })
    .join("\n");
};

const splitWindowsDrivePath = (value: string) => {
  const normalized = value.replaceAll("\\", "/");
  const drivePathMatch = /^([A-Za-z]):\/(.*)$/u.exec(normalized);

  if (!drivePathMatch) {
    return undefined;
  }

  const [, drive, pathRest] = drivePathMatch;

  if (drive === undefined || pathRest === undefined) {
    return undefined;
  }

  return { drive: drive.toLowerCase(), pathRest };
};

const toMsysShellPath = (value: string) => {
  const drivePath = splitWindowsDrivePath(value);
  return drivePath === undefined
    ? value.replaceAll("\\", "/")
    : `/${drivePath.drive}/${drivePath.pathRest}`;
};

const toWslShellPath = (value: string) => {
  const drivePath = splitWindowsDrivePath(value);
  return drivePath === undefined
    ? value.replaceAll("\\", "/")
    : `/mnt/${drivePath.drive}/${drivePath.pathRest}`;
};

const shellPathEntries = (value: string) => {
  if (process.platform !== "win32") {
    return [value];
  }

  return [toWslShellPath(value), toMsysShellPath(value)];
};

const createShellShimScript = () => {
  const cliArgs = ["--import", cliHookUrl, cliPath].map(shellQuote).join(" ");

  if (process.platform !== "win32") {
    return [
      "#!/usr/bin/env bash",
      `exec ${shellQuote(process.execPath)} ${cliArgs} "$@"`,
    ].join("\n");
  }

  return [
    "#!/usr/bin/env bash",
    'case "$(uname -r 2>/dev/null || true)" in',
    "  *icrosoft*|*WSL*)",
    `    dotweave_node=${shellQuote(toWslShellPath(process.execPath))}`,
    "    ;;",
    "  *)",
    `    dotweave_node=${shellQuote(toMsysShellPath(process.execPath))}`,
    "    ;;",
    "esac",
    `exec "$dotweave_node" ${cliArgs} "$@"`,
  ].join("\n");
};

const exportPathCommand = (binDirectory: string) =>
  `export PATH=${shellPathEntries(binDirectory).map(shellQuote).join(":")}:$PATH`;

const fishString = (value: string) => {
  return `'${value.replaceAll("\\", "\\\\").replaceAll("'", "\\'")}'`;
};

const runBashCompletion = async (
  words: readonly string[],
  currentWordIndex: number,
  options?: Readonly<{
    cwd?: string;
  }>,
) => {
  const configDirectory = await realpath(
    await mkdtemp(join(tmpdir(), "dotweave-autocomplete-bash-")),
  );
  const binDirectory = join(configDirectory, "bin");
  const homeDir = join(configDirectory, "home");
  const shimPath = join(binDirectory, "dotweave");

  await mkdir(binDirectory, { recursive: true });
  await writeFile(shimPath, createShellShimScript());
  await chmod(shimPath, 0o755);

  try {
    return await execa(
      "bash",
      [
        "-lc",
        [
          "set -euo pipefail",
          exportPathCommand(binDirectory),
          'eval "$(dotweave autocomplete bash)"',
          `COMP_WORDS=(${words.map(shellQuote).join(" ")})`,
          `COMP_CWORD=${currentWordIndex}`,
          "__dotweave_complete",
          'printf "%s\\n" "${COMPREPLY[@]}"',
        ].join("; "),
      ],
      {
        cwd: options?.cwd,
        env: {
          FORCE_COLOR: "0",
          HOME: homeDir,
          NODE_NO_WARNINGS: "1",
          NO_COLOR: "1",
        },
      },
    );
  } finally {
    await rm(configDirectory, { force: true, recursive: true });
  }
};

const runZshCompletion = async (
  words: readonly string[],
  currentWord: number,
  options?: Readonly<{
    cwd?: string;
  }>,
) => {
  const configDirectory = await realpath(
    await mkdtemp(join(tmpdir(), "dotweave-autocomplete-zsh-")),
  );
  const binDirectory = join(configDirectory, "bin");
  const shimPath = join(binDirectory, "dotweave");

  await mkdir(binDirectory, { recursive: true });
  await writeFile(shimPath, createShellShimScript());
  await chmod(shimPath, 0o755);

  try {
    return await execa(
      "zsh",
      [
        "-lc",
        [
          "set -euo pipefail",
          exportPathCommand(binDirectory),
          "function compdef() { :; }",
          [
            "function compadd() {",
            '  local suffix=""',
            "  while (( $# > 0 )); do",
            '    case "$1" in',
            "      --)",
            "        shift",
            "        break",
            "        ;;",
            "      -Q)",
            "        shift",
            "        ;;",
            "      -S)",
            '        suffix="$2"',
            "        shift 2",
            "        ;;",
            "      *)",
            "        shift",
            "        ;;",
            "    esac",
            "  done",
            '  local completion=""',
            '  for completion in "$@"; do',
            '    printf "%s%s\\n" "$completion" "$suffix"',
            "  done",
            "}",
          ].join("; "),
          'eval "$(dotweave autocomplete zsh)"',
          `words=(${words.map(shellQuote).join(" ")})`,
          `CURRENT=${currentWord}`,
          "__dotweave_complete",
        ].join("; "),
      ],
      {
        cwd: options?.cwd,
        env: {
          FORCE_COLOR: "0",
          NODE_NO_WARNINGS: "1",
          NO_COLOR: "1",
        },
      },
    );
  } finally {
    await rm(configDirectory, { force: true, recursive: true });
  }
};

const runFishCompletion = async (
  commandLine: string,
  options?: Readonly<{ cwd?: string }>,
) => {
  const configDirectory = await realpath(
    await mkdtemp(join(tmpdir(), "dotweave-autocomplete-fish-")),
  );
  const binDirectory = join(configDirectory, "bin");
  await mkdir(binDirectory, { recursive: true });
  const shimPath = join(binDirectory, "dotweave");
  await writeFile(shimPath, createShellShimScript());
  await chmod(shimPath, 0o755);

  try {
    return await execa(
      fishPath ?? "fish",
      [
        "-c",
        [
          `set -gx PATH ${shellPathEntries(binDirectory)
            .map(fishString)
            .join(" ")} $PATH`,
          "dotweave autocomplete fish | source",
          `complete -C ${fishString(commandLine)}`,
        ].join("; "),
      ],
      {
        cwd: options?.cwd,
        env: {
          FORCE_COLOR: "0",
          NODE_NO_WARNINGS: "1",
          NO_COLOR: "1",
        },
      },
    );
  } finally {
    await rm(configDirectory, { force: true, recursive: true });
  }
};

const createPowerShellShim = async () => {
  const configDirectory = await realpath(
    await mkdtemp(join(tmpdir(), "dotweave-autocomplete-pwsh-")),
  );
  const binDirectory = join(configDirectory, "bin");
  await mkdir(binDirectory, { recursive: true });

  const cliArgs = cliNodeOptions
    .map((value) => JSON.stringify(value))
    .join(" ");
  if (process.platform === "win32") {
    await writeFile(
      join(binDirectory, "dotweave.cmd"),
      [`@echo off`, `"${process.execPath}" ${cliArgs} %*`].join("\r\n"),
    );
  } else {
    const shimPath = join(binDirectory, "dotweave");
    await writeFile(shimPath, createShellShimScript());
    await chmod(shimPath, 0o755);
  }

  return { binDirectory, configDirectory };
};

const runPowerShellCompletion = async (
  commandLine: string,
  options?: Readonly<{
    cwd?: string;
  }>,
) => {
  const { binDirectory, configDirectory } = await createPowerShellShim();
  const psString = (value: string) => `'${value.replaceAll("'", "''")}'`;
  const script = [
    "$ErrorActionPreference = 'Stop'",
    `$env:PATH = ${psString(binDirectory)} + ${psString(delimiter)} + $env:PATH`,
    ". ([scriptblock]::Create(((dotweave autocomplete powershell) -join [Environment]::NewLine)))",
    `$line = ${psString(commandLine)}`,
    "$matches = TabExpansion2 -inputScript $line -cursorColumn $line.Length",
    "$matches.CompletionMatches | ForEach-Object { $_.CompletionText }",
  ].join("; ");

  try {
    return await execa(
      powerShellPath ?? "pwsh",
      ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script],
      {
        cwd: options?.cwd,
        env: {
          FORCE_COLOR: "0",
          NODE_NO_WARNINGS: "1",
          NO_COLOR: "1",
        },
      },
    );
  } finally {
    await rm(configDirectory, { force: true, recursive: true });
  }
};

describe("autocomplete e2e", () => {
  let completionFixtureDirectory: string;

  it("uses a supported autocomplete shell selector when provided", () => {
    if (selectedAutocompleteShell !== undefined) {
      expect(supportedAutocompleteShells).toContain(selectedAutocompleteShell);
    }
  });

  it("requires fish when fish autocomplete is selected", () => {
    requireSelectedShellAvailability("fish", isFishAvailable);
  });

  beforeAll(async () => {
    completionFixtureDirectory = await mkdtemp(
      join(tmpdir(), "dotweave-autocomplete-"),
    );
    await writeFile(join(completionFixtureDirectory, "file-alpha.txt"), "");
    await mkdir(join(completionFixtureDirectory, "folder-beta"));
  });

  afterAll(async () => {
    await rm(completionFixtureDirectory, {
      force: true,
      recursive: true,
    });
  });

  it("appears in root help", async () => {
    const result = await runCli([]);

    expect(result.exitCode).toBe(0);
    expect(cleanShellStderr(result.stderr)).toBe("");
    expect(result.stdout).toContain("autocomplete");
    expect(result.stdout).toContain("Print shell autocomplete scripts");
  });

  it("prints a bash autocomplete script for eval", async () => {
    const result = await runCli(["autocomplete", "bash"]);

    expect(result.exitCode).toBe(0);
    expect(result.stdout).toContain("__dotweave_complete() {");
    expect(result.stdout).toContain(COMPLETE_COMMAND);
    expect(result.stdout).toContain(
      "complete -o default -o nospace -F __dotweave_complete dotweave",
    );
    expect(result.stdout).not.toContain("Setup Instructions");
    expect(cleanShellStderr(result.stderr)).toBe("");
  });

  it("prints a zsh autocomplete script for eval", async () => {
    const result = await runCli(["autocomplete", "zsh"]);

    expect(result.exitCode).toBe(0);
    expect(result.stdout).toContain("autoload -Uz compinit");
    expect(result.stdout).toContain(COMPLETE_COMMAND);
    expect(result.stdout).toContain("compdef __dotweave_complete dotweave");
    expect(cleanShellStderr(result.stderr)).toBe("");
  });

  it("prints a fish autocomplete script for source", async () => {
    const result = await runCli(["autocomplete", "fish"]);

    expect(result.exitCode).toBe(0);
    expect(result.stdout).toContain("function __dotweave_complete");
    expect(result.stdout).toContain("command dotweave __complete");
    expect(result.stdout).toContain("complete -c dotweave -f");
    expect(cleanShellStderr(result.stderr)).toBe("");
  });

  it("normalizes __complete input when the command name is included", async () => {
    const result = await runCli(["__complete", "dotweave", "aut"]);

    expect(result.exitCode).toBe(0);
    expect(result.stdout.trim().split("\t")[0]).toBe("autocomplete");
    expect(cleanShellStderr(result.stderr)).toBe("");
  });

  it("completes track targets and flags after an existing target", async () => {
    const result = await runCli(["__complete", "track", "file-alpha.txt", ""], {
      cwd: completionFixtureDirectory,
    });

    expect(result.exitCode).toBe(0);
    expect(completionNames(result.stdout)).toEqual(
      expect.arrayContaining([
        "--mode",
        "--profile",
        "file-alpha.txt",
        "folder-beta/",
      ]),
    );
    expect(cleanShellStderr(result.stderr)).toBe("");
  });

  runForShell("bash", isBashAvailable)(
    "populates bash completions from the emitted script",
    async () => {
      const result = await runBashCompletion(["dotweave", "aut"], 1);

      expect(result.exitCode).toBe(0);
      expect(result.stdout.split("\n")).toContain("autocomplete ");
      expect(cleanShellStderr(result.stderr)).toBe("");
    },
  );

  runForShell("bash", isBashAvailable)(
    "offers root subcommands when bash completes the command token itself",
    async () => {
      const result = await runBashCompletion(["dotweave"], 0);

      expect(result.exitCode).toBe(0);
      expect(result.stdout.split("\n")).toEqual(
        expect.arrayContaining(bashRootCommandNames),
      );
    },
  );

  runForShell("bash", isBashAvailable)(
    "adds a trailing space for unique bash subcommand completions",
    async () => {
      const result = await runBashCompletion(["dotweave", "pro"], 1);

      expect(result.exitCode).toBe(0);
      expect(result.stdout.split("\n")).toContain("profile ");
      expect(cleanShellStderr(result.stderr)).toBe("");
    },
  );

  runForShell("bash", isBashAvailable)(
    "populates bash path completions for track targets",
    async () => {
      const result = await runBashCompletion(["dotweave", "track", "fi"], 2, {
        cwd: completionFixtureDirectory,
      });

      expect(result.exitCode).toBe(0);
      expect(result.stdout.split("\n")).toContain("file-alpha.txt ");
      expect(cleanShellStderr(result.stderr)).toBe("");
    },
  );

  runForShell("bash", isBashAvailable)(
    "populates bash flag completions after a track target",
    async () => {
      const result = await runBashCompletion(
        ["dotweave", "track", "file-alpha.txt", "-"],
        3,
        {
          cwd: completionFixtureDirectory,
        },
      );

      expect(result.exitCode).toBe(0);
      expect(result.stdout.split("\n")).toEqual(
        expect.arrayContaining(["--mode ", "--profile ", "--repo "]),
      );
    },
  );

  runForShell("zsh", isZshAvailable)(
    "adds a trailing space for unique zsh subcommand completions",
    async () => {
      const result = await runZshCompletion(["dotweave", "pro"], 2);

      expect(result.exitCode).toBe(0);
      expect(result.stdout.split("\n")).toContain("profile");
    },
  );

  runForShell("zsh", isZshAvailable)(
    "offers root subcommands when zsh completes the command token itself",
    async () => {
      const result = await runZshCompletion(["dotweave"], 1);

      expect(result.exitCode).toBe(0);
      expect(result.stdout.split("\n")).toEqual(
        expect.arrayContaining(rootCommandNames),
      );
    },
  );

  runForShell("fish", isFishAvailable)(
    "populates fish root completions from a prefix",
    async () => {
      requireSelectedShellAvailability("fish", isFishAvailable);

      const result = await runFishCompletion("dotweave pr");

      expect(result.exitCode).toBe(0);
      expect(completionNames(result.stdout)).toContain("profile");
      expect(cleanShellStderr(result.stderr)).toBe("");
    },
  );

  runForShell("fish", isFishAvailable)(
    "populates fish path completions for track targets",
    async () => {
      requireSelectedShellAvailability("fish", isFishAvailable);

      const result = await runFishCompletion("dotweave track fi", {
        cwd: completionFixtureDirectory,
      });

      expect(result.exitCode).toBe(0);
      expect(completionNames(result.stdout)).toContain("file-alpha.txt");
      expect(cleanShellStderr(result.stderr)).toBe("");
    },
  );

  runForShell("fish", isFishAvailable)(
    "populates fish flag completions after a track target",
    async () => {
      requireSelectedShellAvailability("fish", isFishAvailable);

      const result = await runFishCompletion(
        "dotweave track file-alpha.txt -",
        {
          cwd: completionFixtureDirectory,
        },
      );

      expect(result.exitCode).toBe(0);
      expect(completionNames(result.stdout)).toEqual(
        expect.arrayContaining(["--mode", "--profile", "--repo"]),
      );
      expect(cleanShellStderr(result.stderr)).toBe("");
    },
  );

  it("proposes root subcommands when COMP_LINE has a trailing space", async () => {
    const result = await runCli(["__complete", "dotweave", ""], {
      env: { COMP_LINE: "dotweave " },
    });

    expect(result.exitCode).toBe(0);
    expect(completionNames(result.stdout)).toEqual(
      expect.arrayContaining(rootCommandNames),
    );
    expect(cleanShellStderr(result.stderr)).toBe("");
  });

  it("proposes subcommand completions when COMP_LINE targets a command", async () => {
    const result = await runCli(["__complete", "dotweave", "track", ""], {
      env: { COMP_LINE: "dotweave track " },
      cwd: completionFixtureDirectory,
    });

    expect(result.exitCode).toBe(0);
    expect(completionNames(result.stdout)).toEqual(
      expect.arrayContaining(["--mode", "--profile", "--repo"]),
    );
    expect(cleanShellStderr(result.stderr)).toBe("");
  });

  runForShell("powershell", isPowerShellAvailable)(
    "populates PowerShell root completions from a prefix",
    async () => {
      requireSelectedShellAvailability("powershell", isPowerShellAvailable);

      const result = await runPowerShellCompletion("dotweave p");

      expect(result.exitCode).toBe(0);
      expect(powerShellLines(result.stdout)).toContain("profile");
      expect(cleanShellStderr(result.stderr)).toBe("");
    },
  );

  runForShell("powershell", isPowerShellAvailable)(
    "populates PowerShell subcommand completions from a prefix",
    async () => {
      requireSelectedShellAvailability("powershell", isPowerShellAvailable);

      const result = await runPowerShellCompletion("dotweave tr");

      expect(result.exitCode).toBe(0);
      expect(powerShellLines(result.stdout)).toContain("track");
      expect(cleanShellStderr(result.stderr)).toBe("");
    },
  );

  runForShell("powershell", isPowerShellAvailable)(
    "populates PowerShell path completions for track targets",
    async () => {
      requireSelectedShellAvailability("powershell", isPowerShellAvailable);

      const result = await runPowerShellCompletion("dotweave track fi", {
        cwd: completionFixtureDirectory,
      });

      expect(result.exitCode).toBe(0);
      expect(powerShellLines(result.stdout)).toContain("file-alpha.txt");
      expect(cleanShellStderr(result.stderr)).toBe("");
    },
  );

  runForShell("powershell", isPowerShellAvailable)(
    "populates PowerShell flag completions after a track target",
    async () => {
      requireSelectedShellAvailability("powershell", isPowerShellAvailable);

      const result = await runPowerShellCompletion(
        "dotweave track file-alpha.txt -",
        {
          cwd: completionFixtureDirectory,
        },
      );

      expect(result.exitCode).toBe(0);
      expect(powerShellLines(result.stdout)).toEqual(
        expect.arrayContaining(["--mode", "--profile", "--repo"]),
      );
      expect(cleanShellStderr(result.stderr)).toBe("");
    },
  );

  it("shows bash, zsh, fish, and PowerShell autocomplete subcommands", async () => {
    const result = await runCli(["autocomplete", "--help"]);

    expect(result.exitCode).toBe(0);
    expect(result.stdout).toContain("bash");
    expect(result.stdout).toContain("zsh");
    expect(result.stdout).toContain("fish");
    expect(result.stdout).toContain("powershell");
    expect(result.stdout).not.toContain("install");
    expect(result.stdout).not.toContain("uninstall");
    expect(cleanShellStderr(result.stderr)).toBe("");
  });
});
