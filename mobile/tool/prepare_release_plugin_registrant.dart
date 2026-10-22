import 'dart:convert';
import 'dart:io';

/// Flutter can leave dev-only plugins in its generated Android registrant
/// while Gradle excludes those plugins from release builds. Run after pub get
/// and build the release with --no-pub so the registrant stays consistent.
void main() {
  final metadata =
      jsonDecode(File('.flutter-plugins-dependencies').readAsStringSync())
          as Map<String, dynamic>;
  final plugins =
      (metadata['plugins'] as Map<String, dynamic>)['android'] as List;
  final devPlugins = plugins
      .whereType<Map<String, dynamic>>()
      .where((plugin) => plugin['dev_dependency'] == true)
      .map((plugin) => plugin['name'] as String)
      .toSet();
  final registrant = File(
    'android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java',
  );
  var source = registrant.readAsStringSync();
  for (final name in devPlugins) {
    final block = RegExp(
      r'    try \{\r?\n'
      r'      flutterEngine\.getPlugins\(\)\.add\(new [^\r\n]+\);\r?\n'
      r'    \} catch \(Exception e\) \{\r?\n'
      r'      Log\.e\(TAG, "Error registering plugin '
      '${RegExp.escape(name)}'
      r', [^\r\n]+\);\r?\n'
      r'    \}\r?\n',
    );
    source = source.replaceAll(block, '');
  }
  registrant.writeAsStringSync(source);
  stdout.writeln(
    'Release registrant excludes ${devPlugins.length} dev plugins.',
  );
}
