import json
import os
from pathlib import Path
import secrets
import sys
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from uuid import UUID, uuid4

os.umask(0o077)
root=Path(sys.argv[2]).resolve()
if root.stat().st_mode & 0o077:
    raise SystemExit("Fixture directory must be private (mode 0700).")
cfg=json.loads((root/"runtime.json").read_text())
api="http://127.0.0.1:55471"
edge="http://127.0.0.1:55473"
def request(method, url, data=None, *, token=None, admin=False, expected=(200,), mime=None):
    key=cfg["service" if admin else "anon"]
    headers={"apikey":key}
    if admin or token:
        headers["Authorization"]="Bearer "+(token or key)
    if data is not None:
        if isinstance(data, bytes):
            headers["Content-Type"]=mime or "application/octet-stream"
        else:
            data=json.dumps(data).encode()
            headers["Content-Type"]="application/json"
    with urlopen(Request(url,data=data,headers=headers,method=method),timeout=30) as response:
        if response.status not in expected: raise ValueError("Unexpected fixture response status")
        body=response.read()
        return json.loads(body) if body else None
if sys.argv[1]=="new":
    assert not (root/"actors.json").exists()
    actors={}
    for role in ("target","witness"):
        email=f"e68-{role}@example.com"
        label=f"Execute E68 {role}"
        password=secrets.token_urlsafe(27)
        auth=request("POST",api+"/auth/v1/admin/users",
                     {"email":email,"password":password,"email_confirm":True,"app_metadata":{"e68_fixture":role}},
                     admin=True,expected=(200,201))
        owner=str(UUID(auth["id"]))
        row={"owner_id":owner,"owner_email":email,"created_by":email,"user_email":email}
        profile=str(uuid4()); goal=str(uuid4())
        request("POST", api+"/rest/v1/user_profiles", {**row,"id":profile,"data":{"display_name":label}},admin=True,expected=(201,))
        request("POST", api+"/rest/v1/goals", {**row,"id":goal,"data":{"title":label+" goal"}},admin=True,expected=(201,))
        actors[role]={"email":email,"label":label,"id":owner,"profile":profile,"goal":goal,"path":owner+"/native-e68-proof.txt","password":password}
    (root/"actors.json").write_text(json.dumps(actors))
    e={"SUPABASE_URL":api,"SUPABASE_ANON_KEY":cfg["anon"],"SUPABASE_SERVICE_ROLE_KEY":cfg["service"],
       "EXECUTE_STAGED_DELETION_OWNER_UUID":actors["target"]["id"]}
    (root/"edge.env").write_text("".join(f"{k}={v}\n" for k,v in e.items()))
    print("Created exactly two local synthetic Auth users and markers.")
elif sys.argv[1]=="objects":
    actors=json.loads((root/"actors.json").read_text())
    for role,a in actors.items():
        session=request("POST",api+"/auth/v1/token?grant_type=password",{"email":a["email"],"password":a["password"]})
        assert session["user"]["id"]==a["id"]
        receipt=request("POST",edge+"/functions/v1/guardedStorageUpload?"+urlencode({"bucket":"uploads","path":a["path"]}),
                        a["label"].encode(),token=session["access_token"],expected=(201,),mime="text/plain")
        assert receipt["path"]==a["path"]
        del a["password"]
    (root/"actors.json").write_text(json.dumps(actors))
    print("Canonical writer stored the two exact synthetic objects.")
