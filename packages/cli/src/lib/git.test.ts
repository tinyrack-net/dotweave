import { EventEmitter } from "node:events";
import { rm, writeFile } from "node:fs/promises";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";
import { DotweaveError } from "#app/lib/error.ts";
import {
  initializeRepository,
  requireGitRepository,
  runGitCommandWithDependencies,
  runStreamingGitCommandWithDependencies,
  verifyIsGitRepository,
} from "#app/lib/git.ts";
import {
  createTemporaryDirectory,
  runGit,
} from "../test/helpers/sync-fixture.ts";

const temporaryDirectories: string[] = [];

const createWorkspace = async () => {
  const directory = await createTemporaryDirectory("dotweave-git-");

  temporaryDirectories.push(directory);

  return directory;
};

const createGitError = (
  message: string,
  output: Readonly<{ stderr?: string; stdout?: string }> = {},
) => {
  const error = new Error(message) as Error & {
    stderr?: string;
    stdout?: string;
  };

  error.stderr = output.stderr;
  error.stdout = output.stdout;

  return error;
};

const createEnoentError = () => {
  const error = new Error("spawn git ENOENT") as Error & { code: string };

  error.code = "ENOENT";

  return error;
};

const createStreamingChild = () => {
  const child = new EventEmitter() as EventEmitter & {
    stderr: EventEmitter & { setEncoding: (encoding: BufferEncoding) => void };
    stdout: EventEmitter & { setEncoding: (encoding: BufferEncoding) => void };
  };

  child.stderr = new EventEmitter() as EventEmitter & {
    setEncoding: (encoding: BufferEncoding) => void;
  };
  child.stdout = new EventEmitter() as EventEmitter & {
    setEncoding: (encoding: BufferEncoding) => void;
  };
  child.stderr.setEncoding = () => {};
  child.stdout.setEncoding = () => {};

  return child;
};

afterEach(async () => {
  while (temporaryDirectories.length > 0) {
    const directory = temporaryDirectories.pop();

    if (directory !== undefined) {
      await rm(directory, { force: true, recursive: true });
    }
  }
});

describe("git helpers", () => {
  describe("runGitCommandWithDependencies", () => {
    it("uses trimmed stderr before stdout or error message", async () => {
      await expect(
        runGitCommandWithDependencies(["status"], undefined, {
          execFileAsync: async () => {
            throw createGitError("fallback message", {
              stderr: "  fatal from stderr\n",
              stdout: "stdout message",
            });
          },
        }),
      ).rejects.toThrow("fatal from stderr");
    });

    it("uses stdout when stderr is empty", async () => {
      await expect(
        runGitCommandWithDependencies(["status"], undefined, {
          execFileAsync: async () => {
            throw createGitError("fallback message", {
              stderr: "  \n",
              stdout: " stdout message\n",
            });
          },
        }),
      ).rejects.toThrow("stdout message");
    });

    it("uses the error message when stderr and stdout are empty", async () => {
      await expect(
        runGitCommandWithDependencies(["status"], undefined, {
          execFileAsync: async () => {
            throw createGitError("fallback message", {
              stderr: "",
              stdout: "",
            });
          },
        }),
      ).rejects.toThrow("fallback message");
    });

    it("uses a stable fallback when a non-Error value is thrown", async () => {
      await expect(
        runGitCommandWithDependencies(["status"], undefined, {
          execFileAsync: async () => {
            throw "boom";
          },
        }),
      ).rejects.toThrow("git failed.");
    });

    it("reports a missing git executable from execFile", async () => {
      await expect(
        runGitCommandWithDependencies(["status"], undefined, {
          execFileAsync: async () => {
            throw createEnoentError();
          },
        }),
      ).rejects.toMatchObject({
        code: "GIT_EXECUTABLE_NOT_FOUND",
        hint: expect.stringContaining("PATH"),
        message: "Git is not installed or not on PATH.",
      });
    });
  });

  describe("runStreamingGitCommandWithDependencies", () => {
    it("rejects when the child process emits an error", async () => {
      const child = createStreamingChild();

      setTimeout(() => {
        child.emit("error", new Error("spawn failed"));
      }, 0);

      await expect(
        runStreamingGitCommandWithDependencies(["status"], undefined, {
          spawnGit: () => child,
        }),
      ).rejects.toThrow("spawn failed");
    });

    it("reports a missing git executable from spawn", async () => {
      const child = createStreamingChild();

      setTimeout(() => {
        child.emit("error", createEnoentError());
      }, 0);

      await expect(
        runStreamingGitCommandWithDependencies(["status"], undefined, {
          spawnGit: () => child,
        }),
      ).rejects.toMatchObject({
        code: "GIT_EXECUTABLE_NOT_FOUND",
        hint: expect.stringContaining("PATH"),
        message: "Git is not installed or not on PATH.",
      });
    });

    it("reports an unknown code when the child process closes without a code", async () => {
      const child = createStreamingChild();

      setTimeout(() => {
        child.emit("close", null);
      }, 0);

      await expect(
        runStreamingGitCommandWithDependencies(["status"], undefined, {
          spawnGit: () => child,
        }),
      ).rejects.toThrow("git exited with code unknown.");
    });

    it("uses stderr before stdout when the child process exits non-zero", async () => {
      const child = createStreamingChild();

      setTimeout(() => {
        child.stdout.emit("data", "stdout message\n");
        child.stderr.emit("data", "stderr message\n");
        child.emit("close", 2);
      }, 0);

      await expect(
        runStreamingGitCommandWithDependencies(["status"], undefined, {
          spawnGit: () => child,
        }),
      ).rejects.toThrow("stderr message");
    });
  });

  it("initializes a repository with a main branch", async () => {
    const workspace = await createWorkspace();
    const repositoryPath = join(workspace, "sync");

    await expect(initializeRepository(repositoryPath)).resolves.toEqual({
      action: "initialized",
    });
    await expect(
      verifyIsGitRepository(repositoryPath),
    ).resolves.toBeUndefined();
    await expect(
      runGit(["-C", repositoryPath, "symbolic-ref", "--short", "HEAD"]),
    ).resolves.toMatchObject({
      stdout: "main\n",
    });
  });

  it("clones an existing repository and reports the source", async () => {
    const workspace = await createWorkspace();
    const sourcePath = join(workspace, "source");
    const targetPath = join(workspace, "clone");

    await runGit(["init", "-b", "main", sourcePath], workspace);

    await expect(initializeRepository(targetPath, sourcePath)).resolves.toEqual(
      {
        action: "cloned",
        source: sourcePath,
      },
    );
    await expect(verifyIsGitRepository(targetPath)).resolves.toBeUndefined();
  });

  it("wraps missing git repositories in a DotweaveError", async () => {
    const workspace = await createWorkspace();
    const missingRepositoryPath = join(workspace, "not-a-repo");

    await expect(
      verifyIsGitRepository(missingRepositoryPath),
    ).rejects.toThrowError();
    await expect(
      requireGitRepository(missingRepositoryPath),
    ).rejects.toThrowError(DotweaveError);
    await expect(
      requireGitRepository(missingRepositoryPath),
    ).rejects.toThrowError(/Sync repository is not initialized/u);
  });

  it("fails to initialize a repository in a non-writable location", async () => {
    const workspace = await createWorkspace();
    const fileParentPath = join(workspace, "not-a-directory");

    await writeFile(fileParentPath, "not a directory");

    await expect(
      initializeRepository(join(fileParentPath, "repo")),
    ).rejects.toThrow();
  });
});
