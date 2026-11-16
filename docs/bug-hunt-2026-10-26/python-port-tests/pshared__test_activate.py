# Faithful port of CompanionLicenseActivation.activate lines 35-98 (validator stubbed: unreachable leaves state as set by caller)
import sys
def activate(s, key, result, fixed=False):
    if key == s['key'] and s['status']=='active': return True
    prev = dict(s) if s['status']=='active' and s['key'] else None
    if key != s['key']: s['status']=None
    s['key']=key
    applied = result in ('active','unreachable')
    cond = result != 'active'
    if fixed: cond = result not in ('active','unreachable')
    if prev and cond and s['key']==key: s.update(prev)
    return applied
for fixed in (False, True):
    s={'key':'AUDT-A','status':'active'}
    r=activate(s,'AUDT-B','unreachable',fixed)
    ok = r and s['key']=='AUDT-B'
    print('fixed' if fixed else 'current', 'applied',r,'key',s['key'],'PASS' if ok else 'FAIL')
    if not fixed and not ok: first=1
sys.exit(0)
