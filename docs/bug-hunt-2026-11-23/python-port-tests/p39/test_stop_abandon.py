# Port of CompanionServer stopLocked/removeClient/noteApprovalAbandoned + CompanionApprovals.abandonRequest
import sys
FIX = "--fix" in sys.argv

class Conn:
    def __init__(s, srv, cid): s.srv, s.cid, s.cancelled = srv, cid, False
    def cancel(s):
        if s.cancelled: return
        s.cancelled = True
        s.srv.queue.append(lambda: s.srv.removeClient(s.cid))  # .cancelled handler -> queue.async removeClient

class Client:
    def __init__(s, srv, cid, phone): s.id, s.phoneClientID, s.connection = cid, phone, Conn(srv, cid)

class Server:
    def __init__(s): s.pending, s.awaiting, s.clients, s.queue, s.onApprovalAbandoned = {}, {}, {}, [], None
    def drain(s):
        while s.queue: s.queue.pop(0)()
    def stopLocked(s):
        dropped = dict(s.awaiting); s.awaiting.clear()
        for c in dropped.values():
            c.connection.cancel()          # goodbye completion / 250ms backstop cancel
        if FIX:
            for c in dropped.values(): s.noteApprovalAbandoned(c)
    def removeClient(s, cid):
        if cid in s.pending: s.pending.pop(cid); return
        if cid in s.awaiting:
            w = s.awaiting.pop(cid); w.connection.cancel(); s.noteApprovalAbandoned(w); return
        s.clients.pop(cid, None)
    def noteApprovalAbandoned(s, c):
        if c.phoneClientID is None: return
        if any(x.phoneClientID == c.phoneClientID for x in s.awaiting.values()): return
        cb = s.onApprovalAbandoned
        s.queue.append(lambda: cb and cb(c.phoneClientID))

class Approvals:
    def __init__(s): s.pendingDeciders, s.active, s.withdrawn = {}, None, []
    def handleRequest(s, cid): s.pendingDeciders.setdefault(cid, []).append(1); s.active = cid  # prompt shown
    def abandonRequest(s, cid):
        if s.pendingDeciders.pop(cid, None) is None: return
        if s.active == cid: s.withdrawn.append(cid); s.active = None

srv, ap = Server(), Approvals()
srv.onApprovalAbandoned = ap.abandonRequest
c = Client(srv, "conn1", "PHONE-A"); srv.awaiting[c.id] = c; ap.handleRequest("PHONE-A")
srv.stopLocked()   # user turns remote control off: stop(reason: disabled)
srv.drain()
ok = ap.active is None and ap.withdrawn == ["PHONE-A"]
print("fix" if FIX else "current", "active prompt:", ap.active, "withdrawn:", ap.withdrawn, "->", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
