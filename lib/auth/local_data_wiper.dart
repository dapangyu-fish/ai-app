import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../platform/native_fs.dart';
import '../config/environment_service.dart';
import '../im/apns_service.dart';
import '../im/fcm_service.dart';
import '../im/getui_service.dart';
import '../im/im_service.dart';
import '../json_ui/cache_manager.dart';
import '../json_ui/drift_database.dart';

/// 切换账号时彻底清空所有本地数据。
///
/// 调用顺序很重要：
/// 1. 先优雅断开（IM logout）
/// 2. 再关闭 drift 数据库连接（不关就删不掉文件）
/// 3. 然后才能删磁盘文件
/// 4. 最后清 SharedPreferences
///
/// 全过程对各步失败都吞异常 + 打 log，因为切账号是"清得越干净越好"，
/// 哪怕有一步失败也要继续清剩下的。
Future<void> wipeAllLocalAccountData() async {
  debugPrint('[Wipe] ========== 开始清除本地数据 ==========');

  // 0. 注销后端 device token（必须在 SharedPreferences 清空前做，否则 access_token 没了
  //    后端 DELETE 鉴权会失败）。失败吞掉继续走，token 还能靠后端 BadDeviceToken
  //    自愈逻辑兜底
  try {
    await ApnsService.instance.unregister();
    debugPrint('[Wipe] ApnsService.unregister OK');
  } catch (e) {
    debugPrint('[Wipe] ApnsService.unregister 失败 (忽略): $e');
  }
  try {
    await FcmService.instance.unregister();
    debugPrint('[Wipe] FcmService.unregister OK');
  } catch (e) {
    debugPrint('[Wipe] FcmService.unregister 失败 (忽略): $e');
  }
  try {
    await GetuiService.instance.unregister();
    debugPrint('[Wipe] GetuiService.unregister OK');
  } catch (e) {
    debugPrint('[Wipe] GetuiService.unregister 失败 (忽略): $e');
  }

  // 1. IM logout（清 SDK + im_* prefs；如果 SDK 没初始化会被忽略）
  try {
    await IMService.instance.logout();
    debugPrint('[Wipe] IMService.logout OK');
  } catch (e) {
    debugPrint('[Wipe] IMService.logout 失败 (忽略): $e');
  }

  // 2. 关掉所有 drift 数据库连接
  try {
    await DriftDatabaseManager.instance.closeAll();
    debugPrint('[Wipe] DriftDatabaseManager.closeAll OK');
  } catch (e) {
    debugPrint('[Wipe] drift closeAll 失败 (忽略): $e');
  }

  // 3. 重置 CacheManager 单例（避免内存里残留旧 index）
  try {
    await CacheManager.instance.reset();
    debugPrint('[Wipe] CacheManager.reset OK');
  } catch (e) {
    debugPrint('[Wipe] CacheManager.reset 失败 (忽略): $e');
  }

  // 4. 删除文件系统上的本地数据（web 无文件系统则全部 no-op）
  try {
    final appSupport = await NativeFs.appSupportDir();
    if (appSupport != null) {
      final deleted = await NativeFs.deleteDirAbs('$appSupport/openim');
      if (deleted) debugPrint('[Wipe] 删除 OpenIM 目录: $appSupport/openim');
    }
  } catch (e) {
    debugPrint('[Wipe] 删 OpenIM 目录失败 (忽略): $e');
  }

  try {
    final appDocs = await NativeFs.appDocDir();
    if (appDocs != null) {
      // dsl_cache：JSON-APP / 依赖库的本地缓存
      final deleted = await NativeFs.deleteDirAbs('$appDocs/dsl_cache');
      if (deleted) debugPrint('[Wipe] 删除 dsl_cache: $appDocs/dsl_cache');

      // drift 数据库文件 (app_*.sqlite, app_*.sqlite-journal/wal/shm)
      for (final path in await NativeFs.listFilesAbs(appDocs)) {
        final name = path.split('/').last;
        if (name.startsWith('app_') &&
            (name.endsWith('.sqlite') ||
                name.endsWith('.sqlite-journal') ||
                name.endsWith('.sqlite-wal') ||
                name.endsWith('.sqlite-shm'))) {
          try {
            await NativeFs.deleteAbs(path);
            debugPrint('[Wipe] 删除 drift 文件: $path');
          } catch (e) {
            debugPrint('[Wipe] 删 drift 文件失败 $path: $e');
          }
        }
      }
    }
  } catch (e) {
    debugPrint('[Wipe] 删 docs 目录失败 (忽略): $e');
  }

  // 5. 清空 SharedPreferences（auth/im/ai_session/locale/theme/asr/storage 全清）
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    debugPrint('[Wipe] SharedPreferences cleared');
  } catch (e) {
    debugPrint('[Wipe] 清 prefs 失败 (忽略): $e');
  }

  // 6. 环境配置不属于"账号本地数据"，prefs.clear() 把它顺带冲了 → 写回来。
  //    EnvironmentService 单例内存里仍有 active env，直接持久化即可
  try {
    await EnvironmentService.instance.persistCurrent();
    debugPrint('[Wipe] EnvironmentService.persistCurrent OK');
  } catch (e) {
    debugPrint('[Wipe] env 写回失败 (忽略): $e');
  }

  debugPrint('[Wipe] ========== 清除完成 ==========');
}
