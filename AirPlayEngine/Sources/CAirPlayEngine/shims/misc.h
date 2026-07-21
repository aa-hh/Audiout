// SPDX-License-Identifier: GPL-2.0-or-later
//
// misc — SHIM (2 of 10). Replaces OwnTone's src/misc.h (partial reimplementation).
//
// Implements: docs/seam-map.md §3.3 "misc — misc.h (SHIM partial, ~250-350 LOC)".
// Only the helpers the vendored cluster (airplay.c / rtp_common.c /
// airplay_events.c) actually calls are declared here — verified by grep at
// T-BUILD-1:
//   net helpers:  net_bind, net_connect, net_socket_close, net_sockaddr_get,
//                 net_address_get, net_if_get, net_mac_get (+ struct net_socket,
//                 union net_sockaddr)
//   device_id:    device_id_colon_parse, device_id_colon_make, device_id_hex
//   keyval:       keyval_alloc, keyval_add, keyval_get, keyval_clear
//                 (+ struct keyval, struct onekeyval)
//   safe conv:    safe_hextou32, safe_hextou64
//   quality:      quality_is_equal, enum media_format, struct media_quality
//   thread:       thread_setname
//   misc:         uuid_make
//   macros:       STOB, ARRAY_SIZE, CHECK_NULL
//
// SIGNATURES ARE COPIED FROM OwnTone src/misc.h VERBATIM (only the declared
// subset) so every call site in the cluster resolves against the exact
// prototype it was written for. macOS portability: the endian helper macros
// (htobe*/be*toh) come from compat/endian_compat.h rather than <endian.h>.
//
// STUB STATUS (T-BUILD-1): the .c bodies (misc.c) are MINIMAL stubs — the
// net_*/keyval_*/device_id_*/safe_*/quality/uuid functions currently return
// error/empty (or a trivially-safe value) with TODO(T-SHIM-1) markers so the
// link succeeds. They do NOT yet implement real socket binding, TXT parsing,
// or id conversion — that is T-SHIM-1 (seam-map §3.3, incl. macOS scope-id
// handling for net_if_get, risk from seam-map §10.4).
//
// TODO(T-SHIM-1): implement misc.c bodies for real (BSD sockets w/ macOS
// scope-id care, keyval linked list, device_id string<->u64, hex parsers,
// quality_is_equal, uuid_make).

#ifndef CAIRPLAYENGINE_SHIM_MISC_H
#define CAIRPLAYENGINE_SHIM_MISC_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <sys/socket.h>
#include <netinet/in.h>

/* macOS endian helpers (htobe16/32/64, be16toh/32toh/64toh) — replaces the
 * Linux <endian.h> branch of OwnTone's misc.h. Files that include misc.h
 * (rtp_common.c, airplay.c) get the glibc-named macros through here.
 * File-relative path (shims/ -> ../compat/) so this resolves both when the C
 * sources compile AND when clang parses the module map for `import
 * CAirPlayEngine` (that context only has the publicHeaders path, not the C
 * target's headerSearchPaths). */
#include "../compat/endian_compat.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------- Network utilities --------------------------- */

#define NET_CONNECT_TIMEOUT_MS 3000
#define NET_SOCKET_INIT {-1, -1}

struct net_socket
{
  int fd4;
  int fd6;
};

union net_sockaddr
{
  struct sockaddr_in sin;
  struct sockaddr_in6 sin6;
  struct sockaddr sa;
  struct sockaddr_storage ss;
};

int
net_address_get(char *addr, size_t addr_len, union net_sockaddr *naddr);

int
net_sockaddr_get(union net_sockaddr *naddr, const char *addr, unsigned short port);

int
net_if_get(char *ifname, size_t ifname_len, const char *addr);

int
net_mac_get(uint8_t *mac, size_t mac_size, const char *ifname);

// Returns the socket fd from socket(), -1 on error
int
net_connect(const char *addr, unsigned short port, int type, const char *log_service_name);

void
net_socket_close(struct net_socket *socket);

int
net_bind(struct net_socket *socket, unsigned short *port, int type, const char *log_service_name);

/* ------------------------ Conversion / byte-order ------------------------- */

// Samples to bytes
#define STOB(s, bits, c) ((s) * (c) * (bits) / 8)
#define BTOS(b, bits, c) ((b) / ((c) * (bits) / 8))

#define ARRAY_SIZE(x) ((unsigned int)(sizeof(x) / sizeof((x)[0])))

#ifndef MIN
# define MIN(a, b) (((a) < (b)) ? (a) : (b))
#endif
#ifndef MAX
# define MAX(a, b) (((a) > (b)) ? (a) : (b))
#endif

int
safe_hextou32(const char *str, uint32_t *val);

int
safe_hextou64(const char *str, uint64_t *val);

/* [AirPlayEngine vendored change 2026-07-19] Added for the RAOP (AirPlay 1)
 * sender (sender/raop.c). It parses decimal SETUP transport ports and the
 * sr/ss/ch quality TXT values; airplay.c never needed it (it uses the hex
 * parsers). Ported near-verbatim from OwnTone misc.c. */
int
safe_atoi32(const char *str, int32_t *val);

/* [AirPlayEngine vendored change 2026-07-19] Added for the RAOP sender's SDP
 * handshake (sender/raop.c): the RSA-wrapped AES key (a=rsaaeskey), the AES IV
 * (a=aesiv) and the Apple-Challenge are all base64-encoded. airplay.c's
 * plist-based path never needed base64. Standard RFC-4648 (with '=' padding;
 * raop.c strips the padding itself). Returns a malloc'd NUL-terminated string
 * the caller frees, or NULL on allocation failure. */
char *
b64_encode(const uint8_t *src, int srclen);

/* ---------------------------- Key/value (TXT) ----------------------------- */

struct onekeyval {
  char *name;
  char *value;

  struct onekeyval *next;
  struct onekeyval *sort;
};

struct keyval {
  struct onekeyval *head;
  struct onekeyval *tail;
};

struct keyval *
keyval_alloc(void);

int
keyval_add(struct keyval *kv, const char *name, const char *value);

const char *
keyval_get(struct keyval *kv, const char *name);

void
keyval_clear(struct keyval *kv);

/* ------------------------------ Media quality ----------------------------- */

// Bit flags for the sake of outputs announcing what they support
enum media_format {
  MEDIA_FORMAT_UNKNOWN = 0,
  MEDIA_FORMAT_PCM     = (1 << 0),
  MEDIA_FORMAT_WAV     = (1 << 1),
  MEDIA_FORMAT_MP3     = (1 << 2),
  MEDIA_FORMAT_ALAC    = (1 << 3),
  MEDIA_FORMAT_OPUS    = (1 << 4),
};

// Remember to adjust quality_is_equal() if adding elements
struct media_quality {
  int sample_rate;
  int bits_per_sample;
  int channels;
  int bit_rate;
};

bool
quality_is_equal(struct media_quality *a, struct media_quality *b);

/* NOTE on device_id helpers: OwnTone's device_id_colon_make/parse and
 * device_id_find_byname are defined STATICALLY inside airplay.c (lines
 * 564/585/609), and `device_id_hex` in airplay.c is a local char[] buffer,
 * NOT a misc.h function. So — contrary to seam-map §3.3's grouping — the misc
 * shim must NOT declare any of them (doing so would clash with airplay.c's own
 * definitions). They stay entirely inside airplay.c. (Confirmed at T-BUILD-1.)
 */

/* -------------------------------- Threads --------------------------------- */
// wrapper for pthread_setname_np/pthread_set_name_np
void
thread_setname(const char *name);

/* --------------------------------- UUID ----------------------------------- */
void
uuid_make(char *str);

/* -------------------------------- Assertion ------------------------------- */
/* CHECK_NULL: OwnTone aborts on NULL. In the shim we keep the same "abort on
 * allocation failure" semantics (real macro, not a stub) so call sites that
 * rely on the non-NULL guarantee behave identically. */
#define CHECK_NULL(d, f) \
  do { \
    if ( (f) == NULL ) \
      log_fatal_null(d, #f, __LINE__); \
  } while(0)

void
log_fatal_null(int domain, const char *func, int line) __attribute__((__noreturn__));

#ifdef __cplusplus
}
#endif

#endif /* CAIRPLAYENGINE_SHIM_MISC_H */
