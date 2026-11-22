import 'dart:io';

import 'commands.dart';
import 'gentoo.dart' show readPackages;

class Flavor {
  Flavor(this.source, this.packages);
  final Directory source;
  final List<String> packages;
  Directory get overlay => Directory('${source.path}/overlay');

  static Future<Flavor> load(String argument, Directory sources) async {
    if (!RegExp(r'^[a-z0-9][a-z0-9_-]*$').hasMatch(argument)) {
      throw BuildFailure(
        '--src expects a flavor name such as gnome: $argument',
      );
    }
    final directory = Directory('${sources.path}/$argument');
    final list = File('${directory.path}/packages.conf');
    if (!await list.exists()) {
      throw BuildFailure('Flavor package list not found: ${list.path}');
    }
    return Flavor(directory.absolute, await readPackages(list));
  }
}

// Extract inside the guest: absolute symlinks in either tree must resolve
// relative to the guest, not the build host. Preserve modes and symlinks,
// but never import the checkout user's uid/gid into the image.
Future<void> applyOverlay(
  Directory tree,
  Directory root, {
  String at = '/',
}) async {
  if (!await tree.exists()) return;
  final archive = await Process.start('tar', [
    '--create',
    '--file=-',
    '--owner=0',
    '--group=0',
    '-C',
    tree.path,
    '.',
  ]);
  final extract = await Process.start('chroot', [
    root.path,
    'tar',
    '--extract',
    '--file=-',
    '--no-overwrite-dir',
    '--same-permissions',
    '-C',
    at,
  ]);
  try {
    await Future.wait([
      archive.stdout.pipe(extract.stdin),
      archive.stderr.forEach(stderr.add),
      extract.stderr.forEach(stderr.add),
      extract.stdout.forEach(stdout.add),
    ]);
    if (await archive.exitCode != 0 || await extract.exitCode != 0) {
      throw BuildFailure('Could not apply overlay ${tree.path} to $at');
    }
  } finally {
    archive.kill();
    extract.kill();
  }
}
