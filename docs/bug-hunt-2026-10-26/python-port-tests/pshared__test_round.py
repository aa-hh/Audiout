import sys
def tdiv(a,b):
    q=abs(a)//abs(b)
    return q if (a<0)==(b<0) else -q
def scaled(s,v,fixed=False):
    v=max(0,min(100,v))
    if v==100: return s
    if fixed: return (s*v+50)//100  # floor division = round half up
    return tdiv(s*v+50,100)
fixed = len(sys.argv)>1
cases=[(-7,20,-1),(7,20,1),(-3,50,-1),(3,50,2)]
bad=[(s,v,scaled(s,v,fixed),e) for s,v,e in cases if scaled(s,v,fixed)!=e]
print(bad); assert not bad
