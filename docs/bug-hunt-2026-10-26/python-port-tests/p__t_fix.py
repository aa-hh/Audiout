# port of applyUpdateGroup + groupShapeRefusal (limits irrelevant here) and saveGroup
def shape(name, ids):
    if not name: return "name"
    if not ids: return "empty"
    if any(not i for i in ids): return "invalid"
    return None
def update(groups, gid, name, ids, fixed=False):
    if not any(g["id"]==gid for g in groups): return "gone"
    r = shape(name, ids)
    if r: return r
    if fixed:
        if len(set(ids)) != len(ids): return "dup ids"
        if any(g["id"]!=gid and set(g["m"])==set(ids) for g in groups): return "dup set"
    for g in groups:
        if g["id"]==gid: g["m"]=list(ids); g["name"]=name
    return "ok"
def run(fixed):
    gs=[{"id":"A","name":"A","m":["x"]},{"id":"B","name":"B","m":["y"]}]
    r1=update(gs,"B","B",["x"],fixed)      # same set as A
    r2=update(gs,"B","B",["y","y"],fixed)  # dup ids
    return r1,r2
for f in (False,True):
    r1,r2=run(f); print("fixed" if f else "current",r1,r2)
r1,r2=run(True)
assert r1!="ok" and r2!="ok", "BUG: update accepted duplicate set / duplicate ids"
