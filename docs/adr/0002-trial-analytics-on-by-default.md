# Analytics collection during the trial defaults on, not off

Decided 2026-09-12. During the free trial, and before it — first launch, the licence gate showing — analytics collection is on by default with no ask. This is disclosed in the website privacy policy and can be switched off in Settings ("Share anonymous usage statistics") at any time; an explicit off sticks. Once a user pays, they get a choice: a direct buyer sees the onboarding consent card (the usage-stats step) as before; someone converting from the trial gets a one-time popover right after the paid key is accepted. Declining after conversion keeps the trial data already collected and stops collection going forward.

The prior design asked for consent on the last card of onboarding, so anyone who abandoned setup before reaching it sent nothing, ever — the data that came back was survivor-only. Trial-phase visibility (onboarding drop-off per step, engagement leading to conversion) is worth more than an opt-in ask that almost nobody answers. This also matches the iPhone companion app's existing opt-out posture. The data collected is already minimized: no device names or identifiers, bucketed values, hosted in the EU, and coarse geoip on one event per launch only.

## Considered options

- Ask everyone for opt-in consent, as the prior design did. Rejected: produces survivor-only data, since the only people who reach the consent card are the ones who finished onboarding.
- Server-side anonymous step pings instead of a client default. Rejected: redundant once the client defaults to on, and adds server plumbing for no gain.
- The chosen model: on by default pre-purchase, switchable off any time, with an explicit choice offered after payment.

## Consequences

- The website privacy policy needs to state the trial default. Not part of this change — owed as follow-up in the website repo.
- `docs/analytics-events.md` in `audiout-shared` needs to describe the consent asymmetry: Mac defaults on during trial then asks after payment; phone is opt-out throughout.
- `PRODUCT.md`'s "opt-in, off by default" line is updated in the same change as this ADR.
