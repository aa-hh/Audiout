// SPDX-License-Identifier: GPL-2.0-or-later
//
// endian_compat.h — macOS portability shim for glibc/Linux <endian.h>
// host<->big/little-endian helpers (T-BUILD-1).
//
// The vendored cluster (sender/rtp_common.c, sender/airplay.c) uses the
// glibc names htobe16/32/64, be16toh/32toh/64toh, htole*/le*toh. Linux
// provides these via <endian.h>; macOS does NOT ship <endian.h>. macOS's
// equivalents live in <libkern/OSByteOrder.h> (OSSwapHostToBigInt16 etc.).
// This header maps the glibc names onto them.
//
// (libairptp/src/utils.h already carries its own identical OSByteOrder
// fallback, activated by HAVE_LIBKERN_OSBYTEORDER_H in compat/config.h; this
// header covers the sender-cluster files that don't include utils.h. Both
// guard their macro defs so including both is safe.)

#ifndef CAIRPLAYENGINE_ENDIAN_COMPAT_H
#define CAIRPLAYENGINE_ENDIAN_COMPAT_H

#if defined(__APPLE__)

#include <libkern/OSByteOrder.h>

#ifndef htobe16
#define htobe16(x) OSSwapHostToBigInt16(x)
#endif
#ifndef be16toh
#define be16toh(x) OSSwapBigToHostInt16(x)
#endif
#ifndef htole16
#define htole16(x) OSSwapHostToLittleInt16(x)
#endif
#ifndef le16toh
#define le16toh(x) OSSwapLittleToHostInt16(x)
#endif

#ifndef htobe32
#define htobe32(x) OSSwapHostToBigInt32(x)
#endif
#ifndef be32toh
#define be32toh(x) OSSwapBigToHostInt32(x)
#endif
#ifndef htole32
#define htole32(x) OSSwapHostToLittleInt32(x)
#endif
#ifndef le32toh
#define le32toh(x) OSSwapLittleToHostInt32(x)
#endif

#ifndef htobe64
#define htobe64(x) OSSwapHostToBigInt64(x)
#endif
#ifndef be64toh
#define be64toh(x) OSSwapBigToHostInt64(x)
#endif
#ifndef htole64
#define htole64(x) OSSwapHostToLittleInt64(x)
#endif
#ifndef le64toh
#define le64toh(x) OSSwapLittleToHostInt64(x)
#endif

#else /* non-Apple: assume glibc-style <endian.h> */
#include <endian.h>
#endif

#endif /* CAIRPLAYENGINE_ENDIAN_COMPAT_H */
