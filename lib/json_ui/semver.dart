// 语义化版本解析和约束匹配
// 支持 semver 格式和 pip/npm 风格的版本约束

class SemVer implements Comparable<SemVer> {
  final int major;
  final int minor;
  final int patch;

  const SemVer(this.major, this.minor, this.patch);

  /// 解析版本字符串 "1.2.3"
  factory SemVer.parse(String version) {
    final cleaned = version.trim().replaceFirst(RegExp(r'^v'), '');
    final parts = cleaned.split('.');
    return SemVer(
      parts.isNotEmpty ? int.tryParse(parts[0]) ?? 0 : 0,
      parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0,
      parts.length > 2 ? int.tryParse(parts[2]) ?? 0 : 0,
    );
  }

  @override
  int compareTo(SemVer other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  bool operator >=(SemVer other) => compareTo(other) >= 0;
  bool operator >(SemVer other) => compareTo(other) > 0;
  bool operator <=(SemVer other) => compareTo(other) <= 0;
  bool operator <(SemVer other) => compareTo(other) < 0;

  @override
  bool operator ==(Object other) =>
      other is SemVer &&
      major == other.major &&
      minor == other.minor &&
      patch == other.patch;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => '$major.$minor.$patch';
}

/// 版本约束
class VersionConstraint {
  final List<_VersionRange> _ranges;

  VersionConstraint._(this._ranges);

  /// 解析版本约束字符串
  /// 支持: "1.2.3", "^1.2.0", "~1.2.0", ">=1.0.0", ">=1.0.0 <2.0.0", "*"
  factory VersionConstraint.parse(String constraint) {
    final trimmed = constraint.trim();

    if (trimmed == '*' || trimmed.isEmpty) {
      return VersionConstraint._([_VersionRange.any()]);
    }

    // ^1.2.0 → >=1.2.0 <2.0.0
    if (trimmed.startsWith('^')) {
      final ver = SemVer.parse(trimmed.substring(1));
      return VersionConstraint._([
        _VersionRange(
          min: ver,
          minInclusive: true,
          max: SemVer(ver.major + 1, 0, 0),
          maxInclusive: false,
        ),
      ]);
    }

    // ~1.2.0 → >=1.2.0 <1.3.0
    if (trimmed.startsWith('~')) {
      final ver = SemVer.parse(trimmed.substring(1));
      return VersionConstraint._([
        _VersionRange(
          min: ver,
          minInclusive: true,
          max: SemVer(ver.major, ver.minor + 1, 0),
          maxInclusive: false,
        ),
      ]);
    }

    // 范围组合 ">=1.0.0 <2.0.0"
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length == 1) {
      final range = _parseSingleRange(parts[0]);
      return VersionConstraint._([range]);
    }

    // 多段合并
    final ranges = parts.map(_parseSingleRange).toList();
    return VersionConstraint._(ranges);
  }

  /// 检查版本是否满足约束
  bool satisfiedBy(SemVer version) {
    return _ranges.every((range) => range.allows(version));
  }

  static _VersionRange _parseSingleRange(String part) {
    if (part.startsWith('>=')) {
      return _VersionRange(
          min: SemVer.parse(part.substring(2)), minInclusive: true);
    }
    if (part.startsWith('>')) {
      return _VersionRange(
          min: SemVer.parse(part.substring(1)), minInclusive: false);
    }
    if (part.startsWith('<=')) {
      return _VersionRange(
          max: SemVer.parse(part.substring(2)), maxInclusive: true);
    }
    if (part.startsWith('<')) {
      return _VersionRange(
          max: SemVer.parse(part.substring(1)), maxInclusive: false);
    }
    // 精确版本
    final ver = SemVer.parse(part);
    return _VersionRange(
        min: ver, minInclusive: true, max: ver, maxInclusive: true);
  }

  @override
  String toString() => _ranges.map((r) => r.toString()).join(' ');
}

class _VersionRange {
  final SemVer? min;
  final bool minInclusive;
  final SemVer? max;
  final bool maxInclusive;

  _VersionRange({
    this.min,
    this.minInclusive = false,
    this.max,
    this.maxInclusive = false,
  });

  factory _VersionRange.any() => _VersionRange();

  bool allows(SemVer version) {
    if (min != null) {
      final cmp = version.compareTo(min!);
      if (minInclusive ? cmp < 0 : cmp <= 0) return false;
    }
    if (max != null) {
      final cmp = version.compareTo(max!);
      if (maxInclusive ? cmp > 0 : cmp >= 0) return false;
    }
    return true;
  }

  @override
  String toString() {
    if (min != null && max != null && min == max && minInclusive && maxInclusive) {
      return min.toString();
    }
    final parts = <String>[];
    if (min != null) parts.add('${minInclusive ? ">=" : ">"}$min');
    if (max != null) parts.add('${maxInclusive ? "<=" : "<"}$max');
    return parts.isEmpty ? '*' : parts.join(' ');
  }
}
