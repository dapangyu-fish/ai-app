import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../interpreter.dart';
import 'base_widget.dart';

class JsonCrossAxisSizingListWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final children = <Widget>[];
    final source = _resolveSource(interpreter, json['source']);
    final template = json['itemTemplate'] ?? json['item_template'];
    if (source != null && template is Map<String, dynamic>) {
      for (var index = 0; index < source.length; index++) {
        children.add(
          interpreter.buildWidgetInLoopContext(
            context: context,
            json: template,
            loopItem: source[index],
            loopIndex: index,
          ),
        );
      }
    } else {
      final rawChildren = json['children'];
      if (rawChildren is List) {
        for (final child in rawChildren.whereType<Map<String, dynamic>>()) {
          children.add(interpreter.buildWidget(context, child));
        }
      }
    }

    Widget list = CrossAxisSizingListView(
      scrollDirection: _parseAxis(json['scrollDirection']?.toString()),
      padding: _resolveInsets(json['padding']),
      physics: _parsePhysics(json['physics']?.toString()),
      children: children,
    );
    final width = _resolveDouble(interpreter, json['width']);
    final height = _resolveDouble(interpreter, json['height']);
    if (width != null || height != null) {
      list = SizedBox(width: width, height: height, child: list);
    }
    return list;
  }

  List<dynamic>? _resolveSource(JsonInterpreter interpreter, dynamic raw) {
    if (raw is List) return raw;
    if (raw is String) {
      final resolved = interpreter.resolveExpression(raw);
      if (resolved is List) return resolved;
    }
    return null;
  }

  Axis _parseAxis(String? value) {
    return value == 'vertical' ? Axis.vertical : Axis.horizontal;
  }

  ScrollPhysics? _parsePhysics(String? value) {
    return switch (value) {
      'never' => const NeverScrollableScrollPhysics(),
      'clamping' => const ClampingScrollPhysics(),
      'bouncing' => const BouncingScrollPhysics(),
      _ => null,
    };
  }

  EdgeInsetsGeometry? _resolveInsets(dynamic raw) {
    if (raw is num) return EdgeInsets.all(raw.toDouble());
    if (raw is Map) {
      return EdgeInsets.only(
        left: (raw['left'] as num?)?.toDouble() ?? 0,
        top: (raw['top'] as num?)?.toDouble() ?? 0,
        right: (raw['right'] as num?)?.toDouble() ?? 0,
        bottom: (raw['bottom'] as num?)?.toDouble() ?? 0,
      );
    }
    return null;
  }

  double? _resolveDouble(JsonInterpreter interpreter, dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    final resolved = interpreter.resolveExpression(value);
    if (resolved is num) return resolved.toDouble();
    return double.tryParse(resolved?.toString() ?? '');
  }
}

class CrossAxisSizingListView = ListView with CrossAxisSizingListViewMixin;

mixin CrossAxisSizingListViewMixin on ListView {
  @override
  Widget buildChildLayout(BuildContext context) {
    return CrossAxisSizingSliverList(delegate: childrenDelegate);
  }

  @override
  @protected
  Widget buildViewport(
    BuildContext context,
    ViewportOffset offset,
    AxisDirection axisDirection,
    List<Widget> slivers,
  ) {
    return CrossAxisSizingViewport(
      axisDirection: axisDirection,
      offset: offset,
      slivers: slivers,
      cacheExtent: cacheExtent,
    );
  }

  @override
  List<Widget> buildSlivers(BuildContext context) {
    Widget sliver = buildChildLayout(context);
    EdgeInsetsGeometry? effectivePadding = padding;
    if (padding == null) {
      final mediaQuery = MediaQuery.maybeOf(context);
      if (mediaQuery != null) {
        final horizontalPadding = mediaQuery.padding.copyWith(
          top: 0,
          bottom: 0,
        );
        final verticalPadding = mediaQuery.padding.copyWith(left: 0, right: 0);
        effectivePadding = scrollDirection == Axis.vertical
            ? verticalPadding
            : horizontalPadding;
        sliver = MediaQuery(
          data: mediaQuery.copyWith(
            padding: scrollDirection == Axis.vertical
                ? horizontalPadding
                : verticalPadding,
          ),
          child: sliver,
        );
      }
    }

    if (effectivePadding != null) {
      sliver = CrossAxisSizingSliverPadding(
        padding: effectivePadding,
        sliver: sliver,
      );
    }
    return <Widget>[sliver];
  }
}

class CrossAxisSizingSliverPadding = SliverPadding
    with CrossAxisSizingSliverPaddingMixin;

mixin CrossAxisSizingSliverPaddingMixin on SliverPadding {
  @override
  RenderSliverPadding createRenderObject(BuildContext context) {
    return CrossAxisSizingRenderSliverPadding(
      padding: padding,
      textDirection: Directionality.of(context),
    );
  }
}

class CrossAxisSizingRenderSliverPadding = RenderSliverPadding
    with CrossAxisSizingRenderSliverPaddingMixin;

mixin CrossAxisSizingRenderSliverPaddingMixin on RenderSliverPadding {
  @override
  void performLayout() {
    super.performLayout();
    final childGeometry = child?.geometry;
    if (childGeometry == null) {
      geometry = CrossAxisSizingSliverGeometry(
        existing: SliverGeometry.zero,
        crossAxisSize: 0,
      );
      return;
    }
    final sizingGeometry = childGeometry as CrossAxisSizingSliverGeometry;
    final extra = constraints.axis == Axis.horizontal
        ? padding.vertical
        : padding.horizontal;
    geometry = CrossAxisSizingSliverGeometry(
      existing: geometry,
      crossAxisSize: sizingGeometry.crossAxisSize + extra,
    );
  }
}

class CrossAxisSizingSliverList = SliverList
    with CrossAxisSizingSliverListMixin;

mixin CrossAxisSizingSliverListMixin on SliverList {
  @override
  RenderSliverList createRenderObject(BuildContext context) {
    final element = context as SliverMultiBoxAdaptorElement;
    return CrossAxisSizingRenderSliverList(childManager: element);
  }
}

class CrossAxisSizingRenderSliverList extends RenderSliverList {
  CrossAxisSizingRenderSliverList({required super.childManager});

  @override
  void performLayout() {
    final constraints = this.constraints;
    childManager.didStartLayout();
    childManager.setDidUnderflow(false);

    final scrollOffset = constraints.scrollOffset + constraints.cacheOrigin;
    assert(scrollOffset >= 0);
    final remainingExtent = constraints.remainingCacheExtent;
    assert(remainingExtent >= 0);
    final targetEndScrollOffset = scrollOffset + remainingExtent;
    var childConstraints = constraints.asBoxConstraints();
    if (constraints.axis == Axis.horizontal) {
      childConstraints = childConstraints.copyWith(minHeight: 0);
    } else {
      childConstraints = childConstraints.copyWith(minWidth: 0);
    }

    var leadingGarbage = 0;
    var trailingGarbage = 0;
    var reachedEnd = false;
    var crossAxisSize = 0.0;

    void updateCrossAxisSize(RenderBox? child) {
      if (child == null) return;
      crossAxisSize = math.max(
        crossAxisSize,
        constraints.axis == Axis.horizontal
            ? child.size.height
            : child.size.width,
      );
    }

    CrossAxisSizingSliverGeometry sizingGeometry(SliverGeometry geometry) {
      return CrossAxisSizingSliverGeometry(
        existing: geometry,
        crossAxisSize: crossAxisSize,
      );
    }

    if (firstChild == null) {
      if (!addInitialChild()) {
        geometry = sizingGeometry(SliverGeometry.zero);
        childManager.didFinishLayout();
        return;
      }
    }

    RenderBox? leadingChildWithLayout;
    RenderBox? trailingChildWithLayout;
    var earliestUsefulChild = firstChild;

    if (childScrollOffset(firstChild!) == null) {
      var leadingChildrenWithoutLayoutOffset = 0;
      while (earliestUsefulChild != null &&
          childScrollOffset(earliestUsefulChild) == null) {
        earliestUsefulChild = childAfter(earliestUsefulChild);
        leadingChildrenWithoutLayoutOffset += 1;
      }
      collectGarbage(leadingChildrenWithoutLayoutOffset, 0);
      if (firstChild == null) {
        if (!addInitialChild()) {
          geometry = sizingGeometry(SliverGeometry.zero);
          childManager.didFinishLayout();
          return;
        }
      }
    }

    earliestUsefulChild = firstChild;
    for (
      var earliestScrollOffset = childScrollOffset(earliestUsefulChild!)!;
      earliestScrollOffset > scrollOffset;
      earliestScrollOffset = childScrollOffset(earliestUsefulChild)!
    ) {
      earliestUsefulChild = insertAndLayoutLeadingChild(
        childConstraints,
        parentUsesSize: true,
      );
      updateCrossAxisSize(earliestUsefulChild);
      if (earliestUsefulChild == null) {
        final childParentData =
            firstChild!.parentData! as SliverMultiBoxAdaptorParentData;
        childParentData.layoutOffset = 0;

        if (scrollOffset == 0) {
          firstChild!.layout(childConstraints, parentUsesSize: true);
          earliestUsefulChild = firstChild;
          updateCrossAxisSize(earliestUsefulChild);
          leadingChildWithLayout = earliestUsefulChild;
          trailingChildWithLayout ??= earliestUsefulChild;
          break;
        } else {
          geometry = sizingGeometry(
            SliverGeometry(scrollOffsetCorrection: -scrollOffset),
          );
          return;
        }
      }

      final firstChildScrollOffset =
          earliestScrollOffset - paintExtentOf(firstChild!);
      if (firstChildScrollOffset < -precisionErrorTolerance) {
        geometry = sizingGeometry(
          SliverGeometry(scrollOffsetCorrection: -firstChildScrollOffset),
        );
        final childParentData =
            firstChild!.parentData! as SliverMultiBoxAdaptorParentData;
        childParentData.layoutOffset = 0;
        return;
      }

      final childParentData =
          earliestUsefulChild.parentData! as SliverMultiBoxAdaptorParentData;
      childParentData.layoutOffset = firstChildScrollOffset;
      leadingChildWithLayout = earliestUsefulChild;
      trailingChildWithLayout ??= earliestUsefulChild;
    }

    assert(childScrollOffset(firstChild!)! > -precisionErrorTolerance);

    if (scrollOffset < precisionErrorTolerance) {
      while (indexOf(firstChild!) > 0) {
        final earliestScrollOffset = childScrollOffset(firstChild!)!;
        earliestUsefulChild = insertAndLayoutLeadingChild(
          childConstraints,
          parentUsesSize: true,
        );
        updateCrossAxisSize(earliestUsefulChild);
        assert(earliestUsefulChild != null);
        final firstChildScrollOffset =
            earliestScrollOffset - paintExtentOf(firstChild!);
        final childParentData =
            firstChild!.parentData! as SliverMultiBoxAdaptorParentData;
        childParentData.layoutOffset = 0;
        if (firstChildScrollOffset < -precisionErrorTolerance) {
          geometry = sizingGeometry(
            SliverGeometry(scrollOffsetCorrection: -firstChildScrollOffset),
          );
          return;
        }
      }
    }

    assert(earliestUsefulChild == firstChild);
    assert(childScrollOffset(earliestUsefulChild!)! <= scrollOffset);

    if (leadingChildWithLayout == null) {
      earliestUsefulChild!.layout(childConstraints, parentUsesSize: true);
      updateCrossAxisSize(earliestUsefulChild);
      leadingChildWithLayout = earliestUsefulChild;
      trailingChildWithLayout = earliestUsefulChild;
    }

    var inLayoutRange = true;
    RenderBox? child = earliestUsefulChild;
    var index = indexOf(child!);
    var endScrollOffset = childScrollOffset(child)! + paintExtentOf(child);

    bool advance() {
      assert(child != null);
      if (child == trailingChildWithLayout) inLayoutRange = false;
      child = childAfter(child!);
      if (child == null) inLayoutRange = false;
      index += 1;
      if (!inLayoutRange) {
        if (child == null || indexOf(child!) != index) {
          child = insertAndLayoutChild(
            childConstraints,
            after: trailingChildWithLayout,
            parentUsesSize: true,
          );
          updateCrossAxisSize(child);
          if (child == null) return false;
        } else {
          child!.layout(childConstraints, parentUsesSize: true);
          updateCrossAxisSize(child);
        }
        trailingChildWithLayout = child;
      }
      final childParentData =
          child!.parentData! as SliverMultiBoxAdaptorParentData;
      childParentData.layoutOffset = endScrollOffset;
      assert(childParentData.index == index);
      endScrollOffset = childScrollOffset(child!)! + paintExtentOf(child!);
      return true;
    }

    while (endScrollOffset < scrollOffset) {
      leadingGarbage += 1;
      if (!advance()) {
        assert(leadingGarbage == childCount);
        collectGarbage(leadingGarbage - 1, 0);
        assert(firstChild == lastChild);
        final extent =
            childScrollOffset(lastChild!)! + paintExtentOf(lastChild!);
        geometry = sizingGeometry(
          SliverGeometry(
            scrollExtent: extent,
            paintExtent: 0,
            maxPaintExtent: extent,
          ),
        );
        return;
      }
    }

    while (endScrollOffset < targetEndScrollOffset) {
      if (!advance()) {
        reachedEnd = true;
        break;
      }
    }

    if (child != null) {
      child = childAfter(child!);
      while (child != null) {
        trailingGarbage += 1;
        child = childAfter(child!);
      }
    }

    collectGarbage(leadingGarbage, trailingGarbage);

    assert(debugAssertChildListIsNonEmptyAndContiguous());
    final estimatedMaxScrollOffset = reachedEnd
        ? endScrollOffset
        : childManager.estimateMaxScrollOffset(
            constraints,
            firstIndex: indexOf(firstChild!),
            lastIndex: indexOf(lastChild!),
            leadingScrollOffset: childScrollOffset(firstChild!),
            trailingScrollOffset: endScrollOffset,
          );
    assert(
      reachedEnd ||
          estimatedMaxScrollOffset >=
              endScrollOffset - childScrollOffset(firstChild!)!,
    );
    final paintExtent = calculatePaintOffset(
      constraints,
      from: childScrollOffset(firstChild!)!,
      to: endScrollOffset,
    );
    final cacheExtent = calculateCacheOffset(
      constraints,
      from: childScrollOffset(firstChild!)!,
      to: endScrollOffset,
    );
    final targetEndScrollOffsetForPaint =
        constraints.scrollOffset + constraints.remainingPaintExtent;
    geometry = sizingGeometry(
      SliverGeometry(
        scrollExtent: estimatedMaxScrollOffset,
        paintExtent: paintExtent,
        cacheExtent: cacheExtent,
        maxPaintExtent: estimatedMaxScrollOffset,
        hasVisualOverflow:
            endScrollOffset > targetEndScrollOffsetForPaint ||
            constraints.scrollOffset > 0,
      ),
    );

    if (estimatedMaxScrollOffset == endScrollOffset) {
      childManager.setDidUnderflow(true);
    }
    childManager.didFinishLayout();
  }
}

class CrossAxisSizingViewport = Viewport with CrossAxisSizingViewportMixin;

mixin CrossAxisSizingViewportMixin on Viewport {
  @override
  RenderViewport createRenderObject(BuildContext context) {
    return CrossAxisSizingRenderViewport(
      axisDirection: axisDirection,
      crossAxisDirection:
          crossAxisDirection ??
          Viewport.getDefaultCrossAxisDirection(context, axisDirection),
      anchor: anchor,
      offset: offset,
      cacheExtent: cacheExtent,
    );
  }
}

class CrossAxisSizingRenderViewport = RenderViewport
    with CrossAxisSizingRenderViewportMixin;

mixin CrossAxisSizingRenderViewportMixin on RenderViewport {
  double _unboundedCrossAxisSize = double.infinity;

  @override
  bool get sizedByParent => false;

  @override
  void performLayout() {
    final constraints = this.constraints;
    if (axis == Axis.horizontal) {
      _unboundedCrossAxisSize = constraints.maxHeight;
      size = Size(constraints.maxWidth, 0);
    } else {
      _unboundedCrossAxisSize = constraints.maxWidth;
      size = Size(0, constraints.maxHeight);
    }

    super.performLayout();

    switch (axis) {
      case Axis.vertical:
        offset.applyViewportDimension(size.height);
        break;
      case Axis.horizontal:
        offset.applyViewportDimension(size.width);
        break;
    }
  }

  @override
  double layoutChildSequence({
    required RenderSliver? child,
    required double scrollOffset,
    required double overlap,
    required double layoutOffset,
    required double remainingPaintExtent,
    required double mainAxisExtent,
    required double crossAxisExtent,
    required GrowthDirection growthDirection,
    required RenderSliver? Function(RenderSliver child) advance,
    required double remainingCacheExtent,
    required double cacheOrigin,
  }) {
    final firstChild = child;
    final result = super.layoutChildSequence(
      child: child,
      scrollOffset: scrollOffset,
      overlap: overlap,
      layoutOffset: layoutOffset,
      remainingPaintExtent: remainingPaintExtent,
      mainAxisExtent: mainAxisExtent,
      crossAxisExtent: _unboundedCrossAxisSize,
      growthDirection: growthDirection,
      advance: advance,
      remainingCacheExtent: remainingCacheExtent,
      cacheOrigin: cacheOrigin,
    );

    var crossAxisSize = 0.0;
    var current = firstChild;
    while (current != null) {
      final geometry = current.geometry;
      if (geometry is CrossAxisSizingSliverGeometry) {
        crossAxisSize = math.max(crossAxisSize, geometry.crossAxisSize);
      }
      current = advance(current);
    }
    if (axis == Axis.horizontal) {
      size = Size(size.width, crossAxisSize);
    } else {
      size = Size(crossAxisSize, size.height);
    }

    return result;
  }
}

class CrossAxisSizingSliverGeometry extends SliverGeometry {
  CrossAxisSizingSliverGeometry({
    SliverGeometry? existing,
    required this.crossAxisSize,
  }) : super(
         scrollExtent: existing?.scrollExtent ?? 0,
         paintExtent: existing?.paintExtent ?? 0,
         paintOrigin: existing?.paintOrigin ?? 0,
         layoutExtent: existing?.layoutExtent,
         maxPaintExtent: existing?.maxPaintExtent ?? 0,
         maxScrollObstructionExtent: existing?.maxScrollObstructionExtent ?? 0,
         hitTestExtent: existing?.hitTestExtent,
         visible: existing?.visible,
         hasVisualOverflow: existing?.hasVisualOverflow ?? false,
         scrollOffsetCorrection: existing?.scrollOffsetCorrection,
         cacheExtent: existing?.cacheExtent,
       );

  final double crossAxisSize;
}
