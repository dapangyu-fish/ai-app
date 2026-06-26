import os, sys, json, urllib.request, urllib.error

path = sys.argv[1]
registry = os.environ.get("REGISTRY_URL", "http://localhost:3254").rstrip("/")
token = os.environ["REGISTRY_ADMIN_TOKEN"]
content = json.load(open(path, encoding="utf-8"))
payload = json.dumps({"json_content": content, "force_update": True}).encode()
req = urllib.request.Request(
    registry + "/publish", data=payload, method="POST",
    headers={"Content-Type": "application/json", "Authorization": "Bearer " + token},
)
try:
    r = urllib.request.urlopen(req, timeout=30)
    code, body = r.status, r.read().decode("utf-8", "replace")
except urllib.error.HTTPError as e:
    code, body = e.code, e.read().decode("utf-8", "replace")
except Exception as e:
    code, body = -1, "EXC %r" % e
print("publish ->", registry, "HTTP", code)
print(body[:1200])
