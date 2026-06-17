cmake_minimum_required(VERSION 3.10)
project(bluetooth_le_android C)

# Produces libbluetooth_le_android.so, which Flutter bundles into the APK's
# jniLibs and Dart loads by name via dart:ffi (see android_bindings.dart).
add_library(bluetooth_le_android SHARED
  ${CMAKE_CURRENT_SOURCE_DIR}/../native/android/bluetooth_le_jni.c)

find_library(log-lib log)
target_link_libraries(bluetooth_le_android ${log-lib})
