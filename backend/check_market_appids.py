import json
from registry_server import _load_index, minio_client, BUCKET_COMPONENT

index = _load_index()
print(f"Loaded index with {len(index.get('packages', {}))} packages")

invalid_packages = []
for name, info in index.get('packages', {}).items():
    for version in info.get('versions', []):
        path = info['path']
        filename = f"{name.split('/')[-1]}-{version}.json"
        oss_key = f"{path}/{filename}"
        
        try:
            response = minio_client.get_object(BUCKET_COMPONENT, oss_key)
            content = json.loads(response.read().decode('utf-8'))
            appid = content.get('appid', '')
            
            import re
            uuid_pattern = re.compile(r'^[0-9a-fA-F]{8}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{12}$')
            if not appid or not uuid_pattern.match(appid):
                invalid_packages.append({
                    "name": name,
                    "version": version,
                    "appid": appid
                })
                print(f"INVALID: {name}@{version} - appid: {appid}")
            else:
                print(f"VALID: {name}@{version} - appid: {appid}")
        except Exception as e:
            print(f"ERROR reading {name}@{version}: {e}")

print(f"\nTotal invalid market packages: {len(invalid_packages)}")
