import 'package:jsonlogic/jsonlogic.dart';

/// 位运算 / 整除 jsonlogic 原语（feat/nesd-primitives）。
///
/// 主解释器与游戏逻辑引擎各持有独立的 Jsonlogic 实例，两边都要注册；
/// 单一注册点避免语义漂移。动机与量化背景见 docs/nesd-port-feasibility.md
/// （此前 8 位 AND 需 ~130 节点的算术仿真，实测 5k 次/s；原生原语后
/// 与普通算术步同价）。
void registerBitOps(Jsonlogic jl) {
  num numArg(dynamic applier, dynamic data, List<dynamic> params, int i) {
    if (i >= params.length) return 0;
    final v = applier(params[i], data);
    if (v is num) return v;
    if (v is String) return num.tryParse(v) ?? 0;
    if (v is bool) return v ? 1 : 0;
    return 0;
  }

  int intArg(dynamic applier, dynamic data, List<dynamic> params, int i) =>
      numArg(applier, data, params, i).toInt();

  jl.add('bit_and', (applier, data, params) {
    return intArg(applier, data, params, 0) & intArg(applier, data, params, 1);
  });
  jl.add('bit_or', (applier, data, params) {
    return intArg(applier, data, params, 0) | intArg(applier, data, params, 1);
  });
  jl.add('bit_xor', (applier, data, params) {
    return intArg(applier, data, params, 0) ^ intArg(applier, data, params, 1);
  });
  jl.add('bit_not', (applier, data, params) {
    // 按位求反后以第二参位宽掩码（缺省 32 位），保证结果非负
    final width = params.length > 1 ? intArg(applier, data, params, 1) : 32;
    final mask = width >= 32 ? 0xFFFFFFFF : (1 << width) - 1;
    return (~intArg(applier, data, params, 0)) & mask;
  });
  jl.add('shl', (applier, data, params) {
    final n = intArg(applier, data, params, 1);
    if (n < 0 || n > 32) return 0;
    return (intArg(applier, data, params, 0) << n) & 0xFFFFFFFF;
  });
  jl.add('shr', (applier, data, params) {
    final n = intArg(applier, data, params, 1);
    if (n < 0 || n > 32) return 0;
    return (intArg(applier, data, params, 0) & 0xFFFFFFFF) >> n;
  });
  jl.add('idiv', (applier, data, params) {
    final d = intArg(applier, data, params, 1);
    if (d == 0) return 0;
    return intArg(applier, data, params, 0) ~/ d;
  });
}
