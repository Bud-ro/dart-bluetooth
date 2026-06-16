cmake_minimum_required(VERSION 3.10)
project(bluetooth_rfcomm_android C)

# Produces libbluetooth_rfcomm_android.so, which Flutter bundles into the APK's
# jniLibs and Dart loads by name via dart:ffi (see android_bindings.dart).
add_library(bluetooth_rfcomm_android SHARED
  ${CMAKE_CURRENT_SOURCE_DIR}/../native/android/bluetooth_rfcomm_jni.c)

find_library(log-lib log)
target_link_libraries(bluetooth_rfcomm_android ${log-lib})
