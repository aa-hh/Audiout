# Would an installer package help Audiout? Research, 2026-09-12

Two questions: could a signed `.pkg` put the app in `/Applications` correctly, and
could it pre-grant any of the permissions the first-run Setup window asks for.
Primary sources only: Apple developer documentation (fetched through Apple's own
documentation JSON endpoint, since the HTML pages render client-side), the Apple
Platform Security and Platform Deployment guides, local `man` pages, Sparkle's own
documentation, Rogue Amoeba's own support pages, and this repo.

## Verdict

**(a) Placement: yes, and that is the only thing it buys.** `pkgbuild` takes an
`--install-location` of `/Applications` (`man pkgbuild`, ARGUMENTS AND OPTIONS), the
Installer runs as root (`man installer`: "The installer command requires root
privileges to run."), and Apple's notary service accepts "Flat installer packages"
(https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
So a Developer ID Installer signed, notarized `.pkg` reliably lands the bundle in
`/Applications` and sidesteps Gatekeeper's habit of running a downloaded app from
elsewhere: "When necessary, Gatekeeper opens apps from randomized, read-only
locations." (https://support.apple.com/guide/security/gatekeeper-and-runtime-protection-sec5599b66df/web)

**(b) Permissions: no. Every prompt in Setup today would still appear.** There is no
supported way for an installer to record a privacy decision. The only pre-grant
mechanism Apple documents is a device management (MDM) profile, which "Requires a
device management service to install" and where "Supervision is required if you apply
this payload using a device management service."
(https://support.apple.com/guide/deployment/privacy-preferences-policy-control-payload-dep38df53c2a/web)
And even with enrolment, the two grants that matter most here cannot be set: the
profile's service list contains **no key at all** for system audio capture, and screen
capture is deny-only: "A profile can't grant access to the contents; it can only deny
it." (https://developer.apple.com/documentation/devicemanagement/privacypreferencespolicycontrol/services-data.dictionary)
Local Network is not manageable at all: "Device managers aren't able to configure local
network privacy using MDM."
(https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)

**Nothing can be removed from onboarding.** All seven steps
(`AudioutCore/Sources/AudioutCore/SetupFlowModel.swift:11-20`) stay exactly as they are.

**Recommendation: no.** The one benefit is guaranteed `/Applications` placement, which
the shipped DMG already invites with its `/Applications` symlink
(`scripts/make-staging.sh:148`). Against that: a second signing identity and a second
notarization round-trip per release. And if the `.pkg` were also to become the update
artifact, Sparkle's package path applies, where "Installs always require user authorization
which also prevents silent automatic installs"
(https://sparkle-project.org/documentation/package-updates/), meaning an administrator
password on every update where today there is none. If the drag step is genuinely
costing installs, the cheaper fix is the DMG window's layout, not a new packaging
format.

## 1. What Audiout asks for at first run

Seven Setup steps, in order: `audio`, `localNetwork`, `bluetooth`, `speakerSync`,
`remoteControl`, `audioutRemote`, `usageStats`
(`AudioutCore/Sources/AudioutCore/SetupFlowModel.swift:11-20`). Five of them ask macOS
for something; the iPhone-pairing step asks the OS for nothing
(`AudioutCore/Sources/AudioutOnboardingUI/AGENTS.md:19`), and the usage-stats step is
this app's own consent, not an OS grant (`SetupFlowModel.swift:85`).

| Step | What macOS is being asked | Where the ask lives |
|---|---|---|
| Audio | System audio capture, read through the private `TCCAccessPreflight` on `kTCCServiceAudioCapture` plus `kTCCServiceScreenCapture` | `AudioutCore/Sources/AudioutCore/SystemAudioCaptureTCC.swift:48-52`, `:129-130` |
| Local Network | Bonjour discovery of AirPlay speakers | `SetupModel.swift:79`, service types declared at `scripts/make-app.sh:915-929` |
| Bluetooth | `CBManager` authorization for the paired-device list and reconnect | `SetupModel.swift:96`, `AudioutCore/Sources/AudioutCore/BluetoothPermission.swift` |
| Speaker Sync | Approval of the `SMAppService` LaunchDaemon in Login Items, not a privacy grant | `AudioutCore/Sources/AudioutCore/PTPHelperService.swift:43-77`, `AudioutOnboardingUI/AGENTS.md:19` |
| Remote Control | Accessibility, for media-key posting and the volume-key event tap | `SetupModel.swift:80-90` |

Three of those are treated as required: audio capture, Local Network, the PTP helper
(`SetupModel.swift:106-110`); Accessibility and Bluetooth are deliberately optional
(`SetupModel.swift:91-96`).

The audio grant is not requested through any API, because none exists: the probe
"plays a brief tone and listens for it to verify the grant for real"
(`AudioutCore/Sources/AudioutCore/AudioCapturePermissionProbe.swift:14-16`), and
creating the process tap is what surfaces the prompt
(`AudioCapturePermissionProbe.swift:41-45`).

Grants are pinned to the code signature, which is why release builds are Developer ID
signed: "Developer ID signature keys TCC grants to a STABLE Team ID + bundle id"
(`scripts/make-app.sh:165`), and a real Team ID is also what lets the bundled daemon
register at all (`scripts/make-app.sh:141-146`).

**Current shipping format: a notarized, stapled DMG containing the app plus an
`/Applications` symlink.** `scripts/make-staging.sh:138-163` builds it (`hdiutil
create`, then `codesign`, then `notarytool submit`, then `stapler staple`);
`docs/RELEASE.md:27-29` and `:197` confirm the DMG is the published object and the one
the Sparkle appcast points at. A zip path still exists for the no-notarization fast
path (`scripts/make-release.sh:159-165`, `make-staging.sh:129-141`). No `.pkg` anywhere
in `scripts/`.

The PTP helper's LaunchDaemon plist already ships **inside** the bundle at
`Contents/Library/LaunchDaemons` (`scripts/make-app.sh:202-203`, `:521`), resolved by
`SMAppService.daemon(plistName:)`
(`AudioutCore/Sources/AudioutCore/PTPHelperService.swift:92-121`), so an installer has
no file to place for it.

## 2. Can a signed installer package grant any of these?

### System audio capture: no, and no MDM path either

The privacy profile's service dictionary has these keys and no others: Accessibility,
AddressBook, AppleEvents, BluetoothAlways, Calendar, Camera, FileProviderPresence,
ListenEvent, MediaLibrary, Microphone, Photos, PostEvent, Reminders, ScreenCapture,
SpeechRecognition, SystemPolicyAllFiles, SystemPolicyAppBundles, SystemPolicyAppData,
SystemPolicyDesktopFolder, SystemPolicyDocumentsFolder, SystemPolicyDownloadsFolder,
SystemPolicyNetworkVolumes, SystemPolicyRemovableVolumes, SystemPolicySysAdminFiles
(https://developer.apple.com/documentation/devicemanagement/privacypreferencespolicycontrol/services-data.dictionary,
read via https://developer.apple.com/tutorials/data/documentation/devicemanagement/privacypreferencespolicycontrol/services-data.dictionary.json).
There is no `AudioCapture` entry. The nearest neighbour, `ScreenCapture`, is deny-only:
"A profile can't grant access to the contents; it can only deny it." Camera, Microphone
and `ListenEvent` carry the same deny-only sentence. The payload type is
`com.apple.TCC.configuration-profile-policy`
(https://developer.apple.com/documentation/devicemanagement/privacypreferencespolicycontrol).

So the grant Audiout cannot work without is the one grant no profile, MDM or otherwise,
can pre-set.

### Local Network: no pre-grant mechanism exists

"Device managers aren't able to configure local network privacy using MDM." Users grant
it reactively: "Users configure local network privacy in Settings > Privacy & Security >
Local Network (System Settings on macOS). The OS adds an app to this list after it
attempts to access a local network." And: "Your program starts in the undetermined
state. The first time it performs a local network operation, the system presents the
local network alert."
(https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)

The same note lists automatic exemptions that do **not** help a normal app: "Any daemon
started by `launchd`", "Any program running as root", "Command-line tools run from
Terminal or over SSH, including any child processes they spawn." A `.pkg` postinstall
script would be root and therefore exempt, for itself, for the length of the install.
Nothing carries over to the app the user launches afterwards.

### Bluetooth: manageable, but only by MDM

`BluetoothAlways` exists and carries no deny-only restriction, so a profile can allow
it; it is "Deprecated: macOS 27+", with Apple pointing at the declarative
`com.apple.configuration.app.settings` replacement (same services dictionary as above).
In that replacement, `Bluetooth`, `LocalNetwork` and `Accessibility` accept the values
`None` or `Allow`
(https://developer.apple.com/documentation/devicemanagement/appsettingsappdictionaryobject),
and the declaration still shows the user a prompt: `OrganizationJustification` is "Text
you provide that clearly explains to the user the reason why the organization requires
these app permission defaults. The device includes this text in the permission consent
prompt it displays when it launches the app." Both routes are device management, not
installer, and both need enrolment.

### The Login Items / Background Task Management approval: MDM only

`ServiceManagementManagedLoginItems` is "This payload that configures managed login
items, which auto-enables and auto-allows matched items", payload type
`com.apple.servicemanagement`
(https://developer.apple.com/documentation/devicemanagement/servicemanagementmanagedloginitems);
its rules match by `RuleType`, where "You can use BundleIdentifier,
BundleIdentifierPrefix, Label, LabelPrefix, or TeamIdentifier"
(https://support.apple.com/guide/deployment/managed-login-items-payload-settings-dep07b92494/web),
with `TeamIdentifier` available as "An additional constraint to limit the scope of the
rule"
(https://developer.apple.com/documentation/devicemanagement/servicemanagementmanagedloginitems/rule).
Apple's deployment guide lists its supported delivery as User Enrollment, Device
Enrollment and Automated Device Enrollment, all of them MDM
(https://support.apple.com/guide/deployment/managed-login-items-payload-settings-dep07b92494/web).
Without that, `SMAppService.register()` "Registers the service so it can begin
launching subject to user approval."
(https://developer.apple.com/documentation/servicemanagement/smappservice/register()),
and `.requiresApproval` means "The service has been successfully registered, but the
user needs to take action in System Preferences."
(https://developer.apple.com/documentation/servicemanagement/smappservice/status-swift.enum/requiresapproval)
That is exactly the state the Setup step waits on
(`AudioutCore/Sources/AudioutCore/PTPHelperService.swift:15-24`).

`man sfltool` offers nothing: its whole synopsis is `sfltool [archive [-z]]`, "a tool
for testing and debugging SharedFileList."

### Accessibility: MDM-allowable, and the one step where that is beside the point

`Accessibility` has no deny-only sentence, so a profile could allow it (deprecated in
macOS 27 in favour of the declarative key, which as of macOS 27 "shows a non-blocking
notification for each application when this setting is applied"). Still MDM. And this
step is optional in the product anyway (`SetupModel.swift:91-96`).

### Could a root postinstall script write the privacy database directly? No

`man tccutil` documents exactly one command: "reset    Reset all decisions for the
specified service, causing apps to prompt again the next time they access the service."
There is no grant or allow verb. The database itself sits under System Integrity
Protection, which "restricts components to read-only in specific critical file system
locations" and which "macOS applies ... to every process running on the system,
regardless of whether that process is running sandboxed or with administrative
privileges."
(https://support.apple.com/guide/security/system-integrity-protection-secb7ea06b49/web)
*Unverified:* no Apple page found says the words "TCC database" and "System Integrity
Protection" in the same sentence; the conclusion rests on the quoted "regardless of ...
administrative privileges" plus the absence of any documented write path.

Apple's stance on the general shape of this is in the security guide's file-access
section: "In macOS 10.15 or later, this model is enforced by the system to help ensure
that all apps have obtained user consent before accessing files in Documents,
Downloads, Desktop, iCloud Drive, and network volumes."
(https://support.apple.com/guide/security/controlling-app-access-to-files-secddd1d86a6/web)

Nothing in `man pkgbuild`, `man productbuild` or Apple's notarization page mentions
privacy permissions at all.

## 3. What an installer would and would not buy

**Would:**

- Deterministic placement. `--install-location` "Specify the default install location
  for the contents of the package. For example, if you specify a single application
  component, you might specify an install-path of `/Applications`." (`man pkgbuild`),
  with the caveat in the same paragraph that "whether or not the default install
  location is actually used by the macOS Installer depends on the distribution file you
  deploy with the package."
- Escape from Gatekeeper's randomized read-only launch location, whose stated purpose is
  "to prevent the automatic loading of plug-ins distributed alongside the app"
  (https://support.apple.com/guide/security/gatekeeper-and-runtime-protection-sec5599b66df/web).
  *Unverified:* Apple does not document, on that page or any other found, that moving
  the app to `/Applications` is what ends the behaviour. That detail circulates only in
  developer forum posts, which this note does not treat as a source.
- Root at install time (`man installer`), plus `preinstall`/`postinstall` scripts
  (`man pkgbuild`, `--scripts`). *Unverified:* neither man page states in so many words
  that those scripts themselves run as root; what is quoted is that the `installer`
  tool requires root to run. Audiout has nothing that needs either: the helper's
  plist ships inside the bundle (`scripts/make-app.sh:202-203`).

**Would cost:**

- A second signing identity and a second notarization submission. Signing needs "a
  certificate and corresponding private key -- together called an 'identity'" (`man
  productbuild`, SIGNED PRODUCT ARCHIVES), and Apple's notarization page says "Use a
  'Developer ID' application, kernel extension, system extension, or installer
  certificate for your code-signing signature"
  (https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
  That installer certificate is a different identity from the Developer ID Application
  one `make-app.sh` already resolves (`scripts/make-app.sh:138-151`). The same page lists "Flat installer packages"
  among the deliverables the notary service accepts, so the `.pkg` is a second
  submission, not a free ride on the app's ticket.
- Sparkle, if the `.pkg` became the update artifact. Sparkle does support it:
  "Package installation allows Sparkle to update your application by downloading and
  installing a package, `pkg`, or multi-package, `mpkg`", but the documented
  limitations are "Slower relaunching and installation of updates on quit", "No support
  for delta updates for more efficient updates", "No fallback for rotating signing keys
  in case your signing keys need to change", "No support for generating updates easily
  using the `generate_appcast` tool", and the hard one: "Installs always require user
  authorization which also prevents silent automatic installs". Sparkle recommends the
  package path only for apps with "very custom installation needs that cannot be
  satisfied by distributing a regular app bundle."
  (https://sparkle-project.org/documentation/package-updates/)
  The `generate_appcast` limitation is moot here: this repo writes the appcast XML by
  hand and signs the artifact with `sign_update` (`scripts/make-staging.sh:185-195`).
  The authorization one is not: an administrator password on every update, where today
  Sparkle installs a DMG-delivered app bundle with none
  (`scripts/make-staging.sh:166` sets the enclosure type
  `application/x-apple-diskimage`).
- *Unverified:* whether Sparkle can update an app bundle that a `.pkg` originally
  installed. Sparkle's documentation does not address that case, so the two-artifact
  option below is untested by any source.

**The two-artifact option**, if placement alone is judged worth something: ship the
`.pkg` for first install and keep the DMG as the Sparkle enclosure. That keeps updates
password-free but means building, signing and notarizing two objects per release and
maintaining two download paths through the licence server's `/download` pointer
(`docs/RELEASE.md:197`).

## 4. How Rogue Amoeba ships the comparable apps

Audio Hijack and Loopback capture system audio and carry a background audio component,
so their install is the closest published comparison. On their own pages:

- The app is dragged, not installed: "drag it from its initial download location to the
  Applications folder, then double-click its icon"
  (https://rogueamoeba.com/support/manuals/audiohijack/?page=etc-installinguninstalling).
  The page does not name the download container, so **unverified** whether that download
  is a DMG or a zip.
- Their audio component's install needs an administrator password: "you'll need to enter
  your Mac's administrator password"
  (https://rogueamoeba.com/support/knowledgebase/?showArticle=ACE-Password&product=Audio+Hijack)
  and a System Settings approval: "You need to allow it to run in the System Settings
  app."
  (https://rogueamoeba.com/support/knowledgebase/?showArticle=ACE-Repair&product=Audio+Hijack)
- What it is today: "the ACE component is not a kernel extension. Instead, Apple refers
  to it as a 'system extension'", which "has no ability to interact with the kernel
  directly, and thus no ability to cause your Mac to crash"
  (https://rogueamoeba.com/support/knowledgebase/?showArticle=ACE-SecurityPolicy&product=Loopback).
  *Unverified:* no Rogue Amoeba page found states the before-and-after of moving off a
  kernel extension installer, only what ACE is now.

Read against Audiout: a company whose product needs a privileged audio component still
ships a drag-to-Applications app and does the privileged install from inside the app,
with the same password-plus-System-Settings pair Audiout's Speaker Sync step already
uses. Audiout's helper asks for the Login Items approval rather than a password, since
`SMAppService.register()` launches "subject to user approval"
(https://developer.apple.com/documentation/servicemanagement/smappservice/register()).

## Open questions

- Whether the drag step is actually losing installs. Nothing here measures that, and it
  is the only thing an installer fixes. The existing analytics surface would answer it:
  the gap between a `/download` hit and the first Setup step reaching `completed`.
- Whether moving the app out of a mounted DMG is what ends Gatekeeper's randomized
  launch location. Not documented by Apple; testable in an afternoon with a notarized
  build and `NSBundle.main.bundlePath` logged at launch from inside the mounted image
  versus from `/Applications`.
