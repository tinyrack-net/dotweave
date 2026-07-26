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

/** Transcribed from a real session. Keep it in step with the CLI's output. */
const terminalSession = `❯ dotweave track ~/.gitconfig
✔ Started tracking .gitconfig
  kind  file
  path  /home/you/.gitconfig
  repo  .gitconfig
  mode  normal

❯ dotweave push
✔ Push complete
  plain: 2
  encrypted: 1
  symlinks: 0
  dirs: 1

❯ dotweave pull
✔ Pull complete
  updated: 1 paths updated
  removed: 0 paths removed

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
