import { describe, expect, it } from "vitest";
import {
  resultExitCode,
  runHomepageValidation,
  type ValidationTask,
  type ValidationTaskResult,
} from "../scripts/validate";

function deferredResult(task: ValidationTask) {
  let resolve!: (result: ValidationTaskResult) => void;
  const promise = new Promise<ValidationTaskResult>((complete) => {
    resolve = complete;
  });

  return {
    promise,
    complete(exitCode = 0, signal: NodeJS.Signals | null = null) {
      resolve({ task, exitCode: signal === null ? exitCode : null, signal });
    },
  };
}

async function flushTasks() {
  await new Promise<void>((resolve) => setImmediate(resolve));
}

describe("homepage validation scheduler", () => {
  it("overlaps independent checks and sequences typegen, tsc, and build", async () => {
    const started: string[] = [];
    const blockers = new Map<string, ReturnType<typeof deferredResult>>();

    const validation = runHomepageValidation({
      runner(task) {
        started.push(task.script);
        const blocker = deferredResult(task);
        blockers.set(task.script, blocker);
        return blocker.promise;
      },
      log() {},
    });

    await flushTasks();
    expect(started).toEqual(["format:check", "test", "typegen"]);
    expect(started).not.toContain("typecheck:tsc");

    blockers.get("typegen")?.complete();
    await flushTasks();
    expect(started).not.toContain("typecheck:tsc");

    blockers.get("format:check")?.complete();
    blockers.get("test")?.complete();
    await flushTasks();
    expect(started).toContain("typecheck:tsc");
    expect(started).not.toContain("build");

    blockers.get("typecheck:tsc")?.complete();
    await flushTasks();
    expect(started.at(-1)).toBe("build");

    blockers.get("build")?.complete();
    await expect(validation).resolves.toBe(0);
  });

  it("waits for running peers and skips dependent work after failure", async () => {
    const started: string[] = [];
    const blockers = new Map<string, ReturnType<typeof deferredResult>>();
    let finished = false;

    const validation = runHomepageValidation({
      runner(task) {
        started.push(task.script);
        const blocker = deferredResult(task);
        blockers.set(task.script, blocker);
        return blocker.promise;
      },
      log() {},
    }).then((exitCode) => {
      finished = true;
      return exitCode;
    });

    await flushTasks();
    blockers.get("format:check")?.complete(17);
    blockers.get("typegen")?.complete();
    await flushTasks();
    expect(finished).toBe(false);

    blockers.get("test")?.complete();
    await expect(validation).resolves.toBe(17);
    expect(started).toEqual(["format:check", "test", "typegen"]);
  });

  it("reports SIGSEGV as exit 139 without retrying the task", async () => {
    const calls = new Map<string, number>();
    const logs: string[] = [];

    const exitCode = await runHomepageValidation({
      async runner(task) {
        calls.set(task.script, (calls.get(task.script) ?? 0) + 1);
        if (task.script === "typegen") {
          return { task, exitCode: null, signal: "SIGSEGV" };
        }
        return { task, exitCode: 0, signal: null };
      },
      log(message) {
        logs.push(message);
      },
    });

    expect(exitCode).toBe(139);
    expect(calls.get("typegen")).toBe(1);
    expect(calls.has("typecheck:tsc")).toBe(false);
    expect(logs.join("\n")).toContain("route typegen");
    expect(logs.join("\n")).toContain("signal SIGSEGV, exit 139");
    expect(logs.join("\n")).toContain(`Node ${process.version}`);
  });

  it("maps process signals to conventional shell exit codes", () => {
    expect(
      resultExitCode({
        task: { name: "typegen", script: "typegen" },
        exitCode: null,
        signal: "SIGSEGV",
      }),
    ).toBe(139);
  });
});
