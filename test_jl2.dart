import 'package:jsonlogic/jsonlogic.dart';

void main() {
  final jl = Jsonlogic();
  try {
    print(jl.apply({"a": 1, "b": 2}, {}));
  } catch (e) {
    print("Error: $e");
  }
}
