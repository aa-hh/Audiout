# License Inventory: OwnTone Extraction Cluster

**Generated:** 2026-07-13  
**Task:** T-LICENSE-1 — Licensing sanity check and NOTICE file preparation  
**Project Status:** GPL-2.0-or-later (OPEN SOURCE, per RESOLVED DECISIONS)

---

## Executive Summary

This inventory covers the actual license headers found in the OwnTone source extraction cluster (`dev/owntone-src/`). The project adopts **GPL-2.0-or-later** as the overall license for the Audiouted engine and application. Within this:

- **GPL-2.0+ cluster** (airplay.c, airplay_events.c, rtp_common.c) forms the core sender engine.
- **MIT components** (pair_ap, libairptp) retain their original headers and are compatible with GPL-2.0+.
- **BSD components** (evrtsp, rtsp.c) retain their original headers and are compatible with GPL-2.0+.
- The tiny **SMAppService PTP helper** will ship as MIT (libairptp-based, separate binary).

**Key obligations under GPL-2.0-or-later distribution:**
1. Retain original GPL/BSD/MIT headers in all source files.
2. Provide source code availability (via repository or distribution).
3. Include a NOTICE file crediting all copyright holders.
4. Preserve copyright notices and license texts in derivative works.

---

## License Inventory Table

| Path | License | Copyright Holders | Notes |
|------|---------|-------------------|-------|
| `src/outputs/airplay.c` | GPL-2.0+ | (Not explicitly listed in header) | 4413 lines; core sender implementation. SPDX: "GNU General Public License v2 or later" |
| `src/outputs/airplay_events.c` | GPL-2.0+ | (Not explicitly listed in header) | 12545 bytes; RTSP event handling for sender. Same GPL-2.0+ notice |
| `src/outputs/rtp_common.c` | GPL-2.0+ | Copyright (C) 2019- Espen Jürgensen | RTP/RTCP packet framing. GPL-2.0+ notice present |
| `src/outputs/rtp_common.h` | **NO LICENSE HEADER** | (None declared) | Support header for RTP. Assume GPL-2.0+ by inheritance (paired with .c). |
| `src/evrtsp/rtsp.c` | BSD-2-Clause (Provos 2002-2006) + BSD (Blache 2010) | Niels Provos (2002-2006), Julien BLACHE (2010) | Based on libevent's evhttp. BSD license with 3-clause disclaimer. |
| `src/evrtsp/evrtsp.h` | BSD-2-Clause (Provos 2000-2004) + BSD (Blache 2010) | Niels Provos (2000-2004), Julien BLACHE (2010) | RTSP client/server protocol support. Same BSD license. |
| `src/evrtsp/log.h` | BSD-2-Clause | Niels Provos (2000-2004) | Logging macros. Standard BSD license (3-clause). |
| `src/evrtsp/rtsp-internal.h` | BSD (Provos 2001, Blache 2010) | Niels Provos (2001), Julien BLACHE (2010) | Internal RTSP structures. No explicit license text, but header references both authors. **Assume BSD by context.** |
| `src/pair_ap/pair.c` | MIT | (Not explicitly listed; implicit OwnTone copyright) | AirPlay 2 pairing driver. Clear MIT license. |
| `src/pair_ap/pair.h` | **NO LICENSE HEADER** | (None declared) | Public pairing interface. Assume MIT by pair context. |
| `src/pair_ap/pair_fruit.c` | MIT | (Implicit; adapted from Tom Cocagne's csrp) | MFi ("Fruit") pairing + SRP6a. MIT notice; credits csrp. |
| `src/pair_ap/pair_homekit.c` | MIT | (Implicit; adapted from ViktoriiaKh ap2-sender, Cocagne csrp, maximkulkin esp-homekit) | HomeKit pairing (normal + transient). MIT notice; multiple credits. |
| `src/pair_ap/pair-internal.h` | **NO LICENSE HEADER** | (None declared) | Private pairing structures. Assume MIT by pair context. |
| `src/pair_ap/pair-tlv.c` | MIT | (Adapted from maximkulkin/esp-homekit) | TLV encoding/decoding for HomeKit. MIT notice. |
| `src/pair_ap/pair-tlv.h` | **NO LICENSE HEADER** | (None declared) | TLV type definitions. Assume MIT by pair context. |
| `src/libairptp/LICENSE` | MIT | Copyright (c) 2026 OwnTone | Master LICENSE file for libairptp. Explicit MIT. |
| `src/libairptp/airptp.h` | **NO LICENSE HEADER** | (None declared) | Public PTP daemon API. Assume MIT (by libairptp context). |
| `src/libairptp/src/airptp.c` | MIT | Copyright (c) 2026 OwnTone | Core PTP shared-daemon implementation. Explicit MIT. |
| `src/libairptp/src/daemon.c` | MIT | Copyright (c) 2026 OwnTone | PTP daemon worker. Explicit MIT. |
| `src/libairptp/src/ptp_definitions.h` | **NO LICENSE HEADER** | (None declared) | PTP message constants. Assume MIT by context. |
| `src/libairptp/src/ptp_msg_handle.c` | **NO LICENSE HEADER** | (None declared) | PTP message processing. Assume MIT by context. |
| `src/libairptp/src/ptp_msg_handle.h` | **NO LICENSE HEADER** | (None declared) | PTP message handler interface. Assume MIT by context. |
| `src/libairptp/src/airptp_internal.h` | **NO LICENSE HEADER** | (None declared) | Internal PTP structures. Assume MIT by context. |
| `src/libairptp/src/utils.c` | **NO LICENSE HEADER** | (None declared) | Utility functions (likely PTP support). Assume MIT by context. |
| `src/libairptp/src/utils.h` | **NO LICENSE HEADER** | (None declared) | Utility function declarations. Assume MIT by context. |
| `src/libairptp/daemon/airptpd.c` | MIT | Copyright (c) 2026 OwnTone | Standalone PTP daemon executable. Explicit MIT. |
| `src/libairptp/daemon/airptpd.service.in` | **NO LICENSE HEADER** | (None declared) | systemd service file template. Assume MIT by context. |
| `src/ptpd.h` | **NO LICENSE HEADER** | (None declared) | OwnTone's PTP wrapper layer (points to libairptp). Assume GPL-2.0+ (OwnTone server integration). **REVIEW:** This bridges GPL sender to MIT PTP lib. |
| `src/outputs.h` | **NO LICENSE HEADER** | (None declared) | Output backend interface (OwnTone plumbing). Assume GPL-2.0+ (core OwnTone file). Will be REPLACED in AirPlayEngine. |
| Top-level `COPYING` | GPL-2.0 | Free Software Foundation (1989, 1991) | Full GPL-2.0 license text. Authoritative for OwnTone project. |

---

## Files with NO License Headers (Surprises)

| File | Issue | Mitigation |
|------|-------|-----------|
| `src/outputs/rtp_common.h` | No explicit license header. Paired with GPL-2.0+ .c file. | Treat as GPL-2.0+ by inheritance; document assumption. |
| `src/pair_ap/pair.h` | No explicit license header. Part of MIT pair_ap cluster. | Assume MIT by directory context. |
| `src/pair_ap/pair-internal.h` | No explicit license header. Internal to MIT pair_ap. | Assume MIT by directory context. |
| `src/pair_ap/pair-tlv.h` | No explicit license header. Part of MIT pair_ap. | Assume MIT by directory context. |
| `src/libairptp/airptp.h` | No explicit license header. Public interface for MIT libairptp. | Assume MIT (ratified by libairptp/LICENSE). |
| `src/libairptp/src/ptp_definitions.h` | No explicit license header. Internal to MIT libairptp. | Assume MIT by directory context. |
| `src/libairptp/src/ptp_msg_handle.c` | No explicit license header. Core PTP logic in MIT libairptp. | Assume MIT by directory context. |
| `src/libairptp/src/ptp_msg_handle.h` | No explicit license header. Part of MIT libairptp. | Assume MIT by directory context. |
| `src/libairptp/src/airptp_internal.h` | No explicit license header. Internal to MIT libairptp. | Assume MIT by directory context. |
| `src/libairptp/src/utils.c` | No explicit license header. Utility support for MIT libairptp. | Assume MIT by directory context. |
| `src/libairptp/src/utils.h` | No explicit license header. Utility interface in MIT libairptp. | Assume MIT by directory context. |
| `src/libairptp/daemon/airptpd.service.in` | No explicit license header. systemd service file (administrative). | Assume MIT by directory context. |
| `src/evrtsp/rtsp-internal.h` | No explicit license text (only copyright reference). | Contextually BSD; likely oversight in header. Treat as BSD per rtsp.c. |
| `src/ptpd.h` | No explicit license header. OwnTone wrapper for PTP. | Likely GPL-2.0+ (OwnTone integration layer). Mark for REPLACEMENT in AirPlayEngine. |
| `src/outputs.h` | No explicit license header. OwnTone output backend interface. | Likely GPL-2.0+ (OwnTone infrastructure). Will be REPLACED in AirPlayEngine shims. |

---

## Key Findings & Discrepancies vs. Plan Assumptions

### Plan Assumptions (from PLAN-PHASE-2.md, Q4):

> - airplay.c / airplay_events.c / rtp_common.c = **GPL-2.0+** ✓ CORRECT
> - pair_ap/* = **MIT** ✓ CORRECT
> - libairptp = **MIT** ✓ CORRECT
> - evrtsp/rtsp.c = **BSD (Provos 2002-2006 + Blache 2010)** ✓ CORRECT

### Actual Findings:

1. **All GPL-2.0+ files DO have explicit headers.** ✓ No surprises.
2. **All pair_ap MIT files have explicit headers,** except `pair.h`, `pair-internal.h`, `pair-tlv.h` — **minor omissions.** These are public/internal interfaces with no license text but are clearly part of the MIT cluster.
3. **libairptp: the LICENSE file is explicit MIT (OwnTone 2026), but most .c/.h files in src/ lack headers** — relying on the directory LICENSE. `airptp.c`, `daemon.c`, and `airptpd.c` DO have explicit MIT headers. Others assume MIT by inheritance.
4. **evrtsp: rtsp.c and evrtsp.h have full BSD (Provos + Blache), but rtsp-internal.h lacks the license text** — only copyright notice, but contextually BSD.
5. **ptpd.h and outputs.h have NO license headers.** These are OwnTone infrastructure layers. Since they will be REPLACED with shims in AirPlayEngine, this is **acceptable**; the replacement shims will be GPL-2.0+ under the new project.

### No Unexpected or Conflicting Licenses

✓ **No GPL-incompatible licenses found.** All MIT and BSD licenses are compatible with GPL-2.0+.  
✓ **No third-party embedded SRP/TLV code violations.** pair_ap correctly credits csrp (Cocagne, MIT) and esp-homekit (maximkulkin, MIT).

---

## GPL-2.0-or-later Distribution Obligations

When the AirPlayEngine (and the full Audiouted app) is distributed under GPL-2.0-or-later, the following apply:

### 1. Header Preservation
- Every .c and .h file from the GPL cluster (airplay.c, airplay_events.c, rtp_common.c) **must retain its GPL-2.0+ header** in the distributed source.
- Every BSD file (evrtsp/rtsp.c, evrtsp/*.h) **must retain its BSD header** with full copyright/disclaimer.
- Every MIT file (pair_ap/*, libairptp/*) **must retain its MIT header** with full copyright notice.
- Files without explicit headers (rtp_common.h, libairptp internal files, pair_ap internal files) **must have headers added or clarified** in the distribution. Recommended: add explicit SPDX header matching the cluster (e.g., `// SPDX-License-Identifier: GPL-2.0-or-later` for OwnTone plumbing; `// SPDX-License-Identifier: MIT` for pair_ap/libairptp).

### 2. Source Availability
- The complete source code of the GPL-licensed sender (airplay.c + cluster) **must be provided** in the distribution or available by request.
- No GPL source obfuscation is permitted.

### 3. NOTICE / THIRD-PARTY File
A `NOTICE` file (or `THIRD-PARTY-LICENSES`, `ATTRIBUTION`) **must list:**
- **GPL-2.0-or-later** — AirPlayEngine + Audiouted Core
  - Copyright: Alec Henderson (or the named project holder)
  - Source: Audiouted repository
  - Includes OwnTone-derived code (airplay.c, rtp_common.c) — see individual files for original copyright.
- **OwnTone GPL-2.0-or-later Components** (for historical record)
  - airplay.c — OwnTone Project
  - airplay_events.c — OwnTone Project
  - rtp_common.c — Copyright (C) 2019- Espen Jürgensen; OwnTone Project
  - (Note: distribution does not name OwnTone product; headers retain "OwnTone Project" copyright.)
- **evrtsp (BSD-2-Clause)** — Based on libevent
  - rtsp.c, evrtsp.h, log.h, rtsp-internal.h
  - Copyright (C) 2010 Julien BLACHE (libevhttp adaptation)
  - Copyright (c) 2000-2006 Niels Provos (original libevent code)
  - BSD 2/3-clause license (see `src/evrtsp/rtsp.c` for full text)
- **pair_ap (MIT)** — OwnTone Project / adapted works
  - pair.c, pair.h, pair_fruit.c, pair_homekit.c, pair-tlv.c, pair-tlv.h, pair-internal.h
  - MIT License
  - Includes adaptations of Tom Cocagne's csrp (SRP6a) and maximkulkin's esp-homekit (TLV)
- **libairptp (MIT)** — OwnTone Project
  - airptp.h, src/airptp.c, src/daemon.c, daemon/airptpd.c, and supporting files
  - Copyright (c) 2026 OwnTone
  - MIT License (separable; PTP helper daemon can be shipped as standalone MIT binary)

### 4. Combined Work
The **entire linked application** (Audiouted + AirPlayEngine + system libraries) falls under GPL-2.0-or-later due to the GPL sender cluster. This is a **deliberate design choice per RESOLVED DECISION Q4**; no accident.

The MIT and BSD components are compatible and do not "contaminate" the license — their original headers must be preserved, and their authors credited, but the GPL-2.0+ obligation covers the whole work.

### 5. PTP Helper Binary (Special Case)
The tiny SMAppService daemon (`libairptp` in shared-daemon mode, via `airptpd.c`) **can ship as a separate MIT-licensed binary** alongside the GPL app. Since it:
- Does NOT link GPL sender code (airplay.c cluster)
- IS purely libairptp (MIT)
- Has its own LICENSE and copyright (OwnTone 2026)

It is **severable** under GPL-2.0 Section 3. The daemon can be redistributed under MIT alone if desired. However, if bundled as part of the app distribution, it inherits the GPL-2.0+ notice (but retains its original MIT header for clarity).

---

## Recommended LICENSE / NOTICE File Layout

### Directory: `/AirPlayEngine/`

**File: `LICENSE`** (or `COPYING`)
```
This file describes the licensing terms for the Audiouted project
and its components.

Audiouted AirPlayEngine is licensed under the GNU General Public
License, version 2 or later (GPL-2.0-or-later).

See the LICENSE-COMPONENT.md or NOTICE file for detailed attribution and
component-specific licensing, including third-party code under MIT and BSD.
```

**File: `NOTICE` (or `THIRD-PARTY-LICENSES.md`)**
```markdown
# Third-Party Licenses and Attribution

## Audiouted / AirPlayEngine

The Audiouted project is licensed under **GPL-2.0-or-later**.
See the top-level LICENSE or COPYING file for the full GPL v2 text.

### Component Licensing

#### GNU General Public License (GPL-2.0+) Components

- **AirPlayEngine C Core** (sender implementation)
  - Files: `src/outputs/airplay.c`, `src/outputs/airplay_events.c`, `src/outputs/rtp_common.c`, `src/outputs/rtp_common.h`
  - Derived from OwnTone Server (https://github.com/owntone/owntone-server)
  - GPL-2.0-or-later license
  - Copyright notice retained in each file

#### BSD-Licensed Components (Compatible)

- **evrtsp RTSP Protocol Implementation**
  - Files: `src/evrtsp/rtsp.c`, `src/evrtsp/evrtsp.h`, `src/evrtsp/log.h`, `src/evrtsp/rtsp-internal.h`
  - Based on libevent's evhttp
  - Copyright (C) 2010 Julien BLACHE <jb@jblache.org>
  - Copyright (c) 2000-2006 Niels Provos <provos@citi.umich.edu>
  - BSD 2/3-Clause License (see source files for full disclaimer)
  - Redistribution in source and binary form permitted with conditions (see source)

#### MIT-Licensed Components (Compatible)

- **pair_ap AirPlay 2 Pairing**
  - Directory: `src/pair_ap/`
  - Files: `pair.c`, `pair.h`, `pair_fruit.c`, `pair_homekit.c`, `pair-internal.h`, `pair-tlv.c`, `pair-tlv.h`
  - MIT License (full text in source files)
  - Includes adaptations of:
    - Tom Cocagne's csrp (Secure Remote Password 6a) — MIT
    - maximkulkin's esp-homekit (TLV encoding) — MIT
    - ViktoriiaKh's ap2-sender (HomeKit integration) — MIT
  - Copyright notices retained in source files

- **libairptp PTP Daemon (MIT, Separable)**
  - Directory: `src/libairptp/`
  - Files: `airptp.h`, `src/airptp.c`, `src/daemon.c`, `daemon/airptpd.c`, supporting headers
  - MIT License — see `src/libairptp/LICENSE`
  - Copyright (c) 2026 OwnTone
  - **Note:** This component is severable and can be redistributed as a standalone MIT-licensed binary (e.g., SMAppService launchd daemon)
  - Supporting files without explicit headers inherit MIT from directory LICENSE

### Summary

This project combines:
- **GPL-2.0-or-later** sender (OwnTone-derived)
- **BSD-2/3-Clause** RTSP layer (compatible with GPL)
- **MIT** pairing and PTP (compatible with GPL)

All components retain their original copyright notices and license text.
For the full GPL-2.0 text, see the repository's top-level LICENSE or COPYING file.
```

---

## Files for Inclusion in Distribution

**Recommended directory structure for a distribution:**

```
Audiouted/
  LICENSE                    (GNU General Public License v2)
  COPYING                    (Full GPL-2.0 text)
  NOTICE                     (Third-party attribution, as above)
  
  AirPlayEngine/
    LICENSE                  (Pointer to top-level + note on components)
    Sources/CAirPlayEngine/
      src/outputs/
        airplay.c            (RETAINS GPL-2.0+ header)
        airplay.c.license    (Optional: side-car SPDX metadata)
        airplay_events.c     (RETAINS GPL-2.0+ header)
        rtp_common.c         (RETAINS GPL-2.0+ header + Espen Jürgensen copyright)
        rtp_common.h         (ADD explicit GPL-2.0+ header if missing)
      src/evrtsp/
        rtsp.c               (RETAINS BSD header)
        evrtsp.h             (RETAINS BSD header)
        log.h                (RETAINS BSD header)
        rtsp-internal.h      (RETAINS or ADD BSD header)
      src/pair_ap/
        pair.c               (RETAINS MIT header)
        pair.h               (ADD explicit MIT header if missing)
        pair_fruit.c         (RETAINS MIT header + Tom Cocagne credit)
        pair_homekit.c       (RETAINS MIT header + credits)
        pair-internal.h      (ADD explicit MIT header if missing)
        pair-tlv.c           (RETAINS MIT header + esp-homekit credit)
        pair-tlv.h           (ADD explicit MIT header if missing)
      src/libairptp/
        LICENSE              (MIT)
        airptp.h             (ADD explicit MIT header if missing)
        src/airptp.c         (RETAINS MIT header)
        src/daemon.c         (RETAINS MIT header)
        daemon/airptpd.c     (RETAINS MIT header)
        [other libairptp files — ADD explicit MIT header if missing]
```

---

## Audit Checklist for Distribution

- [ ] Every GPL file retains original header (`This program is free software...`)
- [ ] Every BSD file retains original header (Provos/Blache copyright + disclaimer)
- [ ] Every MIT file retains original header (MIT License text)
- [ ] Files without headers in source tree have headers added (recommend SPDX-License-Identifier)
- [ ] NOTICE file lists all contributors and component licenses
- [ ] Top-level LICENSE or COPYING file provides full GPL-2.0 text
- [ ] Source code is available (via repository or fulfillment process)
- [ ] libairptp can be identified as severable and redistributable under MIT alone
- [ ] ptpd.h and outputs.h notes record that they are replaced by GPL shims in AirPlayEngine

---

## Next Steps (for Distribution Phase)

1. **Add SPDX headers** to files without explicit license text (pair_ap headers, libairptp internal files, evrtsp/rtsp-internal.h).
   - Example: `// SPDX-License-Identifier: MIT` (for pair_ap, libairptp) or `// SPDX-License-Identifier: GPL-2.0-or-later` (for rtp_common.h).

2. **Create top-level NOTICE file** (in the project root) with the attribution template above.

3. **Record in SPEC.md** that:
   - The project is GPL-2.0-or-later.
   - libairptp is severable and MIT-licensed.
   - All third-party code is credited per component.

4. **Update .gitignore** to include the generated `AirPlayEngine/build/` and `AirPlayEngine/.build/` directories (not source).

5. **When the PTP helper daemon is implemented** (Phase 2, T-HELPER-DESIGN-1 → SMAppService), document that it:
   - Links only libairptp (MIT) and system frameworks.
   - Can ship with its own MIT license copy.
   - Does NOT include GPL sender code.

---

## Conclusion

**No showstoppers found.** All assumptions in PLAN-PHASE-2.md Q4 are confirmed:
- GPL-2.0+ cluster is GPL-2.0+. ✓
- pair_ap is MIT. ✓
- libairptp is MIT. ✓
- evrtsp is BSD. ✓

The combined work falls under GPL-2.0-or-later, and all components are compatible. Distribution is compliant when headers are retained and NOTICE is provided.
