import { readFileSync } from "node:fs";

import { tinyrackDocs } from "@tinyrack/docs/vite";
import { defineConfig } from "vite";

import config from "./docs.config.ts";

const cliPackage = JSON.parse(
  readFileSync(new URL("../cli/package.json", import.meta.url), "utf8"),
) as { version: string };

export default defineConfig({
  define: { __CLI_VERSION__: JSON.stringify(cliPackage.version) },
  plugins: tinyrackDocs(config, { root: import.meta.dirname }),
  server: { allowedHosts: true, host: "0.0.0.0", port: 5432, strictPort: true },
});
