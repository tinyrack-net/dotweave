/// <reference types="vite/client" />

declare const __CLI_VERSION__: string;

declare module "*.mdx" {
  import type { JSX } from "react";

  export default function MdxContent(
    props: Record<string, unknown>,
  ): JSX.Element;
}
