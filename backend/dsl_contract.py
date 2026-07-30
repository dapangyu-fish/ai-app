"""DSL 契约版本——后端单一真相源（见 docs/planning/version-management.md §3.7 / §11.3）。

此前 `"3.3"` 在 app.py(/version)、json_app_builder、validate_json_app 各处硬编码，
bump DSL 时易漏改导致三处漂移。统一收敛到这里：发布期 gate 与 /version 端点都引用本模块。

注意：客户端 `lib/json_ui/interpreter.dart` 的 `kSupportedDsl` 是另一进程（Dart），
无法共享 Python 常量，bump 时仍需同步更新——这是跨语言边界的固有约束。
"""

# 当前支持的 DSL 版本窗口：框架新增向后兼容能力 → 加新 MINOR 进窗口；
# 破坏性变更 → bump MAJOR 并收窗口（旧 App 在客户端载入期被 kSupportedDsl 硬拒）。
SUPPORTED_DSL_VERSIONS = frozenset({"3.3", "4.0"})

# 主（最高）支持版本，/version 端点对外自报、文档/客户端对标用。
PRIMARY_DSL_VERSION = max(SUPPORTED_DSL_VERSIONS, key=lambda v: tuple(int(x) for x in v.split(".")))
