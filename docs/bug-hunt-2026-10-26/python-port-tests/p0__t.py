def can(d): return not (d.get('local') or d.get('kind')=='localMac' or d.get('cast'))
def apply(devs, main, routes, bid, did, fix=False):
    d=next((x for x in devs if x['id']==did),None)
    if not d: return 'refused'
    if did in main: return 'refused'
    if fix and not can(d): return 'refused'
    routes[bid]=did; return 'ok'
devs=[{'id':'cast1','cast':True},{'id':'mac','kind':'localMac','local':True}]
for fix in (True,):
    for i in ('cast1','mac'):
        r={}; res=apply(devs,set(),r,'app',i,fix)
        print(fix,i,res)
        if fix or True: assert res=='refused', f"{i} persisted"
