import tailwindcss from "@tailwindcss/vite";
import { tinyrackDocs } from "@tinyrack/docs/vite";
import { defineConfig } from "vite";

import { cliVersion } from "./cli-version.ts";
import config from "./docs.config.ts";

export default defineConfig({
  define: { __CLI_VERSION__: JSON.stringify(cliVersion) },
  plugins: [
    ...tinyrackDocs(config, { root: import.meta.dirname }),
    tailwindcss(),
  ],
  server: { allowedHosts: true, host: "0.0.0.0", port: 5432, strictPort: true },
});
