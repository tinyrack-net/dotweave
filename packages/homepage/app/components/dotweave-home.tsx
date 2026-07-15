import { Badge } from "@tinyrack/ui/components/badge";
import { Button } from "@tinyrack/ui/components/button";
import { CodeBlock } from "@tinyrack/ui/components/code-block";
import { Link } from "@tinyrack/ui/components/link";

import { GlobeBackground } from "./globe-background.tsx";

type DotweaveHomeProps = {
  body: string;
  getStartedLabel: string;
  getStartedPath: string;
  tagline: string;
};

const terminalSession = `❯ dotweave track ~/.zshrc ~/.gitconfig
✓ Tracking .zshrc .gitconfig

❯ dotweave push
✓ .zshrc .gitconfig .vimrc synced

❯ dotweave pull
✓ All configs restored

❯`;

export function DotweaveHome({
  body,
  getStartedLabel,
  getStartedPath,
  tagline,
}: DotweaveHomeProps) {
  return (
    <section className="dotweave-home">
      <GlobeBackground />
      <div className="dotweave-home-content">
        <Badge variant="success">Dotweave v{__CLI_VERSION__}</Badge>
        <h1>{tagline}</h1>
        <p className="dotweave-home-copy">{body}</p>
        <div className="dotweave-home-actions">
          <Button
            render={<a href={getStartedPath} />}
            size="lg"
            variant="primary"
          >
            {getStartedLabel}
          </Button>
          <Link href="https://github.com/tinyrack-net/dotweave">GitHub →</Link>
        </div>
        <section
          aria-label="Dotweave terminal example"
          className="dotweave-terminal"
        >
          <div aria-hidden="true" className="dotweave-terminal-header">
            <span />
            <span />
            <span />
          </div>
          <CodeBlock code={terminalSession} language="bash" />
        </section>
      </div>
    </section>
  );
}
