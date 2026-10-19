# Trial-end conversion: what the published evidence says (2026-09-26)

Question: for a €30 one-time-purchase macOS menu-bar app with a 14-day, no-email trial, what does published evidence say about the moment the trial ends, and does it favour a hard wall or a "keep running, limited, keep reminding" model?

Short answer: almost no published evidence covers one-time-purchase desktop apps. Most numbers come from mobile subscriptions (RevenueCat, Adapty) or business software sold by subscription (ChartMogul, Totango, OpenView). No source compares a Mac app that stops at expiry with one that keeps running. Where a number could not be found, this note says so.

## 1. Trial-end paywall design

**Primary button (Buy vs Enter key).** No published A/B test found. The common mobile pattern puts buying as the main button and "Restore purchases" as a small secondary link; Lazyweb counted restore links as 18.9% of 597 secondary paywall buttons across 43 companies, which describes practice, not a measured effect ([Lazyweb](https://www.lazyweb.com/research/how-common-restore-link-mobile-paywalls)).

**Price and honesty on screen.** Blinkist's trial screen test replaced feature lists with a plain statement of what happens and when (a reminder before billing, no hidden close button, no fine print). Result: 23% more trial starts, notification opt-in up from 6% to 74%, 55% fewer complaints ([Jaycee Day, UX Planet](https://uxplanet.org/how-solving-our-biggest-customer-complaint-at-blinkist-led-to-a-23-increase-in-conversion-b60ad514134b); [Growth.Design write-up](https://growth.design/case-studies/trial-paywall-challenge)). This measured trial starts at the front, not purchases at expiry. No published test found on showing the price vs hiding it on a trial-expired screen.

**Showing the user's own usage or what they will lose.** No published A/B test with numbers found. Vendor blogs recommend it without data.

**Urgency and discounts.** Adapty reports that a 24-hour discount shown only to people who closed the paywall without buying typically adds 10 to 15% revenue per user, and that pricing tests move results 2 to 3 times more than visual tests ([Adapty playbook](https://adapty.io/blog/paywall-experiments-playbook/)). These are subscription apps with many price tiers; transfer to a single €30 price is untested. Some indie developers refuse discounts on principle: Kapeli (Dash) says discounts are unfair to people who paid full price ([Kapeli on X](https://x.com/kapeli/status/1200126176678830089)).

**How many actions.** No published data found.

What this means for a no-email, one-time-purchase menu-bar app: there is no evidence either way on Buy vs Enter key; the only measured result that touches this screen type (Blinkist) rewards plain, honest wording about what happens next. A discount test is the one lever with vendor numbers behind it, all from subscriptions.

## 2. Hard wall vs degraded mode vs unlimited reminders

**Mobile subscriptions.** RevenueCat's 2026 report: apps that block use until payment convert a median 10.7% of users by day 35, against 2.1% for apps with a free tier, and one-year retention is the same (27% vs 28%). Apps with a free tier "continue to convert well into Week 6 and beyond" ([RevenueCat 2026](https://www.revenuecat.com/blog/growth/subscription-app-trends-benchmarks-2026)). This compares blocking at install with a free tier, not blocking at trial end.

**Desktop precedents, no numbers.** Rogue Amoeba (the closest match: Mac audio utilities) has no day limit at all; every app works fully but overlays noise after 10 or 20 minutes of use, and relaunching resets the timer ([Rogue Amoeba support](https://rogueamoeba.com/support/knowledgebase/?showArticle=Misc-AboutAppTrials&product=General)). Sublime Text runs forever with an occasional purchase popup ([Wikipedia](https://en.wikipedia.org/wiki/Sublime_Text)). Bartender (a menu-bar app) asks for purchase after a 4-week trial ([Bartender](https://www.macbartender.com/Bartender4/)). None of these companies has published conversion numbers. Searches for Sublime, Dash and WinRAR conversion rates found nothing.

**Reverse trial** (full features for a time, then drop to a free tier). Elena Verna reports it raised free-to-paid conversion by 10 to 40% in her work, without naming companies or sample sizes ([CXL](https://cxl.com/blog/reverse-trial-strategy/); the page blocked direct reading, so the figure comes from a search summary; her [Amplitude post](https://amplitude.com/blog/reverse-trial) gives only the model-level rates of ~15% for free trials and ~5% for freemium). The 2026 ChartMogul and ProductLed survey of 200 business products puts "good" reverse-trial conversion at 4 to 6% and "great" at 8 to 12%, and 7% of products use it ([Growth Unhinged](https://www.growthunhinged.com/p/free-to-paid-conversion-report); [ChartMogul](https://chartmogul.com/reports/saas-conversion-report/)). Every source assumes a free tier exists and that the free user stays reachable by email. Audiout has no free tier, so a reverse trial means designing one (for example, one speaker only), which is a product decision the evidence does not settle.

What this means for a no-email, one-time-purchase menu-bar app: the closest Mac audio competitor chose "works, but degraded" over "stops", and mobile data says free-tier users keep converting for weeks after a blocking app would have lost them. Neither is a controlled comparison of the two models for a paid desktop utility.

## 3. Timing of conversion

A widely repeated claim says Totango found nearly 50% of conversions happen after the trial ends. I could not find the primary Totango source; the Totango blog post it is attributed to contains no such number ([Totango](https://www.totango.com/blog/trial-conversion-is-top-priority-in-saas/)). Treat it as unverified.

The only controlled evidence found: a field experiment with 680,588 new users of an image-editing app (3-day vs 7-day trial) found the longer trial did not raise conversion at trial end, but raised later conversion by 42% and total subscriptions by 21% over two years, mostly through later promotions ([Frontiers in Psychology 2025](https://pmc.ncbi.nlm.nih.gov/articles/PMC12217587/)). That app had a free tier, so users were still inside the app to see those promotions.

Figures such as "12 to 18% of expired trials convert within 90 days" circulate on content-marketing sites attributed to ChurnZero, Gartner or OpenView with no link to a primary source. Not used here.

How long a lapsed trialist stays reachable with no email: no data found.

What this means for a no-email, one-time-purchase menu-bar app: the only reliable evidence says late buyers exist and are reached by the product itself. With no email, an app that quits at the wall removes the only channel to those late buyers.

## 4. Menu-bar and background apps

No published research or developer write-up found on the cost of a menu-bar app quitting at trial end versus staying visible. Apple's guidance confirms menu-bar extras are "visible by default" on macOS but says nothing about trials ([Apple HIG, The menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar)).

What this means for a no-email, one-time-purchase menu-bar app: this is reasoning, not evidence. A menu-bar icon is the app's only reminder that it exists; once it quits, nothing on screen prompts a return.

## 5. Nudges before expiry without email

Blinkist's day-5-of-7 reminder is the one measured example (section 1), and it was framed as protecting the user from an unwanted charge, which a one-time purchase does not have. Apple's guidance: "Don't use notifications to send marketing or promotional content unless people explicitly agree to receive such information" ([Apple HIG, Managing notifications](https://developer.apple.com/design/human-interface-guidelines/managing-notifications)). The trial-length experiment below found that inactivity in the last days of a trial goes with lower conversion ([Yoganarasimhan et al., Management Science 2023](https://pubsonline.informs.org/doi/10.1287/mnsc.2022.4507)), which supports prompting use late in the trial, not just prompting purchase. No published data found on in-app countdown banners or on the annoyance cost of reminders.

What this means for a no-email, one-time-purchase menu-bar app: an in-app countdown inside the popover is allowed; a system notification pushing a purchase needs the user's explicit agreement under Apple's guidance. Effect size is unknown.

## 6. Trial length and extensions

Evidence conflicts. A field experiment with 337,724 users of a large subscription software company found a 7-day trial beat 14 and 30 days: 5.59% more subscriptions than 30 days, better two-year retention and revenue. Mechanism: longer trials spread use thinly, and users idle at the end convert less. Experienced users did better with longer trials ([Yoganarasimhan et al.](https://pubsonline.informs.org/doi/10.1287/mnsc.2022.4507); [arXiv](https://arxiv.org/abs/2006.13420)). RevenueCat, across 17,000+ apps, finds longer trials convert better (monthly plans: 39.6% at 4 days or less, 46.6% at 10 to 16 days) ([RevenueCat](https://www.revenuecat.com/blog/growth/free-trial-length)), but those trials bill automatically unless cancelled, so they measure forgetting to cancel as well as choosing to buy. ChartMogul found no link between trial length and conversion across 200 business products; 62% use 14 days ([ChartMogul](https://chartmogul.com/reports/saas-conversion-report/)). Nothing found for a utility used a few times a week.

Extensions: Appcues offers a 14-day extension at expiry to trialists who never installed its code and says it "helped to soften the blow", with no numbers ([Appcues docs](https://docs.appcues.com/build-guide-evaluator-trial-conversion)). The frequently quoted "7-day extension converts 8 to 12%" traces to content-marketing sites with no primary source. Not used.

What this means for a no-email, one-time-purchase menu-bar app: calendar days are a weak fit for an app used a few times a week, because the best study ties conversion to use in the final days, not to elapsed days. A usage-based limit (Rogue Amoeba's model) or a "need more time?" extension for people who barely used it are both untested for this case.

## Most load-bearing sources

| Claim | Source | Evidence type | Trust |
|---|---|---|---|
| 7-day trial beat 14 and 30 days; idle end of trial lowers conversion | [Yoganarasimhan et al., Management Science 2023](https://pubsonline.informs.org/doi/10.1287/mnsc.2022.4507) | Randomised field experiment, 337,724 users | High; subscription software, not a utility |
| Longer trial did not lift conversion at trial end but lifted later conversion by 42% | [Frontiers in Psychology 2025](https://pmc.ncbi.nlm.nih.gov/articles/PMC12217587/) | Randomised field experiment, 680,588 users | High; app had a free tier |
| Blocking at install converts 10.7% vs 2.1% for free-tier apps; same retention; free tier keeps converting past week 6 | [RevenueCat 2026](https://www.revenuecat.com/blog/growth/subscription-app-trends-benchmarks-2026) | Aggregate data, mobile subscriptions | Medium; different business model |
| Longer trials convert better (auto-billing trials) | [RevenueCat trial length](https://www.revenuecat.com/blog/growth/free-trial-length) | Aggregate data, 17,000+ apps | Medium; opt-out billing inflates it |
| Trial length not linked to conversion; 14 days most common | [ChartMogul 2026](https://chartmogul.com/reports/saas-conversion-report/) | Survey, 200 business products | Medium |
| Reverse trial benchmarks 4 to 6% good, 8 to 12% great | [Growth Unhinged 2026](https://www.growthunhinged.com/p/free-to-paid-conversion-report) | Survey | Medium; assumes free tier |
| Reverse trial lifted conversion 10 to 40% | [CXL interview with Elena Verna](https://cxl.com/blog/reverse-trial-strategy/) | Practitioner claim, no sample; page not opened directly | Low |
| Honest trial screen: 23% more trial starts, opt-in 6% to 74% | [Blinkist, UX Planet](https://uxplanet.org/how-solving-our-biggest-customer-complaint-at-blinkist-led-to-a-23-increase-in-conversion-b60ad514134b) | Single A/B test | Medium; front of trial, not expiry |
| Mac audio utilities: no day limit, noise after 10 to 20 minutes | [Rogue Amoeba](https://rogueamoeba.com/support/knowledgebase/?showArticle=Misc-AboutAppTrials&product=General) | Vendor practice, no numbers | High as fact, zero as effect |
| Targeted 24-hour discount adds 10 to 15% revenue per user | [Adapty](https://adapty.io/blog/paywall-experiments-playbook/) | Vendor summary | Low to medium |
| No promotional notifications without explicit agreement | [Apple HIG](https://developer.apple.com/design/human-interface-guidelines/managing-notifications) | Platform guidance | High |
| "~50% of conversions happen after trial end" (Totango) | [Totango blog](https://www.totango.com/blog/trial-conversion-is-top-priority-in-saas/) | Primary not found | Unverified; do not rely on it |
