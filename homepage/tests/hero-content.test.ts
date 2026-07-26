import { describe, expect, it } from "vitest";

import {
  installTargets,
  terminalSteps,
} from "../app/components/dotweave-hero-content.ts";

describe("Dotweave hero content", () => {
  it("keeps the transcript within the staggered reveal budget", () => {
    // app.css declares animation-delay for .dotweave-terminal-step:nth-child(2)
    // through :nth-child(5) only. A sixth step would replay on top of the first
    // with no delay, and nothing else would catch it.
    expect(terminalSteps.length).toBeGreaterThan(0);
    expect(terminalSteps.length).toBeLessThanOrEqual(5);
  });

  it("renders every step as a prompt line followed by CLI output", () => {
    for (const step of terminalSteps) {
      expect(step.startsWith("❯ dotweave ")).toBe(true);
      // U+2714, the mark the CLI actually prints — not the lighter U+2713.
      expect(step).toContain("\n✔ ");
    }
  });

  it("uses unique step strings so React keys stay stable", () => {
    expect(new Set(terminalSteps).size).toBe(terminalSteps.length);
  });

  it("publishes the documented install commands", () => {
    expect(installTargets.map((target) => target.command)).toEqual([
      "winget install tinyrack.dotweave",
      "brew install tinyrack-net/tap/dotweave",
    ]);
    expect(new Set(installTargets.map((target) => target.value)).size).toBe(
      installTargets.length,
    );
  });
});
