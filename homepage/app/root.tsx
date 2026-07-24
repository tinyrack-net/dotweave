import "./styles/app.css";

import { meta as docsMeta, Layout, links } from "@tinyrack/docs/runtime";
import type { MetaFunction } from "react-router";

export { default } from "@tinyrack/docs/runtime";
export { Layout, links };

export const meta: MetaFunction = (args) => [
  ...(docsMeta(args) ?? []),
  {
    content: "-4detF9HYfr_TzkI1CzY4aZS7DuiYM6wR7U9YY2-jKw",
    name: "google-site-verification",
  },
];
