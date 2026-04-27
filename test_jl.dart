import 'package:jsonlogic/jsonlogic.dart';
void main() {
  final jl = Jsonlogic();
  final rule = {"id": "{{ global.editingId }}"};
  final data = {};
  final result = jl.apply(rule, data);
  print(result);
}
