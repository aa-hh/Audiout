// SPDX-License-Identifier: GPL-2.0-or-later
//
// config.h — hand-written replacement for OwnTone's autotools-generated
// config.h (T-BUILD-1). OwnTone generates this via `configure` from
// `configure.ac` / `config.h.in`; we vendor the sender cluster without
// autotools, so we hand-roll only the handful of macros the vendored files
// actually reference.
//
// Referenced by the vendored cluster (grepped at T-BUILD-1):
//   - PACKAGE_NAME              (sender/airplay_events.c:218 RTSP Server: header)
//   - HAVE_DECL_PLIST_NEW_INT   (sender/plist_wrap.h — brew libplist HAS it)
//   - HAVE_LIBKERN_OSBYTEORDER_H (libairptp/src/utils.h endian fallback path)
//   - HAVE_CONFIG_H             (guards config.h inclusion in utils.h; we always
//                                provide config.h so the source that tests it is
//                                fine either way)
//   - HAVE_GETADDRINFO / HAVE_GETNAMEINFO / HAVE_STRSEP: all present on macOS.
//   - HAVE_ENDIAN_H / HAVE_SYS_ENDIAN_H: NOT defined — macOS has neither; the
//     endian helpers come from <libkern/OSByteOrder.h> via compat/endian_compat.h
//     (and via libairptp/src/utils.h's own OSByteOrder fallback, which the
//     HAVE_LIBKERN_OSBYTEORDER_H define below activates).
//
// This is intentionally minimal: only what the extracted files read, not the
// full OwnTone feature matrix.

#ifndef CAIRPLAYENGINE_CONFIG_H
#define CAIRPLAYENGINE_CONFIG_H

// Some vendored sources use limits.h macros (e.g. CHAR_BIT in airplay.c:3881)
// without including <limits.h> themselves — they relied on OwnTone's include
// graph pulling it in transitively. Since config.h is force-included first in
// every TU, providing it here fixes those references portably.
#include <limits.h>

// Neutral product name (SPEC.md §4: zero OwnTone references in the shipped
// product). Sent as the RTSP "Server: <name>/1.0" header string.
#define PACKAGE_NAME "AirPlayEngine"
#define PACKAGE_VERSION "0.1.0"

// brew libplist exposes plist_new_int(int64_t) (confirmed in
// /opt/homebrew/opt/libplist/include/plist/plist.h), so plist_wrap.h can use
// the signed-int path rather than the uint fallback.
#define HAVE_DECL_PLIST_NEW_INT 1

// macOS provides big/little-endian conversion via <libkern/OSByteOrder.h>.
// This activates libairptp/src/utils.h's own OSByteOrder fallback branch.
#define HAVE_LIBKERN_OSBYTEORDER_H 1

// Standard POSIX functions present on macOS 14.
#define HAVE_GETADDRINFO 1
#define HAVE_GETNAMEINFO 1
#define HAVE_STRSEP 1

#endif // CAIRPLAYENGINE_CONFIG_H
