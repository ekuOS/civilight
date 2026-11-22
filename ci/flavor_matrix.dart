import 'dart:convert';
import 'dart:io';

import '../lib/flavor.dart';

Future<void> main() async {
  final src = Directory.fromUri(Platform.script.resolve('../src/'));
  final names = <String>[];
  await for (final dir in src.list(followLinks: false)) {
    if (dir is! Directory) continue;
    final name = dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
    await Flavor.load(name, src);
    names.add(name);
  }
  names.sort();
  final matrix = jsonEncode({
    'include': [
      {'name': 'minimal', 'src': ''},
      for (final name in names) {'name': 'flavor-$name', 'src': name},
    ],
  });
  final output = Platform.environment['GITHUB_OUTPUT'];
  if (output == null) {
    print(matrix);
  } else {
    await File(output).writeAsString('matrix=$matrix\n', mode: FileMode.append);
  }
}
