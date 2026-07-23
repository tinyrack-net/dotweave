import { TRBadge } from "@tinyrack/ui/components/badge";
import { TRButton } from "@tinyrack/ui/components/button";
import { TRCodeBlock } from "@tinyrack/ui/components/code-block";
import { TRLink } from "@tinyrack/ui/components/link";

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
        <TRBadge variant="success">Dotweave v{__CLI_VERSION__}</TRBadge>
        <h1>{tagline}</h1>
        <p className="dotweave-home-copy">{body}</p>
        <div className="dotweave-home-actions">
          <TRButton
            render={<a href={getStartedPath} />}
            intent="primary"
            uiSize="lg"
          >
            {getStartedLabel}
          </TRButton>
          <TRLink href="https://github.com/tinyrack-net/dotweave">
            GitHub →
          </TRLink>
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
          <TRCodeBlock code={terminalSession} language="bash" />
        </section>
      </div>
    </section>
  );
}
