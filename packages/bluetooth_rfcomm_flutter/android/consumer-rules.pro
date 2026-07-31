# The Kotlin backend is referenced ONLY via JNI reflection (ClassLoader
# .loadClass + RegisterNatives) — no Java/Kotlin references exist, so R8
# strips or renames it in minified builds, silently breaking the plugin.
-keep class lol.carson.bluetooth_rfcomm.BluetoothRfcommAndroid { *; }
