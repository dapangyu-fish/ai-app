# 规划文档（Planning / RFC）

本目录存放**尚未实现或正在设计**的功能需求与实现方案（RFC 风格）。每篇文档对应一个较大的特性，先于编码确定边界、数据模型、安全模型与分期计划，供评审与对照实现。

> 与其它文档的区别：`JSON-DSL.md` / `backend/ARCHITECTURE.md` 描述**已落地**的契约；本目录描述**将要做什么、为什么、怎么做**。实现完成后，相关结论回流到对应的契约文档，本文转为「已实现」存档。

## 索引

| 文档 | 主题 | 状态 |
|------|------|------|
| [push-jsonapp-isolation.md](push-jsonapp-isolation.md) | JSON-APP 维度的推送隔离 + 点击深链跳转 + 主动授权 | 提案（待实现） |
| [app-share-link-qr.md](app-share-link-qr.md) | App 分享链接 + 二维码，深链打开 AI 生成的 JSON-APP（含未装兜底） | 提案（待实现） |
| [audio-support.md](audio-support.md) | JSON-APP 音频支持：播放 / 录音 / 上传 / 可复用音频 UI（flame 播放引擎下沉复用） | 提案（待实现） |
| [faas-scale-out.md](faas-scale-out.md) | FaaS 横向扩容：多节点 Docker FaaS + 后端二级路由 + 用户私有 faas 节点 | 提案（待实现） |
| [pgbouncer-jsonapp-postgres.md](pgbouncer-jsonapp-postgres.md) | jsonapp-postgres 接 PgBouncer 双实例（faas/platform）+ auth_query + DB_DIRECT 旁路 + 1万DAU调优 | 已落地（77 验证） |
| [version-management.md](version-management.md) | 版本号管理：63 个依赖/版本耦合面审计 + VERSION(1.2.0) 真相源 + 镜像不可变 tag/digest + Python hash-lock + FaaS helper ABI 版本化 + schema 迁移表 + DSL 载入期兼容闸 | 提案（待评审） |
