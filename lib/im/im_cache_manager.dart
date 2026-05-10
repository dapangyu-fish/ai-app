// IM 富媒体专用 CacheManager
//
// 与默认 DefaultCacheManager（200 个 / 30 天 LRU）的区别：
//
//   设计语义：用户**看过的图视为永久持有**，跟微信/Telegram 一致 ——
//   服务端 MinIO 7 天 lifecycle 兜底"从未点开过的"，只要消息打开过、
//   缩略图被下载到本地，就不再被自动 evict。
//
// 实现：
//   - stalePeriod = 365 天（一年）：实际想要"永久"，但 flutter_cache_manager
//     不支持，给个超大值实质等同
//   - maxNrOfCacheObjects = 100000（10 万）：手机正常用三五年也装不到这么多
//   - 触发 LRU 的兜底场景：磁盘空间被 OS 清掉 app cache（用户存储吃紧），
//     那时 OS 会清整个 cache 目录，本就跟我们设置无关
//
// 失效：服务端 MinIO 7 天后删 → 客户端如果本地有缓存还能看；本地没了
// （比如别的设备登录、刚装 app）→ 显示"图片已过期"占位
//
// 用法：所有 CachedNetworkImage / CachedNetworkImageProvider 传
// `cacheManager: imMediaCacheManager` 即可（不传走的是默认 200/30d）

import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// IM 富媒体（聊天图片 / 视频缩略图）专用 cache manager。
/// 头像走默认 DefaultCacheManager 即可（个数有限，LRU 200 够用）。
class ImMediaCacheManager {
  static const _key = 'imMediaCache';

  static final CacheManager instance = CacheManager(
    Config(
      _key,
      stalePeriod: const Duration(days: 365), // 实质不淘汰
      maxNrOfCacheObjects: 100000,
    ),
  );
}
