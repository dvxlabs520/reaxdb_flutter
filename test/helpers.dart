import 'dart:io';

import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:reaxdb_flutter/reaxdb_flutter.dart';

/// Points path_provider at a temporary directory.
class FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  FakePathProvider(this.root);

  final Directory root;

  @override
  Future<String?> getApplicationSupportPath() async => root.path;
}

/// A fresh support directory and an empty secure storage for one test.
///
/// Closes every database that is still open when the test ends.
Future<Directory> setUpFakePlatform({Map<String, String>? storedValues}) async {
  final Directory root = await Directory.systemTemp.createTemp(
    'reaxdb_flutter_test_',
  );
  PathProviderPlatform.instance = FakePathProvider(root);
  FlutterSecureStorage.setMockInitialValues(storedValues ?? <String, String>{});
  return root;
}

Future<void> tearDownFakePlatform(Directory root) async {
  await ReaxDB.closeAll();
  if (await root.exists()) await root.delete(recursive: true);
}
