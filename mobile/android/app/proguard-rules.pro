# Required by sqflite_sqlcipher: keeps the SQLCipher native binding intact
# once R8/ProGuard minification is enabled for release builds.
-keep class net.sqlcipher.** { *; }
