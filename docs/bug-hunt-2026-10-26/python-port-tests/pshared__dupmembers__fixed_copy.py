import sys
def unique_kv(pairs):  # Swift Dictionary(uniqueKeysWithValues:) semantics
    d={}
    for k,v in pairs:
        if k in d: raise RuntimeError("Fatal error: Duplicate values for key: "+k)
        d[k]=v
    return d
def member_names(member_ids, device_names):
    return {i:device_names[i] for i in member_ids if i in device_names}
def test_dup_member():
    assert member_names(["a","a","b"],{"a":"A","b":"B"})=={"a":"A","b":"B"}
if __name__=="__main__":
    test_dup_member(); print("PASS")
