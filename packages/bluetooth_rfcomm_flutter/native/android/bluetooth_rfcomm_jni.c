// Android C ABI shim for bluetooth_rfcomm.
//
// Dart (dart:ffi) calls the btc_and_* functions here; this shim forwards them to
// the Kotlin BluetoothRfcommAndroid via JNI, and the Kotlin side pushes events
// back by calling the native* methods we RegisterNatives below, which invoke the
// Dart callback function pointers (NativeCallable.listener).
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
// `used` + default visibility keep release NDK builds (-fvisibility=hidden,
// --gc-sections, strip) from removing these otherwise-unreferenced symbols.
#define BTC_EXPORT __attribute__((visibility("default"), used))

typedef void (*btc_found_cb)(int64_t token, const char *json);
typedef void (*btc_inquiry_done_cb)(int64_t token, int32_t aborted);
typedef void (*btc_data_cb)(int64_t token, const uint8_t *data, int32_t len);
typedef void (*btc_state_cb)(int64_t token, int32_t state);

static JavaVM *g_vm = NULL;
static jclass g_class = NULL; // global ref to BluetoothRfcommAndroid
static int g_natives_registered = 0;
// Guards g_class/g_natives_registered: btc_and_init can be reached from two
// isolates at once (dup NewGlobalRef leak / double RegisterNatives otherwise).
static pthread_mutex_t g_init_lock = PTHREAD_MUTEX_INITIALIZER;

// _Atomic: written by the Dart mutator (register/dispose) and read by Kotlin
// read-loop/binder threads. The dispose handoff nulls these BEFORE releasing
// the isolate pin, and that only quiesces late Kotlin events if the null
// actually becomes visible to those threads — a plain global gives no such
// guarantee (a C data race), and the loser would dial a destroyed trampoline.
static _Atomic btc_found_cb g_found = NULL;
static _Atomic btc_inquiry_done_cb g_done = NULL;
static _Atomic btc_data_cb g_data = NULL;
static _Atomic btc_state_cb g_state = NULL;

static const char *kClassName = "lol/carson/bluetooth_rfcomm/BluetoothRfcommAndroid";
// Dotted form for ClassLoader.loadClass (which takes binary names, not the
// slash-separated JNI descriptors FindClass takes).
static const char *kClassNameDotted =
    "lol.carson.bluetooth_rfcomm.BluetoothRfcommAndroid";

// Marshals a Java String to a malloc'd, NUL-terminated *standard* UTF-8 buffer
// (caller frees). GetStringUTFChars returns JNI modified UTF-8 — astral chars
// (emoji) come back as CESU-8, which Dart's utf8.decode rejects, so a single
// emoji-named device would make the whole JSON payload fail to parse. Going
// through String.getBytes("UTF-8") yields proper UTF-8.
static char *jstring_to_utf8(JNIEnv *env, jstring s);

// --- JVM / env acquisition ---------------------------------------------------

jint JNI_OnLoad(JavaVM *vm, void *reserved) {
  g_vm = vm;
  // If the library was loaded via System.loadLibrary (rather than Dart's
  // dlopen), this thread has managed frames from the app classloader, so a
  // plain FindClass resolves the Kotlin class. Cache it now — btc_and_init on
  // a natively-attached Dart thread could otherwise only see the boot
  // classloader (see find_app_class).
  // Under g_init_lock: this can race a Dart isolate's btc_and_init, and an
  // unlocked double-cache would leak a global ref.
  JNIEnv *env = NULL;
  if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) == JNI_OK && env) {
    pthread_mutex_lock(&g_init_lock);
    if (!g_class) {
      jclass local = (*env)->FindClass(env, kClassName);
      if (local) {
        g_class = (jclass)(*env)->NewGlobalRef(env, local);
        (*env)->DeleteLocalRef(env, local);
      } else if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
      }
    }
    pthread_mutex_unlock(&g_init_lock);
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

// TLS key whose destructor detaches a thread we attached, so a native thread
// (e.g. the Dart mutator) that calls in here doesn't leak a permanent JVM
// attachment across engine/isolate teardown.
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
    // Arrange to detach when this thread exits.
    pthread_once(&g_detach_once, make_detach_key);
    pthread_setspecific(g_detach_key, (void *)1);
  } else if (r != JNI_OK) {
    return NULL;
  }
  return env;
}

// --- callbacks invoked from Kotlin (RegisterNatives targets) -----------------
//
// These run on JVM-attached Kotlin threads (BroadcastReceiver, read loop), so
// no AttachCurrentThread is involved. Local-ref hygiene: the jstring/jbyteArray
// arguments are JVM-managed local refs, freed automatically when each native
// call returns to Java — even when Kotlin fires these in a loop (one native
// invocation per event) — so no explicit DeleteLocalRef is needed here.
// jstring_to_utf8 deletes every local it creates itself.

static void nOnFound(JNIEnv *env, jclass clazz, jlong token, jstring json) {
  if (!g_found || !json) return;
  char *copy = jstring_to_utf8(env, json); // standard UTF-8 (emoji-safe)
  if (copy) g_found((int64_t)token, copy);
}

static void nOnInquiryDone(JNIEnv *env, jclass clazz, jlong token,
                           jint aborted) {
  if (g_done) g_done((int64_t)token, (int32_t)aborted);
}

static void nOnData(JNIEnv *env, jclass clazz, jlong token, jbyteArray arr) {
  if (!g_data || !arr) return;
  jsize len = (*env)->GetArrayLength(env, arr);
  if (len <= 0) return;
  uint8_t *copy = malloc((size_t)len);
  if (!copy) return;
  (*env)->GetByteArrayRegion(env, arr, 0, len, (jbyte *)copy);
  if ((*env)->ExceptionCheck(env)) {
    (*env)->ExceptionClear(env);
    free(copy);
    return;
  }
  g_data((int64_t)token, copy, (int32_t)len);
}

static void nOnState(JNIEnv *env, jclass clazz, jlong token, jint state) {
  if (g_state) g_state((int64_t)token, (int32_t)state);
}

// --- helpers -----------------------------------------------------------------

static jmethodID static_method(JNIEnv *env, const char *name, const char *sig) {
  if (!g_class) return NULL;
  jmethodID m = (*env)->GetStaticMethodID(env, g_class, name, sig);
  if (!m && (*env)->ExceptionCheck(env)) {
    // Clear the pending NoSuchMethodError so the next JNI call doesn't abort.
    (*env)->ExceptionClear(env);
  }
  return m;
}

// Clears any pending JNI exception left by a CallStatic* (e.g. an unexpected
// throw); the Kotlin methods catch their own errors, but this is belt-and-braces
// so a stray pending exception can never abort the VM on the next JNI call.
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

BTC_EXPORT void btc_free(void *ptr) {
  if (ptr) free(ptr);
}

BTC_EXPORT void btc_and_register(btc_found_cb found, btc_inquiry_done_cb done,
                      btc_data_cb data, btc_state_cb state) {
  g_found = found;
  g_done = done;
  g_data = data;
  g_state = state;
}

// Returns Kotlin initialize()'s code (0 ok, 1 no adapter, 2 no context) or
// BTC_INIT_BRIDGE_FAILED when the JNI plumbing itself is broken (no JVM, class
// not found — e.g. stripped by R8 — or RegisterNatives failed). Distinct so
// the Dart layer never reports a plumbing failure as "no Bluetooth on this
// phone".
#define BTC_INIT_BRIDGE_FAILED 7

BTC_EXPORT int32_t btc_and_init(void) {
  JNIEnv *env = get_env();
  if (!env) return BTC_INIT_BRIDGE_FAILED;
  pthread_mutex_lock(&g_init_lock);
  if (!g_class) {
    jclass local = find_app_class(env);
    if (!local) {
      pthread_mutex_unlock(&g_init_lock);
      return BTC_INIT_BRIDGE_FAILED;
    }
    g_class = (jclass)(*env)->NewGlobalRef(env, local);
    (*env)->DeleteLocalRef(env, local);
  }
  // Registered separately from class caching: g_class may already have been
  // cached by JNI_OnLoad (System.loadLibrary path) with no natives bound yet.
  if (!g_natives_registered) {
    static const JNINativeMethod methods[] = {
        {"nativeOnFound", "(JLjava/lang/String;)V", (void *)nOnFound},
        {"nativeOnInquiryDone", "(JI)V", (void *)nOnInquiryDone},
        {"nativeOnData", "(J[B)V", (void *)nOnData},
        {"nativeOnState", "(JI)V", (void *)nOnState},
    };
    if ((*env)->RegisterNatives(env, g_class, methods, 4) != JNI_OK) {
      (*env)->ExceptionClear(env);
      pthread_mutex_unlock(&g_init_lock);
      return BTC_INIT_BRIDGE_FAILED;
    }
    g_natives_registered = 1;
  }
  pthread_mutex_unlock(&g_init_lock);
  jmethodID m = static_method(env, "initialize", "()I");
  if (!m) return BTC_INIT_BRIDGE_FAILED;
  int32_t r = (int32_t)(*env)->CallStaticIntMethod(env, g_class, m);
  clear_pending(env);
  return r;
}

BTC_EXPORT int32_t btc_and_adapter_state(void) {
  JNIEnv *env = get_env();
  if (!env) return BTC_INIT_BRIDGE_FAILED;
  jmethodID m = static_method(env, "adapterState", "()I");
  if (!m) return BTC_INIT_BRIDGE_FAILED;
  int32_t r = (int32_t)(*env)->CallStaticIntMethod(env, g_class, m);
  clear_pending(env);
  return r;
}

BTC_EXPORT char *btc_and_bonded_json(void) {
  JNIEnv *env = get_env();
  if (!env) return NULL;
  jmethodID m = static_method(env, "bondedJson", "()Ljava/lang/String;");
  if (!m) return NULL;
  jstring s = (jstring)(*env)->CallStaticObjectMethod(env, g_class, m);
  clear_pending(env);
  char *out = jstring_to_utf8(env, s);
  if (s) (*env)->DeleteLocalRef(env, s);
  return out;
}

BTC_EXPORT int32_t btc_and_start_discovery(int64_t token) {
  JNIEnv *env = get_env();
  if (!env) return -1;
  jmethodID m = static_method(env, "startDiscovery", "(J)I");
  if (!m) return -1;
  int32_t r =
      (int32_t)(*env)->CallStaticIntMethod(env, g_class, m, (jlong)token);
  clear_pending(env);
  return r;
}

BTC_EXPORT int32_t btc_and_stop_discovery(void) {
  JNIEnv *env = get_env();
  if (!env) return -1;
  jmethodID m = static_method(env, "stopDiscovery", "()I");
  if (!m) return -1;
  int32_t r = (int32_t)(*env)->CallStaticIntMethod(env, g_class, m);
  clear_pending(env);
  return r;
}

BTC_EXPORT int64_t btc_and_open(int64_t token, const char *address, int32_t channel,
                     const char *uuid) {
  JNIEnv *env = get_env();
  if (!env) return 0;
  jmethodID m = static_method(
      env, "openRfcomm", "(JLjava/lang/String;ILjava/lang/String;)J");
  if (!m) return 0;
  jstring jaddr = (*env)->NewStringUTF(env, address);
  jstring juuid = (*env)->NewStringUTF(env, uuid);
  if (!jaddr || !juuid) {
    // OOM: a NULL jstring would NPE at Kotlin's non-null parameter check.
    clear_pending(env);
    if (jaddr) (*env)->DeleteLocalRef(env, jaddr);
    if (juuid) (*env)->DeleteLocalRef(env, juuid);
    return 0;
  }
  jlong handle = (*env)->CallStaticLongMethod(env, g_class, m, (jlong)token,
                                              jaddr, (jint)channel, juuid);
  clear_pending(env);
  (*env)->DeleteLocalRef(env, jaddr);
  (*env)->DeleteLocalRef(env, juuid);
  return (int64_t)handle;
}

BTC_EXPORT int32_t btc_and_write(int64_t handle, const uint8_t *data, int32_t len) {
  JNIEnv *env = get_env();
  if (!env) return -1;
  jmethodID m = static_method(env, "write", "(J[B)I");
  if (!m) return -1;
  jbyteArray arr = (*env)->NewByteArray(env, len);
  if (!arr) {
    clear_pending(env);
    return -1;
  }
  (*env)->SetByteArrayRegion(env, arr, 0, len, (const jbyte *)data);
  jint rc = (*env)->CallStaticIntMethod(env, g_class, m, (jlong)handle, arr);
  clear_pending(env);
  (*env)->DeleteLocalRef(env, arr);
  return (int32_t)rc;
}

// OS-advertised max single-write payload (BluetoothSocket.
// getMaxTransmitPacketSize). <= 0 means unknown; the Dart side reports null.
BTC_EXPORT int32_t btc_and_max_tx(int64_t handle) {
  JNIEnv *env = get_env();
  if (!env) return -1;
  jmethodID m = static_method(env, "maxTxSize", "(J)I");
  if (!m) return -1;
  int32_t r =
      (int32_t)(*env)->CallStaticIntMethod(env, g_class, m, (jlong)handle);
  clear_pending(env);
  return r;
}

// Bytes submitted to the socket's write executor and not yet handed to the
// socket (exact; 0 for an unknown/closed handle).
BTC_EXPORT int64_t btc_and_pending_bytes(int64_t handle) {
  JNIEnv *env = get_env();
  if (!env) return 0;
  jmethodID m = static_method(env, "pendingBytes", "(J)J");
  if (!m) return 0;
  int64_t r =
      (int64_t)(*env)->CallStaticLongMethod(env, g_class, m, (jlong)handle);
  clear_pending(env);
  return r;
}

BTC_EXPORT int32_t btc_and_flush(int64_t handle) {
  JNIEnv *env = get_env();
  if (!env) return -1;
  jmethodID m = static_method(env, "flush", "(J)I");
  if (!m) return -1;
  int32_t r =
      (int32_t)(*env)->CallStaticIntMethod(env, g_class, m, (jlong)handle);
  clear_pending(env);
  return r;
}

BTC_EXPORT int32_t btc_and_close(int64_t handle) {
  JNIEnv *env = get_env();
  if (!env) return -1;
  jmethodID m = static_method(env, "close", "(J)I");
  if (!m) return -1;
  int32_t r = (int32_t)(*env)->CallStaticIntMethod(env, g_class, m, (jlong)handle);
  clear_pending(env);
  return r;
}

// Quiesces every Kotlin-side event source (discovery receiver, read loops,
// write executors) WITHOUT touching the registered callback pointers — the
// Dart layer calls this at construction, before registering fresh
// NativeCallable pointers, so nothing left over from a dead isolate (Flutter
// hot restart) can invoke a destroyed trampoline; also called at dispose.
BTC_EXPORT void btc_and_reset(void) {
  JNIEnv *env = get_env();
  if (!env) return;
  jmethodID m = static_method(env, "reset", "()I");
  if (!m) return;
  (*env)->CallStaticIntMethod(env, g_class, m);
  clear_pending(env);
}
