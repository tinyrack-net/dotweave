import { chmod, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { rootCommandRoutes } from "../src/cli/root-commands.ts";
import { cliNodeOptions } from "../src/test/helpers/cli-entry.ts";
import { createPtySession, type PtySession } from "../src/test/helpers/pty.ts";
import {
  bashPath,
  fishPath,
  isBashAvailable,
  isFishAvailable,
  isPowerShellAvailable,
  isZshAvailable,
  powerShellPath,
  zshPath,
} from "../src/test/helpers/shell-availability.ts";

const rootCommandNames = ["autocomplete", ...Object.keys(rootCommandRoutes)];
const autocompleteEnvironment: NodeJS.ProcessEnv & {
  DOTWEAVE_AUTOCOMPLETE_SHELL?: string;
} = process.env;
const selectedAutocompleteShell =
  autocompleteEnvironment.DOTWEAVE_AUTOCOMPLETE_SHELL;
const ptyRootSmokeCommandNames = ["autocomplete", "profile", "status"] as const;
type PtyAutocompleteShell = "bash" | "zsh" | "fish" | "powershell";

const shouldRunPtyShell = (shell: PtyAutocompleteShell, available: boolean) => {
  if (
    selectedAutocompleteShell !== undefined &&
    selectedAutocompleteShell !== shell
  ) {
    return false;
  }

  if (shell === "powershell") {
    return (
      process.platform === "win32" &&
      (selectedAutocompleteShell === shell || available)
    );
  }

  if (process.platform === "win32") {
    return false;
  }

  return selectedAutocompleteShell === shell || available;
};

const requireSelectedPtyShellAvailability = (
  shell: PtyAutocompleteShell,
  available: boolean,
) => {
  if (selectedAutocompleteShell === shell) {
    expect(
      available,
      `${shell} must be available for selected autocomplete CI shell`,
    ).toBe(true);
  }
};

const shellQuote = (value: string) => {
  return `'${value.replaceAll("'", "'\\''")}'`;
};

const waitForPtyRootSmokeCommands = (session: PtySession) => {
  return session.waitForOutput((output) => {
    return ptyRootSmokeCommandNames.every((commandName) =>
      output.includes(commandName),
    );
  }, 10_000);
};

const createTestShellDirectory = async (
  rcLines: readonly string[],
  rcFileName: string,
): Promise<{ binDirectory: string; configDirectory: string }> => {
  const configDirectory = await mkdtemp(
    join(tmpdir(), "dotweave-autocomplete-pty-"),
  );
  const binDirectory = join(configDirectory, "bin");

  await mkdir(binDirectory, { recursive: true });

  const cliCommand = [process.execPath, ...cliNodeOptions]
    .map((value) => shellQuote(value))
    .join(" ");

  await writeFile(
    join(binDirectory, "dotweave"),
    ["#!/usr/bin/env bash", `exec ${cliCommand} "$@"`].join("\n"),
  );
  await chmod(join(binDirectory, "dotweave"), 0o755);

  await writeFile(join(configDirectory, rcFileName), rcLines.join("\n"));

  return { binDirectory, configDirectory };
};

const createPowerShellPtyDirectory = async () => {
  const configDirectory = await mkdtemp(
    join(tmpdir(), "dotweave-autocomplete-powershell-pty-"),
  );
  const binDirectory = join(configDirectory, "bin");
  const cliArgs = cliNodeOptions
    .map((value) => JSON.stringify(value))
    .join(" ");

  await mkdir(binDirectory, { recursive: true });
  await writeFile(
    join(binDirectory, "dotweave.cmd"),
    [`@echo off`, `"${process.execPath}" ${cliArgs} %*`].join("\r\n"),
  );

  return { binDirectory, configDirectory };
};

describe.skipIf(!shouldRunPtyShell("fish", isFishAvailable))(
  "autocomplete fish pty e2e",
  () => {
    let fishBinDirectory: string;
    let fishConfigRoot: string;
    let fishFixtureDirectory: string;
    let systemPath: string;

    beforeAll(async () => {
      requireSelectedPtyShellAvailability("fish", isFishAvailable);

      const { PATH: inheritedPath = "" } = process.env;

      systemPath = inheritedPath;

      const { binDirectory, configDirectory } = await createTestShellDirectory(
        [],
        ".fish-placeholder",
      );
      const fishConfigDirectory = join(configDirectory, "fish");

      await mkdir(fishConfigDirectory, { recursive: true });
      await writeFile(
        join(fishConfigDirectory, "config.fish"),
        [
          "function fish_prompt; printf 'PROMPT> '; end",
          "dotweave autocomplete fish | source",
        ].join("\n"),
      );

      fishBinDirectory = binDirectory;
      fishConfigRoot = configDirectory;
      fishFixtureDirectory = await mkdtemp(
        join(tmpdir(), "dotweave-autocomplete-fish-pty-"),
      );
      await writeFile(join(fishFixtureDirectory, "file-alpha.txt"), "");
    });

    afterAll(async () => {
      await rm(fishConfigRoot, {
        force: true,
        recursive: true,
      });
      await rm(fishFixtureDirectory, {
        force: true,
        recursive: true,
      });
    });

    const createFishSession = () => {
      return createPtySession({
        args: ["--features", "no-query-term", "--interactive"],
        cwd: fishFixtureDirectory,
        env: {
          FORCE_COLOR: "0",
          NODE_NO_WARNINGS: "1",
          NO_COLOR: "1",
          PATH: [fishBinDirectory, systemPath].join(delimiter),
          XDG_CONFIG_HOME: fishConfigRoot,
        },
        file: fishPath ?? "fish",
      });
    };

    it("completes a root subcommand in interactive fish", async () => {
      const session = createFishSession();

      try {
        await session.waitFor("PROMPT> ");

        session.write("dotweave p\t");

        const output = await session.waitFor("profile", 10_000);

        expect(output).toContain("profile");
      } finally {
        session.close();
      }
    }, 15_000);
  },
);

describe.skipIf(!shouldRunPtyShell("zsh", isZshAvailable))(
  "autocomplete zsh pty e2e",
  () => {
    let shellConfigDirectory: string;
    let shellBinDirectory: string;
    let systemPath: string;

    beforeAll(async () => {
      requireSelectedPtyShellAvailability("zsh", isZshAvailable);

      const { PATH: inheritedPath = "" } = process.env;

      systemPath = inheritedPath;

      const { binDirectory, configDirectory } = await createTestShellDirectory(
        [
          "autoload -Uz compinit",
          "zmodload zsh/complist",
          "zstyle ':completion:*' list-colors ''",
          "zstyle ':completion:*' menu no",
          "PROMPT='PROMPT> '",
          'eval "$(dotweave autocomplete zsh)"',
        ],
        ".zshrc",
      );
      shellBinDirectory = binDirectory;
      shellConfigDirectory = configDirectory;
    });

    afterAll(async () => {
      await rm(shellConfigDirectory, {
        force: true,
        recursive: true,
      });
    });

    const createZshSession = (
      options?: Readonly<{
        binDirectory?: string;
        configDirectory?: string;
      }>,
    ) => {
      return createPtySession({
        args: ["-f", "-i"],
        cwd: process.cwd(),
        env: {
          FORCE_COLOR: "0",
          NODE_NO_WARNINGS: "1",
          NO_COLOR: "1",
          PATH: [options?.binDirectory ?? shellBinDirectory, systemPath].join(
            delimiter,
          ),
          ZDOTDIR: options?.configDirectory ?? shellConfigDirectory,
        },
        file: zshPath ?? "zsh",
      });
    };

    const sourceZshConfig = async (
      session: ReturnType<typeof createZshSession>,
    ) => {
      session.write(
        `source ${shellQuote(join(shellConfigDirectory, ".zshrc"))}\r`,
      );
      await session.waitFor("PROMPT> ", 10_000);
      session.clearOutput();
    };

    it("lists root subcommands in interactive zsh after dotweave tab tab", async () => {
      const session = createZshSession();

      try {
        await sourceZshConfig(session);

        session.write("dotweave \t\t");

        const output = await waitForPtyRootSmokeCommands(session);

        for (const commandName of ptyRootSmokeCommandNames) {
          expect(output).toContain(commandName);
        }
      } finally {
        session.close();
      }
    }, 15_000);

    it("still lists root subcommands after running dotweave once in zsh", async () => {
      const session = createZshSession();

      try {
        await sourceZshConfig(session);

        session.write("dotweave\n");
        await session.waitFor("COMMANDS");
        await session.waitFor(/PROMPT> $/mu);

        session.clearOutput();

        session.write("dotweave \t\t");

        const output = await waitForPtyRootSmokeCommands(session);

        for (const commandName of ptyRootSmokeCommandNames) {
          expect(output).toContain(commandName);
        }
      } finally {
        session.close();
      }
    }, 15_000);
  },
);

describe.skipIf(!shouldRunPtyShell("bash", isBashAvailable))(
  "autocomplete bash pty e2e",
  () => {
    let bashBinDirectory: string;
    let bashConfigDirectory: string;
    let systemPath: string;

    beforeAll(async () => {
      requireSelectedPtyShellAvailability("bash", isBashAvailable);

      const { PATH: inheritedPath = "" } = process.env;

      systemPath = inheritedPath;

      const { binDirectory, configDirectory } = await createTestShellDirectory(
        ['eval "$(dotweave autocomplete bash)"', "PS1='PROMPT> '"],
        ".bashrc",
      );

      bashBinDirectory = binDirectory;
      bashConfigDirectory = configDirectory;
    });

    afterAll(async () => {
      await rm(bashConfigDirectory, {
        force: true,
        recursive: true,
      });
    });

    const createBashSession = () => {
      return createPtySession({
        args: ["--rcfile", join(bashConfigDirectory, ".bashrc"), "-i"],
        cwd: process.cwd(),
        env: {
          FORCE_COLOR: "0",
          NODE_NO_WARNINGS: "1",
          NO_COLOR: "1",
          PATH: [bashBinDirectory, systemPath].join(delimiter),
        },
        file: bashPath ?? "bash",
      });
    };

    it("lists root subcommands in interactive bash", async () => {
      const session = createBashSession();

      try {
        await session.waitFor("PROMPT> ");

        session.write("dotweave \t\t");

        for (const commandName of rootCommandNames) {
          await session.waitFor(commandName, 10_000);
        }

        const output = session.getOutput();

        for (const commandName of ptyRootSmokeCommandNames) {
          expect(output).toContain(commandName);
        }
      } finally {
        session.close();
      }
    }, 15_000);

    it("still lists root subcommands after running dotweave once in bash", async () => {
      const session = createBashSession();

      try {
        await session.waitFor("PROMPT> ");

        session.write("dotweave\n");
        await session.waitFor("COMMANDS");
        await session.waitFor(/PROMPT> $/mu);

        session.clearOutput();

        session.write("dotweave \t\t");

        for (const commandName of rootCommandNames) {
          await session.waitFor(commandName, 10_000);
        }

        const output = session.getOutput();

        for (const commandName of ptyRootSmokeCommandNames) {
          expect(output).toContain(commandName);
        }
        expect(output).not.toContain("AGENTS.md");
        expect(output).not.toContain("package.json");
      } finally {
        session.close();
      }
    }, 15_000);
  },
);

describe.skipIf(!shouldRunPtyShell("powershell", isPowerShellAvailable))(
  "autocomplete powershell pty e2e",
  () => {
    let powerShellBinDirectory: string;
    let powerShellConfigDirectory: string;
    let powerShellFixtureDirectory: string;
    let systemPath: string;

    beforeAll(async () => {
      requireSelectedPtyShellAvailability("powershell", isPowerShellAvailable);

      const { PATH: inheritedPath = "" } = process.env;

      systemPath = inheritedPath;

      const { binDirectory, configDirectory } =
        await createPowerShellPtyDirectory();

      powerShellBinDirectory = binDirectory;
      powerShellConfigDirectory = configDirectory;
      powerShellFixtureDirectory = await mkdtemp(
        join(tmpdir(), "dotweave-autocomplete-powershell-pty-fixture-"),
      );
      await writeFile(join(powerShellFixtureDirectory, "file-alpha.txt"), "");
    });

    afterAll(async () => {
      await rm(powerShellConfigDirectory, {
        force: true,
        recursive: true,
      });
      await rm(powerShellFixtureDirectory, {
        force: true,
        recursive: true,
      });
    });

    const createPowerShellSession = () => {
      return createPtySession({
        args: ["-NoLogo", "-NoProfile", "-NoExit"],
        cwd: powerShellFixtureDirectory,
        env: {
          FORCE_COLOR: "0",
          NODE_NO_WARNINGS: "1",
          NO_COLOR: "1",
          PATH: [powerShellBinDirectory, systemPath].join(delimiter),
        },
        file: powerShellPath ?? "pwsh",
      });
    };

    const configurePowerShellSession = async (
      session: ReturnType<typeof createPowerShellSession>,
    ) => {
      session.write(
        `${[
          "$ErrorActionPreference = 'Stop'",
          "Set-PSReadLineOption -PredictionSource None",
          "Set-PSReadLineOption -EditMode Windows",
          "function global:prompt { 'PROMPT> ' }",
          ". ([scriptblock]::Create(((dotweave autocomplete powershell) -join [Environment]::NewLine)))",
        ].join("; ")}\r`,
      );
      await session.waitFor("PROMPT> ", 15_000);
      session.clearOutput();
    };

    it("lists root subcommands in interactive PowerShell", async () => {
      const session = createPowerShellSession();

      try {
        await configurePowerShellSession(session);

        session.write("dotweave p\t");

        const output = await session.waitFor("profile", 10_000);

        expect(output).toContain("profile");
      } finally {
        session.close();
        await session.waitForExit();
      }
    }, 20_000);
  },
);
