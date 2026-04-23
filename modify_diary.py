import json

def process(file_path):
    with open(file_path, "r") as f:
        data = json.load(f)

    screens = data["ui"]["screens"]

    home_screen = next(s for s in screens if s["id"] == "home")
    new_entry_screen = next(s for s in screens if s["id"] == "new_entry")

    home_children = list(home_screen["children"])
    row_container = home_children[1]
    if row_container.get("type") == "container" and row_container.get("layout") == "row":
        clear_btn = next((c for c in row_container["children"] if c.get("type") == "button" and "清空" in c.get("label", "")), None)
        if clear_btn:
            row_container["children"] = [clear_btn]

    new_entry_children = list(new_entry_screen["children"])
    if new_entry_children[0].get("type") == "container" and new_entry_children[0].get("layout") == "row":
        new_entry_children = new_entry_children[2:] 

    home_screen["tabs"] = [
        {
            "label": "写日记",
            "icon": "edit",
            "title": "✏️ 写日记",
            "padding": new_entry_screen.get("padding", 20),
            "backgroundColor": new_entry_screen.get("backgroundColor", "#F0EDE6"),
            "children": new_entry_children
        },
        {
            "label": "历史记录",
            "icon": "history",
            "title": "📖 我的日记",
            "padding": home_screen.get("padding", 0),
            "backgroundColor": home_screen.get("backgroundColor", "#F0EDE6"),
            "children": home_children
        }
    ]

    home_screen["title"] = "日记本"
    home_screen.pop("children", None)
    home_screen.pop("padding", None)
    home_screen.pop("backgroundColor", None)

    data["ui"]["screens"] = [s for s in screens if s["id"] != "new_entry"]

    # Remove @navigate to home from createEntry logic
    create_logic = data["global"]["functions"]["createEntry"]["logic"]
    if create_logic[0].get("call") == "@if":
        else_branch = create_logic[0]["args"]["else"]
        # Filter out the navigate call
        create_logic[0]["args"]["else"] = [step for step in else_branch if step.get("call") != "@navigate"]

    # Bump version x.y.z -> x.(y+1).0
    old_ver = data["meta"]["version"]
    parts = old_ver.split('.')
    parts[1] = str(int(parts[1]) + 1)
    parts[2] = '0'
    data["meta"]["version"] = '.'.join(parts)

    with open(file_path, "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write('\n')
    print(f"Processed {file_path}")

process("templates/diary-app.json")
# Also process diary-drift.json just to be consistent
process("templates/diary-drift.json")
