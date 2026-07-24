import { TRBadge } from "@tinyrack/ui/components/badge";
import { TRButton } from "@tinyrack/ui/components/button";
import { TRCodeBlock } from "@tinyrack/ui/components/code-block";
import { TRText } from "@tinyrack/ui/components/text";
import { TRWindowFrame } from "@tinyrack/ui/components/window-frame";

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
        <TRText as="h1" variant="display">
          {tagline}
        </TRText>
        <TRText
          as="p"
          className="dotweave-home-copy"
          color="muted"
          variant="body"
        >
          {body}
        </TRText>
        <div className="dotweave-home-actions">
          <TRButton
            render={<a href={getStartedPath} />}
            intent="primary"
            uiSize="sm"
          >
            {getStartedLabel}
          </TRButton>
          <TRButton
            render={<a href="https://github.com/tinyrack-net/dotweave" />}
            appearance="outline"
            uiSize="sm"
          >
            GitHub →
          </TRButton>
        </div>
        <TRWindowFrame.Root
          aria-label="Dotweave terminal example"
          className="dotweave-terminal"
          variant="macos"
        >
          <TRWindowFrame.TitleBar>
            <TRWindowFrame.Controls aria-hidden="true">
              <TRWindowFrame.Control tone="close" />
              <TRWindowFrame.Control tone="minimize" />
              <TRWindowFrame.Control tone="maximize" />
            </TRWindowFrame.Controls>
            <TRWindowFrame.Title>dotweave</TRWindowFrame.Title>
          </TRWindowFrame.TitleBar>
          <TRWindowFrame.Body padding="none">
            <TRCodeBlock code={terminalSession} language="bash" />
          </TRWindowFrame.Body>
        </TRWindowFrame.Root>
      </div>
    </section>
  );
}
