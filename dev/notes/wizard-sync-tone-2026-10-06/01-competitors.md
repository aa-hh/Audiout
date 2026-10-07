# What shipping products play when they measure speakers

Track 1 of 4. Survey of the stimuli real products use for room tuning and speaker timing, and why.

Terms used below, defined once:

- **Sweep (swept sine, chirp):** a single tone whose pitch glides from one frequency to another. A **log sweep** spends equal time per octave, so it sounds even to the ear and puts more energy in the bass than a linear sweep.
- **Pink noise / brown noise:** hiss with more energy in the low end than white noise. Pink falls 3 dB per octave; brown falls 6 dB per octave and sounds like a waterfall or heavy rain.
- **MLS (maximum length sequence):** a repeating pseudo-random binary noise used for impulse-response measurement.
- **Audio watermark:** a low-level signal hidden inside ordinary audio, designed to be inaudible, that a microphone can still detect.
- **Cross-correlation:** sliding the known stimulus along the recording to find where it matches best; the match position gives the arrival time.

"Unverified" means I found no primary source and the claim rests on a secondary write-up or forum report.

## Summary table

| Product | Signal type | Band | Duration | How it is described to the user | Source |
|---|---|---|---|---|---|
| Sonos Trueplay (phone mic, Advanced) | Periodic hybrid: brown-ish noise below ~50-100 Hz + descending sweep above; one period ~3/8 s, repeated 2-4 times a second | ~20 Hz-20 kHz | 45 s mono, 60 s stereo pair (>150 periods) | "fairly loud"; walk the room moving the phone head to waist. A Sonos rep called it "a laser fight under a waterfall" | [patent US9736584](https://patents.google.com/patent/US9736584B2/en), [Sonos tech blog](https://tech-blog.sonos.com/posts/trueplay-spectral-correction/), [Sonos support](https://support.sonos.com/article/tune-your-sonos-speakers-with-trueplay), [Core77](http://www.core77.com/posts/41080/Sonos-Debuts-Software-That-Makes-Its-Speakers-Sound-Good-Even-in-Terrible-Listening-Environments-ie-Your-Apartment) |
| Sonos home theatre / multi-speaker Trueplay | Same hybrid sound, each speaker given its own time slot inside each repeating frame; delays per speaker from cross-correlation | as above | as above | same flow | [patent US11337017](https://patents.google.com/patent/US11337017B2/en) |
| Sonos Auto Trueplay (Move, Move 2, Roam, Roam 2, Play) | The music itself, via the speaker's own mic | music | continuous | "starts tuning as soon as you begin playing audio" | [Sonos support](https://support.sonos.com/en-us/article/automatic-trueplay-tm) |
| Sonos Quick Tuning (Era 100/300, Arc Ultra) | Speaker plays "a series of sounds" into its own mics; exact signal unverified | unknown | unknown | not described | [Sonos support](https://support.sonos.com/en/article/tune-your-arc-ultra-era-100-or-era-300-with-trueplay) |
| Apple TV Wireless Audio Sync (iPhone mic) | "Tones"; exact signal unverified | unknown | whole flow "a minute or two" | "Apple TV 4K plays tones"; hold iPhone close to the TV; screens show "Listening and Playing Tone" | [Apple support](https://support.apple.com/guide/tv/calibrate-video-and-audio-atvb228b7711/tvos), [iDownloadBlog](https://www.idownloadblog.com/2020/10/15/set-up-wireless-audio-sync-apple-tv/) |
| Apple HomePod room sensing | Listens to its own output (music); no separate tone found | music | "a couple minutes of music" after a move | "uses its mics to listen for sound reflections" | [apple.com HomePod](https://www.apple.com/homepod-2nd-generation/), [Mac Observer](https://www.macobserver.com/tips/homepod-recalibrate-shake/), [DXOMARK](https://www.dxomark.com/apple-homepod-speaker-review-true-360-sound/) |
| Samsung SpaceFit Sound (TVs) | Real programme content, not a test tone | content | continuous | none, it is automatic | [Samsung newsroom (search summary; page timed out)](https://news.samsung.com/global/samsung-neo-qled-tvs-obtain-spatial-sound-optimization-certification-from-vde), [Samsung support](https://www.samsung.com/au/support/tv-audio-video/use-spacefit-sound) |
| Google Home Max Smart Sound / Room EQ | Mics monitor playback; whether music or a tone is used is unverified | unknown | "within seconds" after a move | none | [Android Authority](https://www.androidauthority.com/google-home-max-frances-kwee-interview-835030/) |
| Google Cast group delay | No acoustic step: manual slider | n/a | n/a | "move the slider... until the audio sounds in sync"; typical 0-40 ms speakers, 0-80 ms soundbars | [Google support](https://support.google.com/googlehome/answer/6318642) |
| Amazon Echo Studio | Test tones at setup (unverified) | unknown | "a few seconds" (unverified) | "automatically senses the acoustics of your space" | [What Hi-Fi review](https://www.whathifi.com/reviews/amazon-echo-studio) (not readable in full) |
| Bose ADAPTiQ | "Series of tones" at 5 seats via a mic headset; exact signal unverified. Original patent: tone bursts with 50% silence | unknown | ~10 min whole procedure | voice prompts guide you; room must be quiet | [Bose support](https://www.bose.ie/en_ie/support/article/running-the-adaptiq--system.html), [patent US7483540](https://patents.google.com/patent/US7483540B2/en) |
| Audyssey MultEQ (Denon/Marantz) | Fast log sweep, ~10 per speaker | 10 Hz-24 kHz | "blip" each; sequential per speaker | "chirps" at 75 dB SPL (-30 dBFS); was 85 dB, lowered because users found it too loud | [Audyssey FAQ (quotes Audyssey CTO)](http://audysseyfaq.blogspot.com/2014/06/welcome-to-audyssey-faq-and-audyssey101_16.html) |
| Yamaha YPAO | Test tones (manual-mode level checks use pink noise); exact auto signal unverified | broadband | unknown | "output at high volume and may surprise or frighten small children"; volume cannot be adjusted | [Yamaha manual](https://manual.yamaha.com/av/17/rxa770/en/pages/c3_sf10.html), [AV Nirvana forum](https://www.avnirvana.com/threads/asio4all-level-matching-vs-receiver.9161) |
| Dirac Live | Sine sweep per speaker, plus what users hear as a chirp at the end; exact length unverified | broadband | unknown | not described | [Dirac helpdesk](https://helpdesk.dirac.com/en/dirac-room-correction/popping-sounds-during-measurements-sweeps), [miniDSP forum](https://www.minidsp.com/community/threads/problem-with-a-weird-sound-at-the-end-of-the-dirac-sweep-with-shd-studio.21204/latest) |
| Anthem ARC Genesis | "Short tone sweeps through each speaker" | broadband | unknown | not described | [CinemaConfig](https://cinemaconfig.com/reference/anthem-arc-genesis) |
| Trinnov Optimizer | Not published; captures "in just a few seconds" with a 4-capsule mic | unknown | seconds | not described | [Trinnov](https://www.trinnov.com/en/technologies/active-acoustics/optimizer/) |
| Bang & Olufsen Active Room Compensation | "A sweeping sound" via internal mic | unknown | unknown | room should be quiet | [B&O support](https://support.bang-olufsen.com/hc/en-us/articles/360041256231-What-does-room-compensation-do) (search summary; page refused fetch) |
| Sony Sound Field Optimization (HT-A9, HT-A5000) | Measurement sound, type unverified; measures distance to walls, ceiling, sub and rears | unknown | "up to 30 seconds" (A5000), "about 1 minute" (A9) | "the speakers may make loud sounds"; don't walk or stand in front | [Sony help guide](https://helpguide.sony.net/ht/a5000/v1/en/contents/TP1000381248.html), [Galaxus test](https://www.galaxus.ch/en/page/hta9-sonys-revolutionaeres-dolby-atmos-system-im-test-22003) |
| LG AI Room Calibration | Test tones from the TV/soundbar, heard by remote or far-field mics; type unverified | unknown | unknown | point the remote at the TV | [LG support](https://www.lg.com/us/support/help-library/lg-tv-setting-up-ai-room-calibration-sound--20154713289014) |
| JBL Bar 9.1 | "A calibration tone" in two steps (listening zone, then position of the detachable rears) | unknown | unknown | 5-to-1 countdown, then tone | [JBL support](https://support.jbl.com/howto/jbl-bar-9-1-how-to-perform-sound-calibration-us/000019055.html) (search summary; page refused fetch) |
| AmpMe (phone-to-phone sync) | First an "audible chirping sound"; later replaced by ultrasonic tones ("AutoSync") | ultrasonic (exact unknown) | short | "barely audible series of clicks and beeps" | [VentureBeat](https://venturebeat.com/ai/ampme-plans-to-kill-bluetooth-speakers-by-syncing-music-between-smartphones), [Computerworld](https://www.computerworld.com/article/1641094/new-tech-syncs-small-speakers-for-big-sound.html) |
| SoundSeeder | No acoustic step: manual offset, 10 ms steps, -400 to +400 ms | n/a | n/a | adjust by ear | [SoundSeeder FAQ](https://soundseeder.com/help/) |
| Snapcast, Roon | No acoustic step: manual per-client latency / zone delay in ms | n/a | n/a | adjust by ear | [Home Assistant Snapcast](https://www.home-assistant.io/actions/snapcast.set_latency/), [Roon community](https://community.roonlabs.com/t/zone-grouping-delay/310005) |
| JBL PartyBoost, UE PartyUp | No acoustic step found | n/a | n/a | n/a | [KitGuru](https://www.kitguru.net/lifestyle/jon-martindale/ultimate-ears-can-now-sync-up-50-speakers/) |
| Roku "Adjust Audio Delay" | Phone app, asks for camera permission; signal not documented | unknown | unknown | "follow the steps on the app" | [Roku support](https://support.roku.com/article/360037246034) |
| Marshall, Soundcore/Anker, Teufel, KEF, Devialet, Bluesound/HEOS add-speaker chimes | Nothing found on an acoustic measurement step or a measurement stimulus | — | — | — | searches returned only manual EQ pages, e.g. [Marshall](https://www.marshall.com/at/de/support/speakers/support-for-acton-ii-voice-with-amazon-alexa/how-to-adjust-the-volume-bass-treble) |

## Sonos Trueplay

The best-documented consumer stimulus, and the only one whose designers wrote about pleasantness.

- **What it is.** Patent US9736584 (Sonos, "Hybrid test tone for space-averaged room audio calibration using a moving microphone") describes the sound: a noise component from the bottom of the range up to a crossover "around 50-100 Hz", and a swept component from there to the top, with both overlapping in the crossover zone. One period is "approximately 3/8ths of a second" (range 1/4 to 1 s), repeating at "2-4 Hz", across ~20 Hz-20 kHz. [US9736584](https://patents.google.com/patent/US9736584B2/en)
- **Why noise in the bass.** The patent says noise gives enough low-frequency energy without driving the speaker hard enough to damage it, and the sweep covers the highs efficiently with a predictable phase that lets them undo the Doppler shift from a moving phone. Overlapping the two avoids "possibly unpleasant sounds that are associated with a harsh transition". [US9736584](https://patents.google.com/patent/US9736584B2/en)
- **Pleasantness is an explicit design input.** The family of Sonos patents describes the brown noise as having a "soft" quality "similar to a waterfall or heavy rainfall, which may be considered pleasant to some listeners", and says "a descending chirp may be more pleasant to hear to some listeners than an ascending chirp". [US10585639 via Justia](https://patents.justia.com/patent/10585639), [search summary of US9763018 family](https://patents.google.com/patent/US10750304)
- **Engineer's account.** Tim Sheen (Sonos, Dec 2020): the tone is "periodic", period "about a third of a second" for one speaker, plays "45 seconds, or more than 150 periods"; stereo pairs use a period "twice as long" and play one minute. It is shaped to "overcome room noise efficiently, with sufficient energy at low frequencies where room noise tends to be highest, and just sufficient at high frequencies". [Sonos tech blog](https://tech-blog.sonos.com/posts/trueplay-spectral-correction/)
- **What users hear.** Pocket-lint: "brown noise, pulse sounds that allow for echoes, and a sweep of frequencies". [Pocket-lint](https://www.pocket-lint.com/news/135396-what-is-sonos-trueplay-and-how-does-it-work). Sonos itself only says "fairly loud". [Sonos support](https://support.sonos.com/article/tune-your-sonos-speakers-with-trueplay)
- **The "whoosh" the owner remembers** is the brown-noise bed plus a descending sweep repeating about three times a second. The repetition rate is what makes it read as a pulsing texture rather than a tone.
- **Multiple speakers.** Patent US11337017 ("Spatial audio correction") splits each repeating frame into slots, one per speaker channel, played "sequentially in a known order". It measures "respective delays for each sound axis" to "align time-of-arrival" at the listening spot, using cross-correlation. A slot or frame may carry "a watermark (e.g., a particular pattern of sound)" to identify it. This is time-division: speakers take turns, they are never on at once. [US11337017](https://patents.google.com/patent/US11337017B2/en)
- **Music as a stimulus was claimed early.** Sonos's 2015 patent US9106192 says the calibration audio "may be a favorite track selected by the user" or "a series of incremental frequencies". [US9106192](https://patents.google.com/patent/US9106192B2/en). Auto Trueplay on portable models ships that idea: it tunes from whatever is playing. [Sonos support](https://support.sonos.com/en-us/article/automatic-trueplay-tm)

## Apple TV Wireless Audio Sync

The closest product to the Audiout job: a phone mic measures when a speaker's sound arrives and the box shifts its output to match.

- Apple's wording: "Apple TV 4K plays tones through your wired speakers in order to measure the TV's audio/visual latency, then it matches the output for the wireless speakers... hold your iPhone close to your TV or receiver speakers." [Apple support](https://support.apple.com/guide/tv/calibrate-video-and-audio-atvb228b7711/tvos)
- Both screens show "Listening and Playing Tone"; the flow takes "a minute or two". [iDownloadBlog](https://www.idownloadblog.com/2020/10/15/set-up-wireless-audio-sync-apple-tv/)
- **Unverified:** the exact signal (sweep, chirp, bursts), its band, and its length. No Apple patent or teardown turned up. Press coverage only repeats "a series of tones". [9to5Mac](https://9to5mac.com/2019/06/18/ios-13-uses-your-iphone-microphone-to-fix-apple-tv-audio-sync-issues/)
- It measures one output path at a time: the iPhone is held close to the wired speakers, so there is no near/far level imbalance to handle.

## Apple HomePod

- Apple: "With room sensing, HomePod automatically understands its location in a room by using its mics to listen for sound reflections." [apple.com](https://www.apple.com/homepod-2nd-generation/)
- After a move (detected by its accelerometer) it "launches a low-frequency calibration for bass correction". [DXOMARK](https://www.dxomark.com/apple-homepod-speaker-review-true-360-sound/). Mac Observer found it took "a couple minutes of music" to finish, which points to it measuring from the music rather than a tone. [Mac Observer](https://www.macobserver.com/tips/homepod-recalibrate-shake/). Apple has not said so outright: treat "uses the music" as likely, not confirmed.
- PhoneArena's earlier claim that it "fires sound" at walls is a secondary description and does not say whether that sound is music. [PhoneArena](https://www.phonearena.com/news/Apple-HomePod-how-it-works-sound-technology-explained_id102470)

## Samsung SpaceFit Sound

- Per Samsung's newsroom (seen in a search summary; the page timed out on fetch, so this is unverified at source): traditional TVs use "a set of dedicated sounds", while SpaceFit "utilizes real content to analyze viewing environments". Samsung support says the TV analyses "the content's audio and your surroundings in real time". [Samsung newsroom](https://news.samsung.com/global/samsung-neo-qled-tvs-obtain-spatial-sound-optimization-certification-from-vde), [Samsung support](https://www.samsung.com/au/support/tv-audio-video/use-spacefit-sound)

## Audyssey MultEQ

- Audyssey's CTO, quoted in the Audyssey FAQ: the "silly blip" is "actually a fast sweep. It starts at 10 Hz and runs out to 24 kHz", weighted logarithmically. About 10 per speaker, speakers measured in turn. [Audyssey FAQ](http://audysseyfaq.blogspot.com/2014/06/welcome-to-audyssey-faq-and-audyssey101_16.html)
- Level was cut from 85 dB to 75 dB SPL (-30 dBFS) because users found it too loud at night. Same source. This is the one documented case of a vendor lowering a stimulus because of complaints.
- Individual sweep length: unverified ("blip" suggests well under a second).

## Bose ADAPTiQ

- User-facing: about 10 minutes, five seats, a mic headset, voice prompts, quiet room. [Bose support](https://www.bose.ie/en_ie/support/article/running-the-adaptiq--system.html)
- Bose patent US7483540 (the one ADAPTiQ cites) describes a CD track with "a 50% duty cycle of silence interspersed with bursts of test tones" in one embodiment; no band or duration given. [US7483540](https://patents.google.com/patent/US7483540B2/en)
- The "log chirp... good peak-to-average ratio... immunity to non-linear speaker distortion", 1 s, 20 Hz-20 kHz patent family that searches attribute to Bose is in fact Harman/AMX (US9036825). [US9036825](https://patents.google.com/patent/US9036825B2/en). Its point that the chirp must be at least as long as the room's reverberation still applies.
- Exact ADAPTiQ signal: unverified.

## Other measurement-tone products

- **Yamaha YPAO:** "Test tones are output at high volume and may surprise or frighten small children"; volume fixed. Measures speaker distance as well as level and EQ. [Yamaha manual](https://manual.yamaha.com/av/17/rxa770/en/pages/c3_sf10.html)
- **Sony Sound Field Optimization:** measures distance to ceiling, walls, sub and rear speakers. "Optimization will take up to 30 seconds... the speakers may make loud sounds." [Sony help guide](https://helpguide.sony.net/ht/a5000/v1/en/contents/TP1000381248.html). A reviewer heard "strange sounds" for about a minute on the HT-A9. [Galaxus](https://www.galaxus.ch/en/page/hta9-sonys-revolutionaeres-dolby-atmos-system-im-test-22003)
- **Harman patent US9596553** ("audio measurement sweep"): pink-noise-shaped sweep between 20 Hz and 20 kHz, white below, red above, Tukey-windowed (smooth fade in and out), aimed at protecting drivers rather than pleasantness. [US9596553](https://patents.google.com/patent/US9596553)

## Products that hide the measurement or skip it

- **InterDigital patent US20190116395A1** (audio/video sync across devices): preferred method is "spread spectrum audio watermarking" in the programme audio, "inaudible to the listener, so that the synchronization method... can be repeated nearly continuously". Alternatives: ~21 kHz ultrasound, or an audible 10 ms burst of two summed sine tones. [US20190116395A1](https://patents.google.com/patent/US20190116395A1/en)
- **Waves Audio patent US11778409** (synchronised playback on mic-equipped speakers): the calibration sound can be "music that is played at the time", "pink noise", the user saying "calibrate", or a phone app's sound. It measures delay without shared clocks and absorbs "codec delay, driver delay, buffer drops, DAC delay". [US11778409](https://patents.google.com/patent/US11778409B2/en)
- **AmpMe:** started with "an audible chirping sound", moved to ultrasonic tones. [VentureBeat](https://venturebeat.com/ai/ampme-plans-to-kill-bluetooth-speakers-by-syncing-music-between-smartphones). Ultrasonic is off the table for Audiout (codec roll-off), but the move shows they saw the audible chirp as a cost.
- **Google Cast, SoundSeeder, Snapcast, Roon:** no acoustic measurement at all; a manual millisecond slider adjusted by ear. SoundSeeder notes Bluetooth speakers add 20-70 ms of buffer that changes at every playback start, so a fixed offset cannot hold. [SoundSeeder FAQ](https://soundseeder.com/help/), [Google support](https://support.google.com/googlehome/answer/6318642)

## Musical or branded stimuli

- I found **no shipping product that uses a melodic, branded or jingle-like stimulus** for measurement. The nearest are Sonos (sound shaped deliberately to be "soft" and descending) and the products that measure from the user's own music (Sonos Auto Trueplay, HomePod, Samsung SpaceFit).
- Sonos patent US9106192 allows "a favorite track selected by the user" as the calibration audio. [US9106192](https://patents.google.com/patent/US9106192B2/en)
- Setup chimes on Sonos, Bluesound and HEOS: no evidence that any doubles as a timing measurement.

## What this means for Audiout

1. Apple TV Wireless Audio Sync does the same job as Audiout (phone mic times a speaker) and plays "tones". Apple has not published the signal, so we cannot copy it.
2. Sonos multi-speaker Trueplay (US11337017) is the closest two-speaker, one-mic precedent. It uses one sound shared by all speakers, takes turns in time slots, and finds each delay by cross-correlation. That matches our existing `staggered` 2 s option, not our simultaneous two-band design.
3. Sonos's answer to "pleasant but measurable" is: brown noise in the bass, a descending sweep above it, crossfaded together, repeated about three times a second at a moderate level. Pleasantness came from the spectrum (soft low end) and sweep direction (down), not from melody.
4. Sonos can lean on noise because it measures 45 s of repeats from a moving phone. We get ~1 s, so noise costs us averaging time that a sweep does not.
5. Audyssey cut its sweep level by 10 dB after complaints. Level alone changes how the stimulus is received.
6. Products that cannot predict the speaker's delay chain (Bluetooth buffers) either measure acoustically every time or give up and offer a manual slider. Audiout measures, which is the stronger position.
7. Hiding the measurement in music (watermarks, Auto Trueplay, SpaceFit, HomePod) is patented and shipping, but every case takes seconds to minutes of listening, not 1 s.
8. No precedent ships a musical or branded measurement sound. A branded stimulus would be new ground, without a known failure to learn from.
