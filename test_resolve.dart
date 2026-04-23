import 'dart:convert';
void main() {
  var template = "{{ global.editingId }}";
  final regex = RegExp(r'\{\{\s*(.+?)\s*\}\}');
  var result = template.replaceAllMapped(regex, (match) {
    return '1234';
  });
  print(result);
}
