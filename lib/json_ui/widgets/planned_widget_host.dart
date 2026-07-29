import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Rebuilds one compiler-approved JSON widget when its state paths change.
///
/// This is intentionally a plain component widget. It does not insert a
/// RenderObject, so ParentDataWidget relationships such as Positioned and
/// Expanded remain unchanged.
final class PlannedWidgetHost extends StatelessWidget {
  const PlannedWidgetHost({
    required this.revision,
    required this.builder,
    super.key,
  });

  final ValueListenable<int> revision;
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: revision,
      builder: (context, _, __) {
        try {
          return builder(context);
        } catch (error, stack) {
          // The host defers its real JSON builder to a descendant build phase,
          // outside JsonScreenView's synchronous try/catch. Route failures
          // through the app-wide ErrorWidget handler so production still opens
          // the normal JSON-App crash page instead of leaking a FlutterError.
          return ErrorWidget.builder(
            FlutterErrorDetails(
              exception: error,
              stack: stack,
              library: 'JSON App planned widget',
              context: ErrorDescription(
                'while building a compiled JSON widget',
              ),
            ),
          );
        }
      },
    );
  }
}
