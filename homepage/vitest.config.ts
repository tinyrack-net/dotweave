import { defineConfig } from "vitest/config";

// Unit tests do not need the React Router Vite plugins. Keeping this config
// separate prevents Vitest and the explicit typegen task from concurrently
// rewriting .react-router/types.
export default defineConfig({});
