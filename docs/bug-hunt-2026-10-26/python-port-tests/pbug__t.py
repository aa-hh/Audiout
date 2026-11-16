import os,shutil,tempfile,json,sys
LOGS=["decision.log","engine.log"];STORES=["app-routes.json","groups.json"]
def redacted(t,home): return t if not home else t.replace(home,"~")
def stage(d,snap,logs,stores,home,fix=False):
    os.makedirs(d,exist_ok=True)
    open(d+"/snapshot.json","w").write(json.dumps(snap))  # current: no redaction
    if fix: open(d+"/snapshot.json","w").write(redacted(json.dumps(snap),home))
    for src,names in [(logs,LOGS),(stores,STORES)]:
        for n in names:
            f=os.path.join(src,n)
            if not os.path.exists(f): continue
            if fix: open(d+"/"+n,"w").write(redacted(open(f).read(),home))
            else: shutil.copy(f,d+"/"+n)
def run(fix):
    t=tempfile.mkdtemp();home="/Users/alice"
    for n in LOGS+STORES: open(t+"/"+n,"w").write('{"p":"/Users/alice/Music/x"}')
    out=t+"/out";stage(out,{"name":"/Users/alice/spk"},t,t,home,fix)
    return [n for n in os.listdir(out) if home in open(out+"/"+n).read()]
leak=run(sys.argv[1:]==["fix"]);print("leaks:",leak);assert not leak,"home path leaked"
