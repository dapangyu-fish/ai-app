import 'package:leap/leap.dart' as leap;

enum PlatformerPhysicsBackend { aabb, leap }

class PlatformerPhysicsConfig {
  const PlatformerPhysicsConfig({
    required this.backend,
    required this.fallback,
  });

  factory PlatformerPhysicsConfig.fromSpec(dynamic raw) {
    if (raw is String) {
      return PlatformerPhysicsConfig(
        backend: _readBackend(raw),
        fallback: PlatformerPhysicsBackend.aabb,
      );
    }
    if (raw is Map) {
      return PlatformerPhysicsConfig(
        backend: _readBackend(raw['engine'] ?? raw['backend']),
        fallback: _readBackend(raw['fallback']),
      );
    }
    return const PlatformerPhysicsConfig(
      backend: PlatformerPhysicsBackend.aabb,
      fallback: PlatformerPhysicsBackend.aabb,
    );
  }

  final PlatformerPhysicsBackend backend;
  final PlatformerPhysicsBackend fallback;

  bool get wantsLeap => backend == PlatformerPhysicsBackend.leap;

  bool get usesAabbRuntime {
    return backend == PlatformerPhysicsBackend.aabb ||
        (backend == PlatformerPhysicsBackend.leap &&
            fallback == PlatformerPhysicsBackend.aabb);
  }

  String get engineName => switch (backend) {
    PlatformerPhysicsBackend.leap => 'leap_platformer',
    PlatformerPhysicsBackend.aabb => 'aabb_platformer',
  };

  String get runtimeName => usesAabbRuntime ? 'aabb_platformer' : engineName;

  Map<String, dynamic> toMap() => {
    'engine': engineName,
    'runtime': runtimeName,
    'fallback': fallback == PlatformerPhysicsBackend.leap
        ? 'leap_platformer'
        : 'aabb_platformer',
    'leap_available': LeapPlatformerBridge.available,
  };

  static PlatformerPhysicsBackend _readBackend(dynamic raw) {
    final value = raw?.toString().trim().toLowerCase();
    if (value == 'leap' ||
        value == 'leap_platformer' ||
        value == 'platformer_leap') {
      return PlatformerPhysicsBackend.leap;
    }
    return PlatformerPhysicsBackend.aabb;
  }
}

class LeapPlatformerBridge {
  const LeapPlatformerBridge._();

  static bool get available => true;

  static Type get gameType => leap.LeapGame;

  static Type get mapType => leap.LeapMap;

  static Type get jumperCharacterType => leap.JumperCharacter;

  static leap.LeapConfiguration configuration({
    String groundLayerName = 'ground',
    String metadataLayerName = 'metadata',
    String playerSpawnClass = 'PlayerSpawn',
  }) {
    return leap.LeapConfiguration(
      tiled: leap.TiledOptions(
        groundLayerName: groundLayerName,
        metadataLayerName: metadataLayerName,
        playerSpawnClass: playerSpawnClass,
      ),
    );
  }
}
