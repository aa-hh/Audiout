# Website privacy page: iPhone remote section (spec)

For whoever owns the website repo (`aa-hh/audiout-website`, local checkout
`~/Projects/Audiouter Website`). The page is `src/pages/privacy.astro`. Add one
new section and update the date constant; nothing else on the page changes. The
facts below come from the Mac repo's `PRODUCT.md`, section "Data Collection",
which is the source of truth if the two ever disagree.

## Where

A new `<h2>` section placed after the "Licence keys" section
(`privacy.astro:146`) and before the "Email" section (`:157`), using the same
`<h2>` plus `<p>` markup the file already uses for every other section.

## Exact text

`<h2>The iPhone remote</h2>`

Audiout Remote talks to your Mac directly over your own Wi-Fi. Nothing about
that connection reaches this site or any server of ours. The link is not
encrypted: the names of your speakers and of the apps currently playing, and the
ID the phone uses to identify itself to your Mac, cross your local network in
the clear, where any other device on the same network could read them. Audiout
treats your home network as trusted. The Mac app's "Allow control from iPhone on
this network" setting is on by default; a phone is only admitted after you click
Allow for it on the Mac. On a network you share with strangers, switch that
setting off in the Mac app's Settings under General.

## Also

Set `LAST_UPDATED` (`privacy.astro:37`, currently `"27 August 2026"`) to the date
this section goes live, in the same `"D Month YYYY"` format.

## Do not

No cookie, consent or GDPR legal-basis sentence for this section: no data
reaches a server, so there is no processing to give a basis for. Do not touch
any other section of the page.

## Retire when

Nothing here retires when the approval-secret fix designed in
`dev/notes/companion-approval-secret-brief.md` ships. That fix stops an ID
captured on its own from being admitted, but a device that records a whole
connection still sees everything and can still replay it, so every sentence above
stays true. The whole section only changes when the link itself is encrypted.
