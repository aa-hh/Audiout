// SPDX-License-Identifier: GPL-2.0-or-later
//
// misc.c — REAL shim bodies (T-SHIM-2).
//
// The net helpers, keyval (TXT) parser, safe_hextou32/64, thread_setname and
// uuid_make below are PORTED near-verbatim from OwnTone's src/misc.c (GPL-2.0-
// or-later, Copyright (C) 2009-2010 Julien BLACHE <jb@jblache.org>, plus code
// in the public domain / adapted from mt-daapd as noted in the upstream file
// header). Only the subset the vendored AirPlay sender cluster calls is kept,
// and the bodies are trimmed to the macOS build (the __APPLE__ branch of
// net_mac_get; the pthread_setname_np(name) macOS form of thread_setname).
//
// Provenance per function:
//   net_address_get / net_sockaddr_get / net_port_get / net_if_get /
//   net_mac_get / net_connect / net_socket_close / net_bind  — OwnTone misc.c.
//   keyval_alloc/add/get/clear                                — OwnTone misc.c.
//   safe_hextou32/64                                          — OwnTone misc.c.
//   thread_setname / uuid_make                                — OwnTone misc.c.
//   quality_is_equal / log_fatal_null                         — already-real (kept).
//
// Deviations from upstream (documented so the port is reproducible):
//   * net_port_get is a private static helper here (airplay.c doesn't call it,
//     but net_bind/net_if_get need it).
//   * The "ipv6" config gate (cfg_getbool(cfg_getsec(cfg,"general"),"ipv6"))
//     is preserved; conffile.c now returns true for it so v6 is attempted
//     (PTP peers can be link-local v6). See conffile.c.
//   * uuid_make uses the dependency-free PRNG variant (OwnTone's #else branch)
//     so we don't need to link libuuid.
//
// TODO(seam-map §10.4): net_if_get / the %ifname v6 link-local scope handling
// is Linux-validated in OwnTone; macOS scope-id semantics still need a live
// ipv6 receiver to confirm (that is T-API-1 / the receiver harness, not here).

#include "misc.h"
#include "logger.h"
#include "conffile.h" /* cfg_getbool/cfg_getstr for the ipv6 + bind_address gates */

#include <stdlib.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <limits.h>
#include <inttypes.h> /* PRIX16 in uuid_make */
#include <time.h>
#include <fcntl.h>
#include <poll.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <pthread.h>
#include <sys/socket.h>
#include <net/if_dl.h> /* struct sockaddr_dl / LLADDR (macOS AF_LINK) */

/* ---------------------------- Network utilities --------------------------- */

int
net_address_get(char *addr, size_t addr_len, union net_sockaddr *naddr)
{
  const char *s = NULL;

  memset(addr, 0, addr_len); // Just in case caller doesn't check for errors

  if (naddr->sa.sa_family == AF_INET6)
    s = inet_ntop(AF_INET6, &naddr->sin6.sin6_addr, addr, addr_len);
  else if (naddr->sa.sa_family == AF_INET)
    s = inet_ntop(AF_INET, &naddr->sin.sin_addr, addr, addr_len);

  if (!s)
    return -1;

  return 0;
}

int
net_sockaddr_get(union net_sockaddr *naddr, const char *addr, unsigned short port)
{
  memset(naddr, 0, sizeof(union net_sockaddr));

  if (inet_pton(AF_INET, addr, &naddr->sin.sin_addr) == 1)
    {
      naddr->sin.sin_family = AF_INET;
      naddr->sin.sin_port = htons(port);
      return 0;
    }

  if (cfg_getbool(cfg_getsec(cfg, "general"), "ipv6") && inet_pton(AF_INET6, addr, &naddr->sin6.sin6_addr) == 1)
    {
      naddr->sin6.sin6_family = AF_INET6;
      naddr->sin6.sin6_port = htons(port);
      return 0;
    }

  return -1;
}

static int
net_port_get(unsigned short *port, union net_sockaddr *naddr)
{
  if (naddr->sa.sa_family == AF_INET6)
    *port = ntohs(naddr->sin6.sin6_port);
  else if (naddr->sa.sa_family == AF_INET)
    *port = ntohs(naddr->sin.sin_port);
  else
    return -1;

  return 0;
}

int
net_if_get(char *ifname, size_t ifname_len, const char *addr)
{
  struct ifaddrs *ifaddrs = NULL;
  struct ifaddrs *iap;
  char s[64];

  memset(ifname, 0, ifname_len);

  if (getifaddrs(&ifaddrs) < 0)
    return -1;

  for (iap = ifaddrs; iap; iap = iap->ifa_next)
    {
      if (!iap->ifa_addr)
        continue;

      if (net_address_get(s, sizeof(s), (union net_sockaddr *)iap->ifa_addr) < 0)
        continue;

      if (strcmp(s, addr) != 0)
        continue;

      snprintf(ifname, ifname_len, "%s", iap->ifa_name);
      break;
    }

  freeifaddrs(ifaddrs);

  return (ifname[0] != 0) ? 0 : -1;
}

int
net_mac_get(uint8_t *mac, size_t mac_size, const char *ifname)
{
#define MAC_LENGTH 6
  struct ifaddrs *ifap, *ifaptr;
  struct sockaddr_dl *sdl;

  if (mac_size < MAC_LENGTH || !ifname)
    return -1;

  if (getifaddrs(&ifap) != 0)
    return -1;

  for (ifaptr = ifap; ifaptr != NULL; ifaptr = ifaptr->ifa_next)
    {
      if (ifaptr->ifa_addr && strcmp(ifaptr->ifa_name, ifname) == 0 && ifaptr->ifa_addr->sa_family == AF_LINK)
        {
          sdl = (struct sockaddr_dl *)ifaptr->ifa_addr;
          memcpy(mac, LLADDR(sdl), MAC_LENGTH);
          freeifaddrs(ifap);
          return 0;
        }
    }

  freeifaddrs(ifap);
  return -1;
#undef MAC_LENGTH
}

static int
net_connect_addrinfo(struct addrinfo *ai, int timeout_ms, bool set_nonblock, const char **errmsg)
{
  int fd = -1;
  int flags;
  struct pollfd pollfd;
  socklen_t len;
  int error;
  int ret;

  fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
  if (fd < 0)
    {
      *errmsg = strerror(errno);
      goto error;
    }

  // For Linux we could just give SOCK_CLOEXEC to socket(), but that won't work
  // with MacOS, so we have to use fcntl()
  flags = fcntl(fd, F_GETFL, 0);
  if (flags < 0)
    {
      *errmsg = "fcntl() with F_GETFL returned an error";
      goto error;
    }

  ret = fcntl(fd, F_SETFL, flags | O_NONBLOCK | O_CLOEXEC);
  if (ret < 0)
    {
      *errmsg = "fcntl() with F_SETFL non-block returned an error";
      goto error;
    }

  ret = connect(fd, ai->ai_addr, ai->ai_addrlen);
  if (ret < 0 && errno != EINPROGRESS)
    {
      *errmsg = strerror(errno);
      goto error;
    }
  else if (ret != 0)
    {
      pollfd.fd = fd;
      pollfd.events = POLLOUT;

      ret = poll(&pollfd, 1, timeout_ms);
      if (ret < 0)
        {
          *errmsg = strerror(errno);
          goto error;
        }
      else if (ret == 0)
        {
          *errmsg = "Timed out trying to connect";
          goto error;
        }

      len = sizeof(error);
      ret = getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &len);
      if (ret < 0 || error)
        {
          *errmsg = error ? strerror(error) : strerror(errno);
          goto error;
        }
    }

  if (!set_nonblock)
    {
      ret = fcntl(fd, F_SETFL, flags | O_CLOEXEC);
      if (ret < 0)
        {
          *errmsg = "fcntl() with F_SETFL block returned an error";
          goto error;
        }
    }

  return fd;

 error:
  if (fd >= 0)
    close(fd);

  return -1;
}

int
net_connect(const char *addr, unsigned short port, int type, const char *log_service_name)
{
  struct addrinfo hints = { 0 };
  struct addrinfo *servinfo;
  struct addrinfo *ai;
  char strport[8];
  const char *errmsg = NULL;
  int fd = -1;
  int ret;

  DPRINTF(E_DBG, L_MISC, "Connecting to '%s' at %s (port %u)\n", log_service_name, addr, port);

  hints.ai_socktype = type;
  hints.ai_family = (cfg_getbool(cfg_getsec(cfg, "general"), "ipv6")) ? AF_UNSPEC : AF_INET;

  snprintf(strport, sizeof(strport), "%hu", port);
  ret = getaddrinfo(addr, strport, &hints, &servinfo);
  if (ret != 0)
    {
      DPRINTF(E_LOG, L_MISC, "Could not get '%s' address info for %s (port %u): %s\n", log_service_name, addr, port, gai_strerror(ret));
      return -1;
    }

  for (ai = servinfo; ai && fd < 0; ai = ai->ai_next)
    fd = net_connect_addrinfo(ai, NET_CONNECT_TIMEOUT_MS, false, &errmsg);

  freeaddrinfo(servinfo);

  if (fd < 0)
    {
      DPRINTF(E_LOG, L_MISC, "Could not connect to '%s' at %s (port %u): %s\n", log_service_name, addr, port, errmsg ? errmsg : "unknown error");
      return -1;
    }

  return fd;
}

void
net_socket_close(struct net_socket *socket)
{
  if (!socket)
    return;

  if (socket->fd4 >= 0)
    close(socket->fd4);
  if (socket->fd6 >= 0)
    close(socket->fd6);

  socket->fd4 = -1;
  socket->fd6 = -1;
}

// If *port is 0 then a random port will be assigned, and *port will be updated
// with the port number. SOCK_STREAM type services are set to use non-blocking
// sockets.
static int
bind_one(const char *node, unsigned short *port, int type, int family, const char *log_service_name)
{
  struct addrinfo hints = { 0 };
  struct addrinfo *servinfo;
  struct addrinfo *ptr;
  union net_sockaddr naddr = { 0 };
  socklen_t naddr_len = sizeof(naddr);
  char addr[INET6_ADDRSTRLEN];
  char strport[8];
  int flags;
  int yes = 1;
  int no = 0;
  int fd = -1;
  int ret;

  hints.ai_socktype = type;
  hints.ai_family = family;
  hints.ai_flags = node ? 0 : AI_PASSIVE;

  snprintf(strport, sizeof(strport), "%hu", *port);
  ret = getaddrinfo(node, strport, &hints, &servinfo);
  if (ret != 0)
    {
      DPRINTF(E_LOG, L_MISC, "Failure creating '%s' service, could not resolve '%s' (port %s): %s\n", log_service_name, node ? node : "(ANY)", strport, gai_strerror(ret));
      return -1;
    }

  for (ptr = servinfo; ptr != NULL; ptr = ptr->ai_next)
    {
      if (fd >= 0)
        close(fd);

      fd = socket(ptr->ai_family, ptr->ai_socktype, ptr->ai_protocol);
      if (fd < 0)
        continue;

      flags = fcntl(fd, F_GETFL, 0);
      if (flags < 0)
        continue;
      ret = fcntl(fd, F_SETFL, (type == SOCK_STREAM) ? flags | O_NONBLOCK | O_CLOEXEC : flags | O_CLOEXEC);
      if (ret < 0)
        continue;

      // For udp, only one socket should get the messages, so REUSEPORT off.
      ret = setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &no, sizeof(int));
      if (ret < 0)
        continue;

      ret = setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &yes, sizeof(yes));
      if (ret < 0)
        continue;

      // For tcp, SO_REUSEADDR means the server can restart quickly.
      ret = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, (type == SOCK_STREAM) ? &yes : &no, sizeof(int));
      if (ret < 0)
        continue;

      // No dual stack (doesn't work on MacOS/BSD). Turn it off explicitly.
      ret = (ptr->ai_family == AF_INET6) ? setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &yes, sizeof(int)) : 0;
      if (ret < 0)
        continue;

      ret = bind(fd, ptr->ai_addr, ptr->ai_addrlen);
      if (ret < 0)
        continue;

      break;
    }

  freeaddrinfo(servinfo);

  if (!ptr)
    {
      DPRINTF(E_LOG, L_MISC, "Could not create service '%s' with address %s, port %hu: %s\n", log_service_name, node ? node : "(ANY)", *port, strerror(errno));
      goto error;
    }

  // Get our address and the port that was assigned (necessary when caller
  // didn't specify a port)
  ret = getsockname(fd, &naddr.sa, &naddr_len);
  if (ret < 0)
    {
      DPRINTF(E_LOG, L_MISC, "Error finding address of service '%s': %s\n", log_service_name, strerror(errno));
      goto error;
    }
  else if (naddr_len > sizeof(naddr))
    {
      DPRINTF(E_LOG, L_MISC, "Unexpected address length of service '%s'\n", log_service_name);
      goto error;
    }

  net_port_get(port, &naddr);
  net_address_get(addr, sizeof(addr), &naddr);

  DPRINTF(E_DBG, L_MISC, "Service '%s' bound to %s, port %hu, socket %d\n", log_service_name, addr, *port, fd);

  return fd;

 error:
  if (fd >= 0)
    close(fd);
  return -1;
}

int
net_bind(struct net_socket *socket, unsigned short *port, int type, const char *log_service_name)
{
  const char *bind_address = cfg_getstr(cfg_getsec(cfg, "general"), "bind_address");
  bool v6_enabled = cfg_getbool(cfg_getsec(cfg, "general"), "ipv6");

  // For "::" listen on both ipv4 and ipv6.
  if (bind_address && strcmp(bind_address, "::") == 0)
    bind_address = NULL;

  socket->fd4 = -1;
  socket->fd6 = -1;

  if (v6_enabled)
    {
      socket->fd6 = bind_one(bind_address, port, type, AF_INET6, log_service_name);
      if (socket->fd6 < 0)
        {
          DPRINTF(E_LOG, L_MISC, "Could not bind service '%s' for IPv6, falling back to IPv4\n", log_service_name);
          v6_enabled = false;
        }
    }

  socket->fd4 = bind_one(bind_address, port, type, AF_INET, log_service_name);
  if (socket->fd4 < 0)
    {
      if (!v6_enabled)
        return -1;

      DPRINTF(E_LOG, L_MISC, "Could not bind service '%s' for IPv4, listening on IPv6 only\n", log_service_name);
    }

  return 0;
}

/* ------------------------------ Conversions ------------------------------- */

int
safe_hextou32(const char *str, uint32_t *val)
{
  char *end;
  unsigned long intval;

  if (str == NULL)
    {
      DPRINTF(E_SPAM, L_MISC, "Input to safe_hextou32 is NULL\n");
      return -1;
    }

  errno = 0;
  intval = strtoul(str, &end, 16);

  if (((errno == ERANGE) && (intval == ULONG_MAX))
      || ((errno != 0) && (intval == 0)))
    {
      DPRINTF(E_DBG, L_MISC, "Invalid u32 in string (%s): %s\n", str, strerror(errno));
      return -1;
    }

  if (end == str)
    {
      DPRINTF(E_DBG, L_MISC, "No u32 found in string (%s)\n", str);
      return -1;
    }

  if (intval > UINT32_MAX)
    {
      DPRINTF(E_DBG, L_MISC, "u32 value out of range (%s)\n", str);
      return -1;
    }

  *val = (uint32_t)intval;

  return 0;
}

int
safe_hextou64(const char *str, uint64_t *val)
{
  char *end;
  unsigned long long intval;

  if (str == NULL)
    {
      DPRINTF(E_SPAM, L_MISC, "Input to safe_hextou64 is NULL\n");
      return -1;
    }

  errno = 0;
  intval = strtoull(str, &end, 16);

  if (((errno == ERANGE) && (intval == ULLONG_MAX))
      || ((errno != 0) && (intval == 0)))
    {
      DPRINTF(E_DBG, L_MISC, "Invalid u64 in string (%s): %s\n", str, strerror(errno));
      return -1;
    }

  if (end == str)
    {
      DPRINTF(E_DBG, L_MISC, "No u64 found in string (%s)\n", str);
      return -1;
    }

  *val = (uint64_t)intval;

  return 0;
}

/* ---------------------------- Key/value (TXT) ----------------------------- */

struct keyval *
keyval_alloc(void)
{
  struct keyval *kv;

  kv = calloc(1, sizeof(struct keyval));
  if (!kv)
    {
      DPRINTF(E_LOG, L_MISC, "Out of memory for keyval alloc\n");
      return NULL;
    }

  return kv;
}

static int
keyval_add_size(struct keyval *kv, const char *name, const char *value, size_t size)
{
  struct onekeyval *okv;
  const char *val;

  if (!kv || !name || !value)
    return -1;

  /* Check for duplicate key names */
  val = keyval_get(kv, name);
  if (val)
    {
      /* Same value, fine */
      if (strcmp(val, value) == 0)
        return 0;
      else /* Different value, bad */
        return -1;
    }

  okv = (struct onekeyval *)malloc(sizeof(struct onekeyval));
  if (!okv)
    {
      DPRINTF(E_LOG, L_MISC, "Out of memory for new keyval\n");
      return -1;
    }

  okv->name = strdup(name);
  if (!okv->name)
    {
      DPRINTF(E_LOG, L_MISC, "Out of memory for new keyval name\n");
      free(okv);
      return -1;
    }

  okv->value = (char *)malloc(size + 1);
  if (!okv->value)
    {
      DPRINTF(E_LOG, L_MISC, "Out of memory for new keyval value\n");
      free(okv->name);
      free(okv);
      return -1;
    }

  memcpy(okv->value, value, size);
  okv->value[size] = '\0';

  okv->next = NULL;
  okv->sort = NULL;

  if (!kv->head)
    kv->head = okv;

  if (kv->tail)
    kv->tail->next = okv;

  kv->tail = okv;

  return 0;
}

int
keyval_add(struct keyval *kv, const char *name, const char *value)
{
  if (!value)
    return -1;
  return keyval_add_size(kv, name, value, strlen(value));
}

const char *
keyval_get(struct keyval *kv, const char *name)
{
  struct onekeyval *okv;

  if (!kv || !name)
    return NULL;

  for (okv = kv->head; okv; okv = okv->next)
    {
      if (strcasecmp(okv->name, name) == 0)
        return okv->value;
    }

  return NULL;
}

void
keyval_clear(struct keyval *kv)
{
  struct onekeyval *hokv;
  struct onekeyval *okv;

  if (!kv)
    return;

  hokv = kv->head;

  for (okv = hokv; hokv; okv = hokv)
    {
      hokv = okv->next;

      free(okv->name);
      free(okv->value);
      free(okv);
    }

  kv->head = NULL;
  kv->tail = NULL;
}

/* ------------------------------ Media quality ----------------------------- */

bool
quality_is_equal(struct media_quality *a, struct media_quality *b)
{
  // Real (trivial) comparison — cheap and correct; airplay.c branches on this
  // to reuse master sessions, so a correct compare is harmless to include now.
  if (!a || !b)
    return false;
  return a->sample_rate == b->sample_rate &&
         a->bits_per_sample == b->bits_per_sample &&
         a->channels == b->channels &&
         a->bit_rate == b->bit_rate;
}

/* -------------------------------- Threads --------------------------------- */

void
thread_setname(const char *name)
{
  // macOS form: pthread_setname_np sets the name of the CALLING thread.
  pthread_setname_np(name);
}

/* --------------------------------- UUID ----------------------------------- */

// Dependency-free variant (OwnTone's #else branch — no libuuid). Produces a
// canonical lowercase-hex v4-ish UUID string (uppercase here, matching
// uuid_unparse_upper). Buffer must be >= 37 bytes (caller's responsibility, as
// in OwnTone).
void
uuid_make(char *str)
{
  uint16_t uuid[8];
  time_t now;
  unsigned int i;

  if (!str)
    return;

  now = time(NULL);
  srand((unsigned int)now);

  for (i = 0; i < ARRAY_SIZE(uuid); i++)
    {
      uuid[i] = (uint16_t)rand();

      // time_hi_and_version, set version to 4 (=random)
      if (i == 3)
        uuid[i] = (uuid[i] & 0x0FFF) | 0x4000;
      // clock_seq, variant 1
      if (i == 4)
        uuid[i] = (uuid[i] & 0x3FFF) | 0x8000;

      if (i == 2 || i == 3 || i == 4 || i == 5)
        str += sprintf(str, "-");

      str += sprintf(str, "%04" PRIX16, uuid[i]);
    }
}

/* -------------------------------- Assertion ------------------------------- */

void
log_fatal_null(int domain, const char *func, int line)
{
  // REAL impl (not a stub): CHECK_NULL relies on this aborting on NULL so the
  // non-NULL guarantee airplay.c assumes holds.
  DPRINTF(E_FATAL, domain, "Out of memory at %s (line %d)\n", func, line);
  abort();
}
