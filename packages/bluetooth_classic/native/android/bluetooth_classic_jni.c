// Android C ABI shim for bluetooth_classic.
//
// Dart (dart:ffi) calls the btc_and_* functions here; this shim forwards them to
// the Kotlin BluetoothClassicAndroid via JNI, and the Kotlin side pushes events
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
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef void (*btc_found_cb)(int64_t token, const char *json);
typedef void (*btc_inquiry_done_cb)(int64_t token, int32_t aborted);
typedef void (*btc_data_cb)(int64_t token, const uint8_t *data, int32_t len);
typedef void (*btc_state_cb)(int64_t token, int32_t state);

static JavaVM *g_vm = NULL;
static jclass g_class = NULL; // global ref to BluetoothClassicAndroid

static btc_found_cb g_found = NULL;
static btc_inquiry_done_cb g_done = NULL;
static btc_data_cb g_data = NULL;
static btc_state_cb g_state = NULL;

static const char *kClassName = "lol/carson/bluetooth_classic/BluetoothClassicAndroid";

// --- JVM / env acquisition ---------------------------------------------------

jint JNI_OnLoad(JavaVM *vm, void *reserved) {
  g_vm = vm;
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

static JNIEnv *get_env(void) {
  if (ensure_vm() != 0) return NULL;
  JNIEnv *env = NULL;
  jint r = (*g_vm)->GetEnv(g_vm, (void **)&env, JNI_VERSION_1_6);
  if (r == JNI_EDETACHED) {
    if ((*g_vm)->AttachCurrentThread(g_vm, &env, NULL) != JNI_OK) return NULL;
  } else if (r != JNI_OK) {
    return NULL;
  }
  return env;
}

// --- callbacks invoked from Kotlin (RegisterNatives targets) -----------------

static void nOnFound(JNIEnv *env, jclass clazz, jlong token, jstring json) {
  if (!g_found || !json) return;
  const char *s = (*env)->GetStringUTFChars(env, json, NULL);
  if (!s) return;
  size_t len = strlen(s) + 1;
  char *copy = malloc(len);
  memcpy(copy, s, len);
  (*env)->ReleaseStringUTFChars(env, json, s);
  g_found((int64_t)token, copy);
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
  (*env)->GetByteArrayRegion(env, arr, 0, len, (jbyte *)copy);
  g_data((int64_t)token, copy, (int32_t)len);
}

static void nOnState(JNIEnv *env, jclass clazz, jlong token, jint state) {
  if (g_state) g_state((int64_t)token, (int32_t)state);
}

// --- helpers -----------------------------------------------------------------

static jmethodID static_method(JNIEnv *env, const char *name, const char *sig) {
  if (!g_class) return NULL;
  return (*env)->GetStaticMethodID(env, g_class, name, sig);
}

static char *jstring_to_cstr(JNIEnv *env, jstring s) {
  if (!s) return NULL;
  const char *c = (*env)->GetStringUTFChars(env, s, NULL);
  if (!c) return NULL;
  size_t len = strlen(c) + 1;
  char *out = malloc(len);
  memcpy(out, c, len);
  (*env)->ReleaseStringUTFChars(env, s, c);
  return out;
}

// --- C ABI -------------------------------------------------------------------

void btc_free(void *ptr) {
  if (ptr) free(ptr);
}

void btc_and_register(btc_found_cb found, btc_inquiry_done_cb done,
                      btc_data_cb data, btc_state_cb state) {
  g_found = found;
  g_done = done;
  g_data = data;
  g_state = state;
}

int32_t btc_and_init(void) {
  JNIEnv *env = get_env();
  if (!env) return 1; // unavailable
  if (!g_class) {
    jclass local = (*env)->FindClass(env, kClassName);
    if (!local) {
      (*env)->ExceptionClear(env);
      return 1;
    }
    g_class = (jclass)(*env)->NewGlobalRef(env, local);
    (*env)->DeleteLocalRef(env, local);

    static const JNINativeMethod methods[] = {
        {"nativeOnFound", "(JLjava/lang/String;)V", (void *)nOnFound},
        {"nativeOnInquiryDone", "(JI)V", (void *)nOnInquiryDone},
        {"nativeOnData", "(J[B)V", (void *)nOnData},
        {"nativeOnState", "(JI)V", (void *)nOnState},
    };
    if ((*env)->RegisterNatives(env, g_class, methods, 4) != JNI_OK) {
      (*env)->ExceptionClear(env);
      return 1;
    }
  }
  jmethodID m = static_method(env, "initialize", "()I");
  if (!m) return 1;
  return (int32_t)(*env)->CallStaticIntMethod(env, g_class, m);
}

int32_t btc_and_adapter_state(void) {
  JNIEnv *env = get_env();
  if (!env) return 1;
  jmethodID m = static_method(env, "adapterState", "()I");
  if (!m) return 1;
  return (int32_t)(*env)->CallStaticIntMethod(env, g_class, m);
}

char *btc_and_bonded_json(void) {
  JNIEnv *env = get_env();
  if (!env) return NULL;
  jmethodID m = static_method(env, "bondedJson", "()Ljava/lang/String;");
  if (!m) return NULL;
  jstring s = (jstring)(*env)->CallStaticObjectMethod(env, g_class, m);
  char *out = jstring_to_cstr(env, s);
  if (s) (*env)->DeleteLocalRef(env, s);
  return out;
}

int32_t btc_and_start_discovery(int64_t token) {
  JNIEnv *env = get_env();
  if (!env) return -1;
  jmethodID m = static_method(env, "startDiscovery", "(J)I");
  if (!m) return -1;
  return (int32_t)(*env)->CallStaticIntMethod(env, g_class, m, (jlong)token);
}

int32_t btc_and_stop_discovery(void) {
  JNIEnv *env = get_env();
  if (!env) return -1;
  jmethodID m = static_method(env, "stopDiscovery", "()I");
  if (!m) return -1;
  return (int32_t)(*env)->CallStaticIntMethod(env, g_class, m);
}

int64_t btc_and_open(int64_t token, const char *address, int32_t channel,
                     const char *uuid) {
  JNIEnv *env = get_env();
  if (!env) return 0;
  jmethodID m = static_method(
      env, "openRfcomm", "(JLjava/lang/String;ILjava/lang/String;)J");
  if (!m) return 0;
  jstring jaddr = (*env)->NewStringUTF(env, address);
  jstring juuid = (*env)->NewStringUTF(env, uuid);
  jlong handle = (*env)->CallStaticLongMethod(env, g_class, m, (jlong)token,
                                              jaddr, (jint)channel, juuid);
  (*env)->DeleteLocalRef(env, jaddr);
  (*env)->DeleteLocalRef(env, juuid);
  return (int64_t)handle;
}

int32_t btc_and_write(int64_t handle, const uint8_t *data, int32_t len) {
  JNIEnv *env = get_env();
  if (!env) return -1;
  jmethodID m = static_method(env, "write", "(J[B)I");
  if (!m) return -1;
  jbyteArray arr = (*env)->NewByteArray(env, len);
  (*env)->SetByteArrayRegion(env, arr, 0, len, (const jbyte *)data);
  jint rc = (*env)->CallStaticIntMethod(env, g_class, m, (jlong)handle, arr);
  (*env)->DeleteLocalRef(env, arr);
  return (int32_t)rc;
}

int32_t btc_and_close(int64_t handle) {
  JNIEnv *env = get_env();
  if (!env) return -1;
  jmethodID m = static_method(env, "close", "(J)I");
  if (!m) return -1;
  return (int32_t)(*env)->CallStaticIntMethod(env, g_class, m, (jlong)handle);
}
