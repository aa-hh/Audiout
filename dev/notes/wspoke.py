#!/usr/bin/env python3
"""Minimal dependency-free WebSocket client to poke the companion server.
Sends a hello, then prints every frame the server returns until timeout.
Usage: wspoke.py <port> <clientID>
"""
import socket, os, base64, hashlib, struct, sys, json, time

port = int(sys.argv[1])
client_id = sys.argv[2]

s = socket.create_connection(("127.0.0.1", port), timeout=10)
key = base64.b64encode(os.urandom(16)).decode()
req = (
    f"GET / HTTP/1.1\r\n"
    f"Host: localhost:{port}\r\n"
    f"Upgrade: websocket\r\n"
    f"Connection: Upgrade\r\n"
    f"Sec-WebSocket-Key: {key}\r\n"
    f"Sec-WebSocket-Version: 13\r\n\r\n"
)
s.sendall(req.encode())

# read HTTP handshake response up to \r\n\r\n
buf = b""
while b"\r\n\r\n" not in buf:
    chunk = s.recv(4096)
    if not chunk:
        print("HANDSHAKE: connection closed before response"); sys.exit(1)
    buf += chunk
status = buf.split(b"\r\n", 1)[0].decode(errors="replace")
print("HANDSHAKE:", status)
if "101" not in status:
    print("  full:", buf.decode(errors="replace")[:300]); sys.exit(1)
leftover = buf.split(b"\r\n\r\n", 1)[1]

def send_text(payload: str):
    data = payload.encode()
    mask = os.urandom(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
    header = bytes([0x81])  # FIN + text
    n = len(data)
    if n < 126:
        header += bytes([0x80 | n])
    elif n < 65536:
        header += bytes([0x80 | 126]) + struct.pack(">H", n)
    else:
        header += bytes([0x80 | 127]) + struct.pack(">Q", n)
    s.sendall(header + mask + masked)

def read_frame(sock, pre):
    # returns (opcode, payload_bytes, leftover)
    def need(nbytes, pre):
        while len(pre) < nbytes:
            sock.settimeout(remaining())
            chunk = sock.recv(4096)
            if not chunk:
                raise EOFError
            pre += chunk
        return pre
    pre = need(2, pre)
    b0, b1 = pre[0], pre[1]
    opcode = b0 & 0x0F
    ln = b1 & 0x7F
    idx = 2
    if ln == 126:
        pre = need(4, pre); ln = struct.unpack(">H", pre[2:4])[0]; idx = 4
    elif ln == 127:
        pre = need(10, pre); ln = struct.unpack(">Q", pre[2:10])[0]; idx = 10
    pre = need(idx + ln, pre)
    payload = pre[idx:idx+ln]
    return opcode, payload, pre[idx+ln:]

DEADLINE = time.time() + 45
def remaining(): return max(0.5, DEADLINE - time.time())

hello = json.dumps({"v": 1, "type": "hello",
                    "payload": {"clientID": client_id,
                                "clientName": "Gate Poke (Alec's iPhone)",
                                "protoVersion": 1}})
send_text(hello)
print("SENT hello  clientID=", client_id)

while time.time() < DEADLINE:
    try:
        op, payload, leftover = read_frame(s, leftover)
    except (EOFError, socket.timeout):
        print("(no more frames / closed)")
        break
    if op == 0x8:
        print("<- CLOSE frame"); break
    if op in (0x9, 0xA):
        continue  # ping/pong
    try:
        msg = json.loads(payload.decode())
        t = msg.get("type", "?")
        if t == "welcome":
            snap = msg.get("payload", {}).get("snapshot", {})
            devs = snap.get("devices", [])
            print(f"<- WELCOME  serverName={snap.get('serverName')!r}  devices={len(devs)}: "
                  + ", ".join(d.get('name','?') for d in devs))
            break
        elif t == "awaitingApproval":
            print("<- AWAITING APPROVAL  (an Allow/Don't-Allow alert should be on the Mac now — click Allow)")
        else:
            print(f"<- {t}  {json.dumps(msg.get('payload', {}))[:160]}")
    except Exception as e:
        print("<- non-JSON frame", len(payload), "bytes")
s.close()
