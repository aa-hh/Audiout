# Faithful port of NativeDiscovery.normalizedHostname / handleResolve self-filter
# and NetworkFrameworkBrowser.probeIPv4First's ResolvedService construction.
FIXED = False
LOCAL_ADDRS = {"192.168.1.20"}  # this Mac's interface addresses (getifaddrs) - used only by the fix

def normalized_hostname(h):
    l = h.lower()
    return l[:-1] if l.endswith(".") else l

def probe_ipv4_first_emit(name, address, port, txt, service_type):
    # NativeDiscovery.swift:1033-1041 : hostname: name
    return dict(serviceType=service_type, name=name, hostname=name, address=address, port=port, txt=txt)

class NativeDiscovery:
    def __init__(self, local_hostname):
        self.local_hostname = normalized_hostname(local_hostname) if local_hostname else None
        self.entries = []
    def handle_resolve(self, s):
        if self.local_hostname is not None and normalized_hostname(s["hostname"]) == self.local_hostname:
            return "dropped"
        if FIXED and s["address"] in LOCAL_ADDRS:
            return "dropped"
        self.entries.append(s)
        return "surfaced"
