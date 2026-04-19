
import os
import json

TEMPLATES_DIR = '/Users/renxuehuan/ai-app/templates'

print(f"Checking directory: {TEMPLATES_DIR}")
print(f"Directory exists: {os.path.exists(TEMPLATES_DIR)}")
print(f"Directory content:")

files = sorted(os.listdir(TEMPLATES_DIR))
for f in files:
    if not f.endswith(".json"):
        continue
    print(f"\n  - {f}:")
    try:
        filepath = os.path.join(TEMPLATES_DIR, f)
        print(f"    File exists: {os.path.exists(filepath)}")
        with open(filepath, 'r', encoding='utf-8') as fh:
            data = json.load(fh)
        meta = data.get("meta", {})
        print(f"    Meta loaded successfully:")
        print(f"      - Name: {meta.get('name', f)}")
        print(f"      - Author: {meta.get('author', '')}")
        print(f"      - Description: {meta.get('description', '')}")
    except Exception as e:
        print(f"    ERROR loading: {type(e).__name__}: {e}")

print("\nDone!")
