import { resolve } from "node:path";
import { defineConfig } from "vitest/config";

export default defineConfig({
  resolve: {
    alias: {
      "#app": resolve(import.meta.dirname, "src"),
      "#test": resolve(import.meta.dirname, "src/test"),
    },
  },
  test: {
    testTimeout: 30000,
    environment: "node",
    include: ["src/**/*.test.ts", "tests/**/*.e2e.test.ts"],
    coverage: {
      exclude: ["src/**/*.test.ts", "src/test/**", "src/index.ts"],
      include: ["src/**/*.ts"],
      provider: "v8",
      reporter: ["text", "lcov"],
      thresholds: {
        branches: 80,
        functions: 95,
        lines: 84,
        statements: 84,
      },
    },
  },
});
