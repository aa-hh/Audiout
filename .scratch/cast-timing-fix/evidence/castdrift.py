# Feedback loop for the Cast "slipping" bug. Replays telemetry; per minute after the last settle:
# err = lead + age - room (ms). RED when the err slope exceeds 0.1 ms/min or the median strays >10 ms
# from the by-ear offset. Usage: python3 castdrift.py <telemetry.jsonl> [since-iso]
import json,sys,statistics as st,collections
p=sys.argv[1]; since=sys.argv[2] if len(sys.argv)>2 else ""
room=None; off=0; settle_ts=None; rows=[]
for l in open(p):
    try: j=json.loads(l)
    except: continue
    if j.get("ts","")<since: continue
    v=j["evt"]
    if v=="room_delay_changed": room=int(j["room_ms"])
    elif v=="cast_feed_delay": off=int(j["offset_ms"])
    elif v=="cast_lead_settled": settle_ts=j["ts"]; rows=[]
    elif v=="cast_stage_timing" and j["kept"]=="1" and j["age_ms"]!="nil" and room and settle_ts:
        rows.append((j["ts"][11:16],int(j["lead_ms"])+float(j["age_ms"])-room-off,int(j["lead_ms"]),float(j["ioproc_to_push_ms"])))
by=collections.OrderedDict()
for r in rows: by.setdefault(r[0],[]).append(r)
mins=list(by.items())
if len(mins)<3: sys.exit("not enough settled minutes")
ys=[st.median([r[1] for r in rs]) for _,rs in mins]; xs=list(range(len(ys)))
mx,my=st.mean(xs),st.mean(ys); slope=sum((x-mx)*(y-my) for x,y in zip(xs,ys))/sum((x-mx)**2 for x in xs)
lead=[st.median([r[2] for r in rs]) for _,rs in mins]; io=[st.median([r[3] for r in rs]) for _,rs in mins]
print(f"since settle {settle_ts[11:19]}: {len(mins)} min, err (offset removed) first {ys[0]:+.0f} last {ys[-1]:+.0f}, slope {slope:+.2f} ms/min")
print(f"  lead {lead[0]:.0f}->{lead[-1]:.0f}   capture-to-push {io[0]:.0f}->{io[-1]:.0f}")
red=abs(slope)>0.1 or abs(st.median(ys))>10
print("RED" if red else "GREEN"); sys.exit(1 if red else 0)
