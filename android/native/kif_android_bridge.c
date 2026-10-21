/*
 * KIF's small virtual-input queue and Ruby -> JNI transport. HTTP/TLS is implemented by Java, never by
 * the runtime's native HTTPLite extension. Payloads are UTF-8 byte arrays;
 * JNI modified-UTF-8 string APIs are deliberately not used for JSON.
 *
 * The forward declarations below are stable MRI entry points, checked against
 * the pinned libruby.so by scripts/android/build_bridge.ps1 before linking.
 */
#include <jni.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>

typedef uintptr_t VALUE;
/* MRI stores this callback and dispatches according to the explicit arity. */
typedef VALUE (*KifRubyMethod)(void);
extern VALUE rb_define_module(const char *name);
extern void rb_define_module_function(VALUE module, const char *name,
                                     KifRubyMethod function, int arity);
extern char *rb_string_value_cstr(VALUE *value);
extern VALUE rb_utf8_str_new(const char *bytes, long length);
extern VALUE rb_ary_new_from_args(long length, ...);
extern VALUE rb_ull2inum(unsigned long long number);
extern VALUE rb_protect(VALUE (*function)(VALUE), VALUE argument, int *state);
extern void rb_jump_tag(int state) __attribute__((noreturn));
extern void rb_raise(VALUE exception_class, const char *format, ...)
    __attribute__((noreturn, format(printf, 2, 3)));
extern VALUE rb_eRuntimeError;

#define KIF_EXPORT __attribute__((visibility("default")))
#define KIF_REQUEST_LIMIT ((size_t)64 * 1024)
#define KIF_RESPONSE_LIMIT ((jsize)12 * 1024 * 1024)

_Static_assert(sizeof(VALUE) == sizeof(void *), "MRI VALUE must hold a pointer");

static pthread_mutex_t bridge_mutex = PTHREAD_MUTEX_INITIALIZER;
static JavaVM *bridge_vm;
static jclass bridge_class; /* Owned global reference, protected by bridge_mutex. */
static jmethodID bridge_perform_http;
/* Independent from HTTP configuration: input never enters SDL or Java from Ruby. */
static pthread_mutex_t input_mutex = PTHREAD_MUTEX_INITIALIZER;
static uint32_t input_pressed;
static uint32_t input_triggered;
static uint32_t input_released;
static uint32_t text_input_requested;
/* Retained independently of key resets, including activity pause/focus changes. */
static uint32_t display_stretch;

static void throw_configuration_error(JNIEnv *env, const char *message) {
    if ((*env)->ExceptionCheck(env)) return;
    jclass exception = (*env)->FindClass(env, "java/lang/IllegalStateException");
    if (exception != NULL) {
        (void)(*env)->ThrowNew(env, exception, message);
        (*env)->DeleteLocalRef(env, exception);
    }
}

static int virtual_key_valid(jint code) {
    return code == 2 || code == 4 || code == 6 || code == 8 || (code >= 11 && code <= 18);
}

KIF_EXPORT JNIEXPORT void JNICALL
Java_org_kuray_kif_NetworkBridge_setVirtualKey(JNIEnv *env, jclass java_class,
                                             jint code, jboolean down) {
    (void)java_class;
    if (!virtual_key_valid(code)) {
        throw_configuration_error(env, "Unknown RGSS virtual button code");
        return;
    }
    if (pthread_mutex_lock(&input_mutex) != 0) {
        throw_configuration_error(env, "Cannot access Android virtual input");
        return;
    }
    const uint32_t bit = UINT32_C(1) << (unsigned)code;
    if (down != JNI_FALSE) {
        if ((input_pressed & bit) == 0) input_triggered |= bit;
        input_pressed |= bit;
    } else {
        if ((input_pressed & bit) != 0) input_released |= bit;
        input_pressed &= ~bit;
    }
    (void)pthread_mutex_unlock(&input_mutex);
}

KIF_EXPORT JNIEXPORT void JNICALL
Java_org_kuray_kif_NetworkBridge_requestTextInput(JNIEnv *env, jclass java_class) {
    (void)java_class;
    if (pthread_mutex_lock(&input_mutex) != 0) {
        throw_configuration_error(env, "Cannot request Android text input");
        return;
    }
    text_input_requested = 1;
    (void)pthread_mutex_unlock(&input_mutex);
}

KIF_EXPORT JNIEXPORT void JNICALL
Java_org_kuray_kif_NetworkBridge_clearVirtualKeys(JNIEnv *env, jclass java_class) {
    (void)java_class;
    if (pthread_mutex_lock(&input_mutex) != 0) {
        throw_configuration_error(env, "Cannot clear Android virtual input");
        return;
    }
    /* Pause/start resets discard stale edges as well as held buttons. */
    input_pressed = 0;
    input_triggered = 0;
    input_released = 0;
    text_input_requested = 0;
    (void)pthread_mutex_unlock(&input_mutex);
}

static VALUE text_input_request_poll(VALUE receiver) {
    (void)receiver;
    uint32_t requested;
    if (pthread_mutex_lock(&input_mutex) != 0)
        rb_raise(rb_eRuntimeError, "Cannot poll Android text input request");
    requested = text_input_requested;
    text_input_requested = 0;
    (void)pthread_mutex_unlock(&input_mutex);
    /* Keep MRI allocation outside the mutex, including this small integer. */
    return rb_ull2inum((unsigned long long)requested);
}

KIF_EXPORT JNIEXPORT void JNICALL
Java_org_kuray_kif_NetworkBridge_setDisplayStretch(JNIEnv *env, jclass java_class,
                                                 jboolean stretch) {
    (void)java_class;
    if (pthread_mutex_lock(&input_mutex) != 0) {
        throw_configuration_error(env, "Cannot set Android display mode");
        return;
    }
    display_stretch = stretch != JNI_FALSE ? 1U : 0U;
    (void)pthread_mutex_unlock(&input_mutex);
}

static VALUE display_mode_poll(VALUE receiver) {
    (void)receiver;
    uint32_t stretch;
    if (pthread_mutex_lock(&input_mutex) != 0)
        rb_raise(rb_eRuntimeError, "Cannot poll Android display mode");
    stretch = display_stretch;
    (void)pthread_mutex_unlock(&input_mutex);
    return rb_ull2inum((unsigned long long)stretch);
}

static VALUE input_poll(VALUE receiver) {
    (void)receiver;
    uint32_t pressed, triggered, released;
    if (pthread_mutex_lock(&input_mutex) != 0)
        rb_raise(rb_eRuntimeError, "Cannot poll Android virtual input");
    pressed = input_pressed;
    triggered = input_triggered;
    released = input_released;
    input_triggered = 0;
    input_released = 0;
    (void)pthread_mutex_unlock(&input_mutex);
    /* MRI allocation can raise: it must happen outside the input mutex. */
    return rb_ary_new_from_args(3L, rb_ull2inum((unsigned long long)pressed),
                               rb_ull2inum((unsigned long long)triggered),
                               rb_ull2inum((unsigned long long)released));
}

KIF_EXPORT JNIEXPORT void JNICALL
Java_org_kuray_kif_NetworkBridge_configure(JNIEnv *env, jclass java_class) {
    JavaVM *vm = NULL;
    if ((*env)->GetJavaVM(env, &vm) != JNI_OK || vm == NULL) {
        throw_configuration_error(env, "Cannot obtain the Android Java VM");
        return;
    }
    jmethodID method = (*env)->GetStaticMethodID(env, java_class,
                                               "performHttp", "([B)[B");
    if (method == NULL) {
        /* Preserve the Java exception, if any, for the Java configure caller. */
        throw_configuration_error(env, "NetworkBridge.performHttp(byte[]) is unavailable");
        return;
    }
    jclass new_class = (jclass)(*env)->NewGlobalRef(env, java_class);
    if (new_class == NULL) {
        throw_configuration_error(env, "Cannot retain the Android networking class");
        return;
    }
    if (pthread_mutex_lock(&bridge_mutex) != 0) {
        (*env)->DeleteGlobalRef(env, new_class);
        throw_configuration_error(env, "Cannot configure the Android networking bridge");
        return;
    }
    if (bridge_vm != NULL && bridge_vm != vm) {
        (void)pthread_mutex_unlock(&bridge_mutex);
        (*env)->DeleteGlobalRef(env, new_class);
        throw_configuration_error(env, "Android networking cannot change Java VMs");
        return;
    }
    jclass old_class = bridge_class;
    bridge_vm = vm;
    bridge_class = new_class;
    bridge_perform_http = method;
    if (old_class != NULL) (*env)->DeleteGlobalRef(env, old_class);
    (void)pthread_mutex_unlock(&bridge_mutex);
}

struct ResponseBytes {
    char *bytes;
    long length;
};

static VALUE make_ruby_response(VALUE opaque) {
    const struct ResponseBytes *response = (const struct ResponseBytes *)(uintptr_t)opaque;
    return rb_utf8_str_new(response->bytes, response->length);
}

static VALUE request_json(VALUE receiver, VALUE request) {
    (void)receiver;
    /* Coercion and embedded-NUL validation can raise; no JNI resources exist yet. */
    const char *request_bytes = rb_string_value_cstr(&request);
    size_t request_length = 0;
    while (request_length <= KIF_REQUEST_LIMIT && request_bytes[request_length] != '\0') {
        request_length++;
    }
    if (request_length > KIF_REQUEST_LIMIT) {
        rb_raise(rb_eRuntimeError, "Android network request exceeds 64 KiB");
    }

    JavaVM *vm = NULL;
    if (pthread_mutex_lock(&bridge_mutex) != 0) {
        rb_raise(rb_eRuntimeError, "Cannot access the Android networking bridge");
    }
    vm = bridge_vm;
    (void)pthread_mutex_unlock(&bridge_mutex);
    if (vm == NULL) rb_raise(rb_eRuntimeError, "Android networking has not been configured");

    JNIEnv *env = NULL;
    int attached_here = 0;
    jint environment_status = (*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6);
    if (environment_status == JNI_EDETACHED) {
        if ((*vm)->AttachCurrentThread(vm, &env, NULL) != JNI_OK || env == NULL) {
            rb_raise(rb_eRuntimeError, "Cannot attach the game thread to Android networking");
        }
        attached_here = 1;
    } else if (environment_status != JNI_OK || env == NULL) {
        rb_raise(rb_eRuntimeError, "Cannot obtain the Android networking environment");
    }

    const char *error = NULL;
    jclass local_class = NULL;
    jmethodID method = NULL;
    jbyteArray java_request = NULL;
    jbyteArray java_response = NULL;
    struct ResponseBytes response = {NULL, 0};

    /* Convert the global class to a local ref while protected from reconfigure. */
    if (pthread_mutex_lock(&bridge_mutex) != 0) {
        error = "Cannot access the Android networking class";
        goto cleanup;
    }
    if (bridge_vm == vm && bridge_class != NULL && bridge_perform_http != NULL) {
        local_class = (jclass)(*env)->NewLocalRef(env, bridge_class);
        method = bridge_perform_http;
    }
    (void)pthread_mutex_unlock(&bridge_mutex);
    if ((*env)->ExceptionCheck(env) || local_class == NULL || method == NULL) {
        error = "Android networking is unavailable";
        goto cleanup;
    }

    java_request = (*env)->NewByteArray(env, (jsize)request_length);
    if ((*env)->ExceptionCheck(env) || java_request == NULL) {
        error = "Cannot allocate the Android network request";
        goto cleanup;
    }
    if (request_length != 0) {
        (*env)->SetByteArrayRegion(env, java_request, 0, (jsize)request_length,
                                  (const jbyte *)request_bytes);
        if ((*env)->ExceptionCheck(env)) {
            error = "Cannot copy the Android network request";
            goto cleanup;
        }
    }

    /* This synchronous call retains Ruby's GVL. Java performs all networking. */
    java_response = (jbyteArray)(*env)->CallStaticObjectMethod(env, local_class,
                                                             method, java_request);
    if ((*env)->ExceptionCheck(env)) {
        error = "Android networking raised a Java exception";
        goto cleanup;
    }
    if (java_response == NULL) {
        error = "Android networking returned no response";
        goto cleanup;
    }
    jsize response_length = (*env)->GetArrayLength(env, java_response);
    if ((*env)->ExceptionCheck(env)) {
        error = "Cannot read the Android network response length";
        goto cleanup;
    }
    if (response_length > KIF_RESPONSE_LIMIT) {
        error = "Android network response exceeds 12 MiB";
        goto cleanup;
    }
    response.bytes = (char *)malloc(response_length != 0 ? (size_t)response_length : 1);
    if (response.bytes == NULL) {
        error = "Cannot allocate the Android network response";
        goto cleanup;
    }
    response.length = (long)response_length;
    if (response_length != 0) {
        (*env)->GetByteArrayRegion(env, java_response, 0, response_length,
                                  (jbyte *)response.bytes);
        if ((*env)->ExceptionCheck(env)) {
            error = "Cannot copy the Android network response";
            goto cleanup;
        }
    }

cleanup:
    /* Ruby raises use longjmp: every JNI cleanup must precede any Ruby raise. */
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    if (java_response != NULL) (*env)->DeleteLocalRef(env, java_response);
    if (java_request != NULL) (*env)->DeleteLocalRef(env, java_request);
    if (local_class != NULL) (*env)->DeleteLocalRef(env, local_class);
    if (attached_here && (*vm)->DetachCurrentThread(vm) != JNI_OK && error == NULL) {
        error = "Cannot detach the Android networking thread";
    }
    if (error != NULL) {
        free(response.bytes);
        rb_raise(rb_eRuntimeError, "%s", error);
    }

    /* Protect the Ruby allocation too, so OOM cannot leak the copied C buffer. */
    int state = 0;
    VALUE result = rb_protect(make_ruby_response, (VALUE)(uintptr_t)&response, &state);
    free(response.bytes);
    if (state != 0) rb_jump_tag(state);
    return result;
}

KIF_EXPORT void Init_libkif_android_bridge(void) {
    VALUE module = rb_define_module("KIFAndroidBridge");
    rb_define_module_function(module, "request", (KifRubyMethod)request_json, 1);
    rb_define_module_function(module, "input_poll", (KifRubyMethod)input_poll, 0);
    rb_define_module_function(module, "text_input_request_poll", (KifRubyMethod)text_input_request_poll, 0);
    rb_define_module_function(module, "display_mode_poll", (KifRubyMethod)display_mode_poll, 0);
}

KIF_EXPORT void Init_kif_android_bridge(void) {
    Init_libkif_android_bridge();
}
