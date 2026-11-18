import 'dart:convert';
import 'dart:io';

class BuildFailure implements Exception {
  const BuildFailure(this.message);
  final String message;

  @override
  String toString() => message;
}

const gib = 1024 * 1024 * 1024;

final diskError = RegExp(
  r'no space left|not enough (free )?space|disk quota exceeded|\bENOSPC\b',
  caseSensitive: false,
);

Future<String> capture(String command, List<String> args) async {
  final result = await Process.run(command, args, environment: {'LC_ALL': 'C'});
  if (result.exitCode != 0) {
    throw BuildFailure(
      '$command failed (${result.exitCode}): ${result.stderr}',
    );
  }
  return (result.stdout as String).trim();
}

Future<void> run(
  String command,
  List<String> args, {
  String? cwd,
  Map<String, String> environment = const {},
  String? input,
}) async {
  final process = await Process.start(
    command,
    args,
    workingDirectory: cwd,
    environment: {'LC_ALL': 'C', ...environment},
  );
  var outOfSpace = false;
  Future<void> forward(Stream<List<int>> stream, IOSink output) async {
    await for (final line
        in stream
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())) {
      outOfSpace |= diskError.hasMatch(line);
      output.writeln(line);
    }
  }

  final streams = Future.wait([
    forward(process.stdout, stdout),
    forward(process.stderr, stderr),
  ]);
  if (input != null) process.stdin.write(input);
  await process.stdin.close();
  final code = await process.exitCode;
  await streams;
  if (code != 0) {
    final disk = outOfSpace ? 'Disk space exhausted. ' : '';
    throw BuildFailure(
      '${disk}$command ${args.take(3).join(' ')} failed ($code).',
    );
  }
}

Future<void> requireSpace(String path, int minimum) async {
  final data = await capture('df', ['-PB1', '--', path]);
  final available = int.parse(
    data.split('\n').last.trim().split(RegExp(r'\s+'))[3],
  );
  if (available < minimum) {
    throw BuildFailure(
      'Insufficient disk space at $path. '
      'Available ${(available / gib).toStringAsFixed(1)} GiB, '
      'need ${(minimum / gib).toStringAsFixed(1)} GiB.',
    );
  }
}
