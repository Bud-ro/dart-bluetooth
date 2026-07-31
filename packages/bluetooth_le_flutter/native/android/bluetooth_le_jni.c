// Android C ABI shim for bluetooth_le.
//
// Dart (dart:ffi) calls the ble_and_* functions here; this shim forwards them to
// the Kotlin BluetoothLeAndroid via JNI, and the Kotlin side pushes events back
// by calling the native* methods we RegisterNatives below, which invoke the Dart
// callback function pointers (NativeCallable.listener).
//
// The callback shapes (scan/state/op/notify) deliberately mirror the Apple C ABI
// in bluetooth_le's src/native/apple/include/bluetooth_le.h so the Dart backend
// can correlate async GATT ops the same way (request-id <-> Completer, notify
// routing keyed "service|char").
//
// To stay Flutter-free we never rely on JNI_OnLoad firing (a dlopen'd library on
// Android doesn't get it). Instead we obtain the running JavaVM via
// JNI_GetCreatedJavaVMs and bind the callback natives with RegisterNatives.
//
// NOTE: This is structurally complete but requires on-device validation.

#include <dlfcn.h>
#include <jni.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// Exported to Dart via dart:ffi DynamicLibrary.open + lookupFunction.
#define BLE_EXPORT __attribute__((visibility("default"), used))

typedef void (*ble_scan_cb)(int64_t scan_token, const char *json);
typedef void (*ble_state_cb)(int64_t conn_token, int32_t state);
typedef void (*ble_op_cb)(int64_t req_id, int32_t status, const char *json,
                          const uint8_t *data, int32_t len);
typedef void (*ble_notify_cb)(int64_t conn_token, const char *characteristic,
                              const uint8_t *data, int32_t len);

static JavaVM *g_vm = NULL;
static jclass g_class = NULL; // global ref to BluetoothLeAndroid
static int g_natives_registered = 0;

static ble_scan_cb g_scan = NULL;
static ble_state_cb g_state = NULL;
static ble_op_cb g_op = NULL;
static ble_notify_cb g_notify = NULL;

static const char *kClassName = "lol/carson/bluetooth_le/BluetoothLeAndroid";
// Dotted form for ClassLoader.loadClass (which takes binary names, not the
// slash-separated JNI descriptors FindClass takes).
static const char *kClassNameDotted = "lol.carson.bluetooth_le.BluetoothLeAndroid";

static char *jstring_to_utf8(JNIEnv *env, jstring s);
static uint8_t *jbytes_copy(JNIEnv *env, jbyteArray arr, int32_t *out_len);

// --- JVM / env acquisition ---------------------------------------------------

jint JNI_OnLoad(JavaVM *vm, void *reserved) {
  (void)reserved;
  g_vm = vm;
  // If the library was loaded via System.loadLibrary (rather than Dart's
  // dlopen), this thread has managed frames from the app classloader, so a
  // plain FindClass resolves the Kotlin class. Cache it now — ble_and_init on
  // a natively-attached Dart thread could otherwise only see the boot
  // classloader (see find_app_class).
  JNIEnv *env = NULL;
  if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) == JNI_OK && env) {
    jclass local = (*env)->FindClass(env, kClassName);
    if (local) {
      g_class = (jclass)(*env)->NewGlobalRef(env, local);
      (*env)->DeleteLocalRef(env, local);
    } else if ((*env)->ExceptionCheck(env)) {
      (*env)->ExceptionClear(env);
    }
  }
  return JNI_VERSION_1_6;
}

static int ensure_vm(void) {
  if (g_vm) return 0;
  typedef jint (*GetVMs)(JavaVM **, jsize, jsize *);
  GetVMs getVMs = (GetVMs)dlsym(RTLD_DEFAULT, "JNI_GetCreatedJavaVMs");
  if (!getVMs) {
    void *h = dlopen("libnativehelper.so", RTLD_NOW);
    if (h) getVMs = (GetVMs)dlsym(h, "JNI_GetCreatedJavaVMs");
  }
  if (!getVMs) return -1;
  jsize n = 0;
  if (getVMs(&g_vm, 1, &n) != JNI_OK || n == 0) {
    g_vm = NULL;
    return -1;
  }
  return 0;
}

static pthread_key_t g_detach_key;
static pthread_once_t g_detach_once = PTHREAD_ONCE_INIT;

static void detach_current_thread(void *arg) {
  (void)arg;
  if (g_vm) (*g_vm)->DetachCurrentThread(g_vm);
}

static void make_detach_key(void) {
  pthread_key_create(&g_detach_key, detach_current_thread);
}

static JNIEnv *get_env(void) {
  if (ensure_vm() != 0) return NULL;
  JNIEnv *env = NULL;
  jint r = (*g_vm)->GetEnv(g_vm, (void **)&env, JNI_VERSION_1_6);
  if (r == JNI_EDETACHED) {
    if ((*g_vm)->AttachCurrentThread(g_vm, (void *)&env, NULL) != JNI_OK) return NULL;
    pthread_once(&g_detach_once, make_detach_key);
    pthread_setspecific(g_detach_key, (void *)1);
  } else if (r != JNI_OK) {
    return NULL;
  }
  return env;
}

// --- callbacks invoked from Kotlin (RegisterNatives targets) -----------------

static void nOnScan(JNIEnv *env, jclass clazz, jlong token, jstring json) {
  (void)clazz;
  if (!g_scan || !json) return;
  char *copy = jstring_to_utf8(env, json);
  if (copy) g_scan((int64_t)token, copy);
}

static void nOnState(JNIEnv *env, jclass clazz, jlong token, jint state) {
  (void)env;
  (void)clazz;
  if (g_state) g_state((int64_t)token, (int32_t)state);
}

static void nOnOp(JNIEnv *env, jclass clazz, jlong reqId, jint status,
                  jstring json, jbyteArray data) {
  (void)clazz;
  if (!g_op) return;
  char *jcopy = json ? jstring_to_utf8(env, json) : NULL;
  int32_t len = 0;
  uint8_t *dcopy = data ? jbytes_copy(env, data, &len) : NULL;
  g_op((int64_t)reqId, (int32_t)status, jcopy, dcopy, len);
}

static void nOnNotify(JNIEnv *env, jclass clazz, jlong token, jstring key,
                      jbyteArray data) {
  (void)clazz;
  if (!g_notify || !key) return;
  char *kcopy = jstring_to_utf8(env, key);
  int32_t len = 0;
  uint8_t *dcopy = data ? jbytes_copy(env, data, &len) : NULL;
  if (kcopy) g_notify((int64_t)token, kcopy, dcopy, len);
}

// --- helpers -----------------------------------------------------------------

static jmethodID static_method(JNIEnv *env, const char *name, const char *sig) {
  if (!g_class) return NULL;
  jmethodID m = (*env)->GetStaticMethodID(env, g_class, name, sig);
  if (!m && (*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
  return m;
}

static void clear_pending(JNIEnv *env) {
  if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
}

// Resolves the Kotlin class, returning a LOCAL ref (caller makes it global).
//
// FindClass on a natively-attached thread with no managed frames (the Dart
// mutator that dlopen'd us) resolves against the system/boot classloader on
// ART, which cannot see app-APK classes — so when it fails we go through the
// application classloader instead: ActivityThread.currentApplication() (a
// framework class, always findable) -> getClassLoader() -> loadClass(name).
static jclass find_app_class(JNIEnv *env) {
  jclass local = (*env)->FindClass(env, kClassName);
  if (local) return local;
  clear_pending(env);

  jclass activityThread = (*env)->FindClass(env, "android/app/ActivityThread");
  if (!activityThread) {
    clear_pending(env);
    return NULL;
  }
  jmethodID currentApplication = (*env)->GetStaticMethodID(
      env, activityThread, "currentApplication", "()Landroid/app/Application;");
  if (!currentApplication) {
    clear_pending(env);
    (*env)->DeleteLocalRef(env, activityThread);
    return NULL;
  }
  jobject app =
      (*env)->CallStaticObjectMethod(env, activityThread, currentApplication);
  (*env)->DeleteLocalRef(env, activityThread);
  clear_pending(env);
  if (!app) return NULL;

  jclass appCls = (*env)->GetObjectClass(env, app);
  jmethodID getClassLoader = (*env)->GetMethodID(
      env, appCls, "getClassLoader", "()Ljava/lang/ClassLoader;");
  (*env)->DeleteLocalRef(env, appCls);
  if (!getClassLoader) {
    clear_pending(env);
    (*env)->DeleteLocalRef(env, app);
    return NULL;
  }
  jobject loader = (*env)->CallObjectMethod(env, app, getClassLoader);
  (*env)->DeleteLocalRef(env, app);
  clear_pending(env);
  if (!loader) return NULL;

  jclass loaderCls = (*env)->GetObjectClass(env, loader);
  jmethodID loadClass = (*env)->GetMethodID(
      env, loaderCls, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;");
  (*env)->DeleteLocalRef(env, loaderCls);
  if (!loadClass) {
    clear_pending(env);
    (*env)->DeleteLocalRef(env, loader);
    return NULL;
  }
  jstring name = (*env)->NewStringUTF(env, kClassNameDotted);
  if (!name) {
    clear_pending(env);
    (*env)->DeleteLocalRef(env, loader);
    return NULL;
  }
  jclass result =
      (jclass)(*env)->CallObjectMethod(env, loader, loadClass, name);
  (*env)->DeleteLocalRef(env, name);
  (*env)->DeleteLocalRef(env, loader);
  if ((*env)->ExceptionCheck(env)) {
    (*env)->ExceptionClear(env);
    if (result) (*env)->DeleteLocalRef(env, result);
    return NULL;
  }
  return result;
}

static uint8_t *jbytes_copy(JNIEnv *env, jbyteArray arr, int32_t *out_len) {
  *out_len = 0;
  if (!arr) return NULL;
  jsize len = (*env)->GetArrayLength(env, arr);
  if (len <= 0) return NULL;
  uint8_t *copy = malloc((size_t)len);
  if (!copy) return NULL;
  (*env)->GetByteArrayRegion(env, arr, 0, len, (jbyte *)copy);
  if ((*env)->ExceptionCheck(env)) {
    (*env)->ExceptionClear(env);
    free(copy);
    return NULL;
  }
  *out_len = (int32_t)len;
  return copy;
}

// Standard UTF-8 (emoji-safe) copy of a Java String via String.getBytes("UTF-8").
static char *jstring_to_utf8(JNIEnv *env, jstring s) {
  if (!s) return NULL;
  jclass cls = (*env)->GetObjectClass(env, s);
  if (!cls) return NULL;
  jmethodID getBytes =
      (*env)->GetMethodID(env, cls, "getBytes", "(Ljava/lang/String;)[B");
  (*env)->DeleteLocalRef(env, cls);
  if (!getBytes) {
    clear_pending(env);
    return NULL;
  }
  jstring charset = (*env)->NewStringUTF(env, "UTF-8");
  if (!charset) {
    clear_pending(env);
    return NULL;
  }
  jbyteArray bytes =
      (jbyteArray)(*env)->CallObjectMethod(env, s, getBytes, charset);
  (*env)->DeleteLocalRef(env, charset);
  if ((*env)->ExceptionCheck(env)) {
    (*env)->ExceptionClear(env);
    return NULL;
  }
  if (!bytes) return NULL;
  jsize len = (*env)->GetArrayLength(env, bytes);
  char *out = malloc((size_t)len + 1);
  if (out) {
    (*env)->GetByteArrayRegion(env, bytes, 0, len, (jbyte *)out);
    if ((*env)->ExceptionCheck(env)) {
      (*env)->ExceptionClear(env);
      free(out);
      out = NULL;
    } else {
      out[len] = '\0';
    }
  }
  (*env)->DeleteLocalRef(env, bytes);
  return out;
}

// --- C ABI -------------------------------------------------------------------

BLE_EXPORT void ble_free(void *ptr) {
  if (ptr) free(ptr);
}

BLE_EXPORT void ble_and_register(ble_scan_cb scan, ble_state_cb state,
                                 ble_op_cb op, ble_notify_cb notify) {
  g_scan = scan;
  g_state = state;
  g_op = op;
  g_notify = notify;
}

BLE_EXPORT int32_t ble_and_init(void) {
  JNIEnv *env = get_env();
  if (!env) return 1; // unavailable
  if (!g_class) {
    jclass local = find_app_class(env);
    if (!local) return 1;
    g_class = (jclass)(*env)->NewGlobalRef(env, local);
    (*env)->DeleteLocalRef(env, local);
  }
  // Registered separately from class caching: g_class may already have been
  // cached by JNI_OnLoad (System.loadLibrary path) with no natives bound yet.
  if (!g_natives_registered) {
    static const JNINativeMethod methods[] = {
        {"nativeOnScan", "(JLjava/lang/String;)V", (void *)nOnScan},
        {"nativeOnState", "(JI)V", (void *)nOnState},
        {"nativeOnOp", "(JILjava/lang/String;[B)V", (void *)nOnOp},
        {"nativeOnNotify", "(JLjava/lang/String;[B)V", (void *)nOnNotify},
    };
    if ((*env)->RegisterNatives(env, g_class, methods, 4) != JNI_OK) {
      (*env)->ExceptionClear(env);
      return 1;
    }
    g_natives_registered = 1;
  }
  jmethodID m = static_method(env, "initialize", "()I");
  if (!m) return 1;
  int32_t r = (int32_t)(*env)->CallStaticIntMethod(env, g_class, m);
  clear_pending(env);
  return r;
}

BLE_EXPORT int32_t ble_and_adapter_state(void) {
  JNIEnv *env = get_env();
  if (!env) return 1;
  jmethodID m = static_method(env, "adapterState", "()I");
  if (!m) return 1;
  int32_t r = (int32_t)(*env)->CallStaticIntMethod(env, g_class, m);
  clear_pending(env);
  return r;
}

BLE_EXPORT int32_t ble_and_start_scan(int64_t token, const char *csv) {
  JNIEnv *env = get_env();
  if (!env) return -1;
  jmethodID m = static_method(env, "startScan", "(JLjava/lang/String;)I");
  if (!m) return -1;
  jstring jcsv = (*env)->NewStringUTF(env, csv ? csv : "");
  int32_t r =
      (int32_t)(*env)->CallStaticIntMethod(env, g_class, m, (jlong)token, jcsv);
  clear_pending(env);
  (*env)->DeleteLocalRef(env, jcsv);
  return r;
}

BLE_EXPORT void ble_and_stop_scan(void) {
  JNIEnv *env = get_env();
  if (!env) return;
  jmethodID m = static_method(env, "stopScan", "()V");
  if (!m) return;
  (*env)->CallStaticVoidMethod(env, g_class, m);
  clear_pending(env);
}

BLE_EXPORT int32_t ble_and_connect(int64_t conn_token, const char *address) {
  JNIEnv *env = get_env();
  if (!env) return -1;
  jmethodID m = static_method(env, "connect", "(JLjava/lang/String;)I");
  if (!m) return -1;
  jstring jaddr = (*env)->NewStringUTF(env, address);
  int32_t r = (int32_t)(*env)->CallStaticIntMethod(env, g_class, m,
                                                   (jlong)conn_token, jaddr);
  clear_pending(env);
  (*env)->DeleteLocalRef(env, jaddr);
  return r;
}

BLE_EXPORT void ble_and_disconnect(int64_t conn_token) {
  JNIEnv *env = get_env();
  if (!env) return;
  jmethodID m = static_method(env, "disconnect", "(J)V");
  if (!m) return;
  (*env)->CallStaticVoidMethod(env, g_class, m, (jlong)conn_token);
  clear_pending(env);
}

BLE_EXPORT void ble_and_discover_services(int64_t req_id, int64_t conn_token) {
  JNIEnv *env = get_env();
  if (!env) return;
  jmethodID m = static_method(env, "discoverServices", "(JJ)V");
  if (!m) return;
  (*env)->CallStaticVoidMethod(env, g_class, m, (jlong)req_id,
                               (jlong)conn_token);
  clear_pending(env);
}

BLE_EXPORT void ble_and_read(int64_t req_id, int64_t conn_token,
                             const char *service, const char *characteristic) {
  JNIEnv *env = get_env();
  if (!env) return;
  jmethodID m = static_method(
      env, "readCharacteristic",
      "(JJLjava/lang/String;Ljava/lang/String;)V");
  if (!m) return;
  jstring jsvc = (*env)->NewStringUTF(env, service);
  jstring jchr = (*env)->NewStringUTF(env, characteristic);
  (*env)->CallStaticVoidMethod(env, g_class, m, (jlong)req_id,
                               (jlong)conn_token, jsvc, jchr);
  clear_pending(env);
  (*env)->DeleteLocalRef(env, jsvc);
  (*env)->DeleteLocalRef(env, jchr);
}

BLE_EXPORT void ble_and_write(int64_t req_id, int64_t conn_token,
                              const char *service, const char *characteristic,
                              const uint8_t *data, int32_t len,
                              int32_t without_response) {
  JNIEnv *env = get_env();
  if (!env) return;
  jmethodID m = static_method(
      env, "writeCharacteristic",
      "(JJLjava/lang/String;Ljava/lang/String;[BZ)V");
  if (!m) return;
  jstring jsvc = (*env)->NewStringUTF(env, service);
  jstring jchr = (*env)->NewStringUTF(env, characteristic);
  jbyteArray arr = (*env)->NewByteArray(env, len);
  if (!arr) {
    // OOM: don't pass null to Kotlin's non-null ByteArray param (would NPE and
    // leave the Dart op hung). Leave it to be torn down / time out.
    clear_pending(env);
    (*env)->DeleteLocalRef(env, jsvc);
    (*env)->DeleteLocalRef(env, jchr);
    return;
  }
  if (len > 0) {
    (*env)->SetByteArrayRegion(env, arr, 0, len, (const jbyte *)data);
  }
  (*env)->CallStaticVoidMethod(env, g_class, m, (jlong)req_id,
                               (jlong)conn_token, jsvc, jchr, arr,
                               (jboolean)(without_response ? JNI_TRUE
                                                           : JNI_FALSE));
  clear_pending(env);
  (*env)->DeleteLocalRef(env, jsvc);
  (*env)->DeleteLocalRef(env, jchr);
  if (arr) (*env)->DeleteLocalRef(env, arr);
}

BLE_EXPORT void ble_and_subscribe(int64_t req_id, int64_t conn_token,
                                  const char *service,
                                  const char *characteristic, int32_t enable) {
  JNIEnv *env = get_env();
  if (!env) return;
  jmethodID m = static_method(
      env, "subscribe", "(JJLjava/lang/String;Ljava/lang/String;Z)V");
  if (!m) return;
  jstring jsvc = (*env)->NewStringUTF(env, service);
  jstring jchr = (*env)->NewStringUTF(env, characteristic);
  (*env)->CallStaticVoidMethod(env, g_class, m, (jlong)req_id,
                               (jlong)conn_token, jsvc, jchr,
                               (jboolean)(enable ? JNI_TRUE : JNI_FALSE));
  clear_pending(env);
  (*env)->DeleteLocalRef(env, jsvc);
  (*env)->DeleteLocalRef(env, jchr);
}

BLE_EXPORT void ble_and_request_mtu(int64_t req_id, int64_t conn_token,
                                    int32_t mtu) {
  JNIEnv *env = get_env();
  if (!env) return;
  jmethodID m = static_method(env, "requestMtu", "(JJI)V");
  if (!m) return;
  (*env)->CallStaticVoidMethod(env, g_class, m, (jlong)req_id,
                               (jlong)conn_token, (jint)mtu);
  clear_pending(env);
}

// Quiesces every Kotlin-side event source (scan callback, GATT connections)
// WITHOUT touching the registered callback pointers — the Dart layer calls
// this at construction, before registering fresh NativeCallable pointers, so
// nothing left over from a dead isolate (Flutter hot restart) can invoke a
// destroyed trampoline; also called at dispose.
BLE_EXPORT void ble_and_reset(void) {
  JNIEnv *env = get_env();
  if (!env) return;
  jmethodID m = static_method(env, "reset", "()I");
  if (!m) return;
  (*env)->CallStaticIntMethod(env, g_class, m);
  clear_pending(env);
}
