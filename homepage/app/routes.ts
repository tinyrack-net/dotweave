import { resolve } from "node:path";

import { createDocsRoutes } from "@tinyrack/docs/react-router";

import config from "../docs.config.ts";

export default createDocsRoutes(config, {
  root: resolve(import.meta.dirname, ".."),
});
