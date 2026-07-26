import { TRBadge } from "@tinyrack/ui/components/badge";
import { TRButton } from "@tinyrack/ui/components/button";
import { TRCodeBlock } from "@tinyrack/ui/components/code-block";
import { TRCopyButton } from "@tinyrack/ui/components/copy-button";
import { TRTabs } from "@tinyrack/ui/components/tabs";
import { TRText } from "@tinyrack/ui/components/text";
import { TRWindowFrame } from "@tinyrack/ui/components/window-frame";

import { installTargets, terminalSteps } from "./dotweave-hero-content.ts";
import { GlobeBackground } from "./globe-background.tsx";

type DotweaveHomeProps = {
  body: string;
  features: readonly string[];
  getStartedLabel: string;
  getStartedPath: string;
  installLabel: string;
  tagline: string;
  terminalLabel: string;
};

export function DotweaveHome({
  body,
  features,
  getStartedLabel,
  getStartedPath,
  installLabel,
  tagline,
  terminalLabel,
}: DotweaveHomeProps) {
  return (
    <section className="dotweave-home">
      <GlobeBackground />
      <div className="dotweave-home-content">
        <div className="dotweave-home-lede">
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
          <ul className="dotweave-features">
            {features.map((feature) => (
              <li key={feature}>
                <TRBadge uiSize="sm" variant="neutral">
                  {feature}
                </TRBadge>
              </li>
            ))}
          </ul>
          <div className="dotweave-home-actions">
            <TRButton
              render={<a href={getStartedPath} />}
              intent="primary"
              uiSize="md"
            >
              {getStartedLabel}
            </TRButton>
            <TRButton
              render={<a href="https://github.com/tinyrack-net/dotweave" />}
              appearance="outline"
              uiSize="md"
            >
              GitHub →
            </TRButton>
          </div>
          <TRTabs.Root
            className="dotweave-install"
            defaultValue={installTargets[0].value}
            uiSize="sm"
          >
            <TRTabs.List aria-label={installLabel}>
              {installTargets.map((target) => (
                <TRTabs.Tab key={target.value} value={target.value}>
                  {target.label}
                </TRTabs.Tab>
              ))}
              <TRTabs.Indicator />
            </TRTabs.List>
            {installTargets.map((target) => (
              <TRTabs.Panel key={target.value} value={target.value}>
                <div className="dotweave-install-command">
                  <TRCodeBlock code={target.command} language="bash" />
                  <TRCopyButton
                    appearance="ghost"
                    uiSize="sm"
                    value={target.command}
                  />
                </div>
              </TRTabs.Panel>
            ))}
          </TRTabs.Root>
        </div>

        <TRWindowFrame.Root
          aria-label={terminalLabel}
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
            <div className="dotweave-terminal-transcript">
              {terminalSteps.map((step) => (
                <div className="dotweave-terminal-step" key={step}>
                  <TRCodeBlock code={step} language="bash" />
                </div>
              ))}
              <span aria-hidden="true" className="dotweave-terminal-caret" />
            </div>
          </TRWindowFrame.Body>
        </TRWindowFrame.Root>
      </div>
    </section>
  );
}
