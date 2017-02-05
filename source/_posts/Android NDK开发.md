title:  Android NDK开发
date: 2016-08-03 20:46
tag: [Android, NDK, c++]
---
# 基本使用
## Data Types
主要有两种：`primitive types`和`Reference types`
### Primitive Types
基础类型的对应表：

| **Java Type** | **JNI Type** | **c++ Type**   | **Size** |
| ------------- | ------------ | -------------- | -------- |
| Boolean       | Jboolean     | unsigned char  | 8 bit    |
| Byte          | Jbyte        | char           | 8 bit    |
| Char          | Jchar        | unsigned short | 16 bit   |
| Short         | Jshort       | short          | 16 bit   |
| Int           | Jint         | int            | 32 bit   |
| Long          | Jlong        | long long      | 64 bit   |
| Float         | Jfloat       | float          | 32 bit   |
| Double        | Jdouble      | double         | 64 bit   |
<!--more-->

### Reference Types
| **Java Type**       | **Native Type** |
| ------------------- | --------------- |
| java.lang.Class     | jclass          |
| java.lang.Throwable | jthrowable      |
| java.lang.String    | jstring         |
| Other objects       | jobject         |
| java.lang.Object[]  | jobjectArray    |
| boolean[]           | jbooleanArray   |
| byte[]              | jbyteArray      |
| char[]              | jbyteArray      |
| short[]             | jshortArray     |
| int[]               | jintArray       |
| long[]              | jlongArray      |
| float[]             | jfloatArray     |
| double[]            | jdoubleArray    |

## 引用类型数据操作
### [String Operations][string_operations]
JNI支持Unicode和UTF-8编码的strings
#### 创建新的String
对于Unicode的string使用`NewString`，对于UTF-8的string使用`NewStringUTF`。
```c++
jstring jstr0 = (*env)->NewStringUTF(eng, "UTF-8编码字符");
jstring jstr1 = (*env)->NewString(eng, "Unicode编码字符");
```
#### java的string转为C string
对于Unicode的string使用`GetStringChars`，对于UTF-8的string使用`GetStringUTFChars`(注：当这两个Get函数得到的字符串不再使用时，需要调用相应的`ReleaseStringChars`和`ReleaseStringUTFChars`函数)
```c++
const jbyte* str;
str = (*env)->GetStringUTFChars(env, javaString, null);
// 当native不再使用str时，通知VM释放string资源
(*env)->ReleaseStringUTFChars(env, javaString, str);
```
### [Array Operations][array_operations]
#### 创建新的Array
不同的primitive type对应的创建函数形如`New<TYpe>Array`的函数，如`NewIntArray`。
```c++
jintArray jIntArr;
jIntArr = (*env)->NewIntArray(env, 10);
```
#### 存取Array的Elements
JNI提供了两种存取Java数组元素的方法。
1. Operating on Copy
   先调用`Get<Type>ArrayRegion`取出，然后操作刚刚取出放在native的数组中的数组，最后调用`Set<Type>ArrayRegion`将数据设回到java数组对象中。
```c++
jint nativeArray[10];
(*env)->GetIntArrayRegion(env, javaArray, 0, 10, nativeArray);
(*env)->SetIntArrayRegion(env, javaArray, 0, 10, nativeArray);
```
1. Operating on Direct Pointer
   调用`Get<Type>ArrayElements`函数返回Type对应的类型数据的内容，如果`isCopy`值变成了`JNI_TRUE`，则表示返回的数组是java数组的一份拷贝；当返回的数组是copy的，其内元素变化并不需要体现到原始java数组上，当调用`Release<Type>ArrayElements`后再将变化体现到原始java数组。
```c++
jint* nativeDirectArray;
jboolean isCopy;
nativeDirectArray = env->GetIntArrayElements(arr, &isCopy);
// 如果此时isCopy为JNI_TRUE，表示get函数返回的是一份copy数据
nativeDirectArray[0] = 100;
env->ReleaseIntArrayElements(arr, nativeDirectArray, 0);
// 这样java层传进来的int数组第一个元素值变成了100
```
`Release<Type>ArrayElements`函数的第三个mode参数可选值：
| mode       | actions                                  |
| ---------- | ---------------------------------------- |
| 0          | copy back the content and free the elems buffer |
| JNI_COMMIT | copy back the content but do not free the elems buffer |
| JNI_ABORT  | free the buffer without copying back the possible changes |

此参数只有在get的函数的`isCopy`值为`JNI_TRUE`时才有用，即返回的是copy array时起作用。

### [NIO Support][nio_support]
#### New Direct Byte Buffer
在native代码中直接分配内存，然后给java使用
```c++
// native自己管理内存的释放
unsigned char* buffer = (unsigned char*) malloc(1024);
jobject directBuffer;
directBuffer = (*env)->NewDirectByteBuffer(env, buffer, 1024);
```
#### Getting the Direct Byte Buffer
可以直接在Java中创建java.nio.ByteBuffer的一个对象，然后在native层调用`GetDirectBufferAddress`函数获取其内存地址：
```c++
unsigned char* buffer;
buffer = (unsigned char*) (*env)->GetDirectBufferAddress(env, directBuffer);
```

### 存取Fields
包括两种类型：[实例对象Fields][accessing_fields_of_objects]和[静态Fields][accessing_static_fields]
```java
public class JavaClass {
 /** Instance field */
 private String instanceField = "Instance Field";
 /** Static field */
 private static String staticField = "Static Field";
}
```
#### 获取Field ID
可以通过**class** object来获取java对象实例的field ID，**class** object通过`GetObjectClass`函数获取。
```c++
jclass clazz;
clazz = (*env)->GetObjectClass(env, javaInstance);
```
有两个函数可以从class中获取field ID。`GetFieldId`方法用于获取instance的fields
```c++
jfieldID instanceFieldId;
// java中javaInstance对应的class类中存在一个String someField的成员变量
instanceFieldId = (*env)->GetFieldID(env, clazz, "someField", "Ljava/lang/String;");
```
`GetStaticFieldID`用于获取静态fields
```c++
jfieldID staticFieldId;
// java中javaInstance对应的class中有一个静态String staticField的成员
staticFieldId = (*env)->GetStaticFieldID(env, clazz, "staticField", "Ljava/lang/String;");
```
获取instance Field的函数：`Get<Type>Field`
获取静态Field的函数：`GetStatic<Type>Field`
```c++
jstring staticField, instanceField;
instanceField = (*env)->GetObjectField(env, javaInstance, instanceFieldId);
staticField = (*env)->GetStaticObjectField(env, clazz, staticFieldId);
```
获取单个field的值需要调用多个JNI函数，从native代码回到Java中获取对应field值，会降低性能，一般推荐将需要用到的对象直接以参数形式传到native层。

### 调用Methods
同fields类似，java中也由两种类型的method：instance method和static method。JNI提供获取这两种类型method的函数。
#### 获取Method ID
使用`GetMethodID`函数获取instance method的method ID；使用`GetStaticMethodID`函数获取static method的method ID。
```c++
jmethodID instanceMethodId;
instanceMethodId = (*env)->GetMethodID(env, clazz,
 "instanceMethod", "()Ljava/lang/String;");
 
jmethodID staticMethodId;
staticMethodId = (*env)->GetStaticMethodID(env, clazz,
 "staticMethod", "()Ljava/lang/String;");
```
#### 调用Method
通过上面获取到的method ID来调用实际的函数方法，使用[`Call<Type>Method`函数][calling_instance_methods]调用instance methods；使用[`CallStatic<Type>Method`函数][calling_static_methods]调用static methods。
```c++
jstring instanceMethodResult;
instanceMethodResult = (*env)->CallObjectMethod(env, instance, instanceMethodId);
jstring staticMethodResult;
staticMethodResult = (*env)->CallStaticObjectMethod(env, clazz, staticMethodId);
```

### Field和Method的Descriptors
|     **Java Type**     |      **Signature**      |
| :-------------------: | :---------------------: |
|        Boolean        |            Z            |
|         Byte          |            B            |
|         Char          |            C            |
|         Short         |            S            |
|          Int          |            I            |
|         Long          |            L            |
|         Float         |            F            |
|        Double         |            D            |
| fully-qualified-class | Lfully-qualified-class; |
|        type[]         |          [type          |
|      method type      |   (arg-type)ret-type    |

## 异常处理(Exception Handling)
* native层的异常处理
```c++
jthrowable ex;
// throwingMethodId对应的java方法会抛出一个异常
(*env)->CallVoidMethod(env, instance, throwingMethodId);
ex = (*env)->ExceptionOccurred(env);
if (0 != ex) {
	(*env)->ExceptionClear(env);
	// 异常的处理逻辑
}
```
* native层的异常抛出
```c++
jclass clazz;
clazz = (*env)->FindClass(env, "java/lang/NullPointerException");
if (0 ! = clazz) {
	(*env)->ThrowNew(env, clazz, "Exception message.");
}
```
native层抛出异常不会终止native函数的执行，也不会控制转移到异常处理（exception handler）。

## 局部和全局引用
JNI支持3中引用类型：局部引用、全局引用和弱全局引用。
### 局部引用(Local References)
很多JNI函数返回的是local references，local references在native函数return时释放，当然也可以显示调用`DeleteLocalRef`函数进行释放。
```c++
jclass clazz;
// FindClass返回的就是一个local reference
clazz = (*env)->FindClass(env, "java/lang/String");
```
### 创建一个Global Reference
调用`NewGlobalRef`函数并以local reference来初始化Global reference
```c++
jclass localClazz, globalClazz;
localClazz = (*env)->FindClass(env, "java/lang/String");
// 由local reference初始化一个global reference
globalClazz = (*env)->NewGlobalRef(env, localClazz);
// 显式删除了local reference
(*env)->DeleteLocalRef(evn, localClazz);
```
### 删除一个Global Reference
当一个global reference不再使用时需要主动删除，使用`DeleteGlobalRef`函数
```c++
(*env)->DeleteGlobalRef(env, globalClazz);
```
### 弱全局引用
类似于global reference，不过native层的弱引用对象不会阻止垃圾回收（即垃圾回收时，此弱全局引用可能会被回收）
* 创建弱全局引用
```c++
jclass weakGlobalClazz;
weakGlobalClazz = (*env)->NewWeakGlobalRef(env, localClazz);
```
* 判断弱全局引用的有效性
```c++
if (JNI_FALSE == (*env)->IsSameObject(env, weakGlobalClazz, NULL)) {
 // 对象可以使用
} else {
 // 对象已经被回收，不可以使用了
}
```
### 删除弱全局引用
可以在任何时候调用`DeleteWeakGlobalRef`函数来释放弱全局引用
```c++
(*env)->DeleteWeakGlobalRef(env, weakGlobalClazz);
```

## 线程(Threading)
* Local references没法在多个线程之间贡献使用；Global references可以在多个线程之间共享使用；
* JNIEnv接口指针是在每个native方法调用时传入，它也是与调用方法所在线程相关的，不能cached并且不能在其他线程使用。
  在java层使用`synchronized`来控制不同线程同步问题
```java
synchronized(obj) {
	/* Synchronized thread-safe code block. */
}
```
在native层，使用JNI的 monitor方法`MonitorEnter`和`MonitorExit`：
```c++
if (JNI_OK == (*env)->MonitorEnter(env, ob)j) {
  /* Error handling. */
}
/* Synchronized thread-safe code block. */
if (JNI_OK == (*env)->MonitorExit(env, obj)) {
 /* Error handling. */
}
```
### Native Threads
native层使用native threads执行多线程任务时，java虚拟机是不知道这些native threads的，故他们不能直接与java组件直接进行communicate。Native threads被attached到虚拟机后就可以进行communicate了。
JNI提供的`AttachCurrentThread`函数允许native threads被attached到虚拟机，需要提供`JavaVM`类型的指针作为参数，所以需要提前将JavaVM接口指针缓存。
```c++
JavaVM* cachedJvm;
...
JNIEnv* env;
...
/* Attach the current thread to virtual machine. */
(*cachedJvm)->AttachCurrentThread(cachedJvm, &env, NULL);
/* Thread can communicate with the Java application
 using the JNIEnv interface. */
 /* Detach the current thread from virtual machine. */
(*cachedJvm)->DetachCurrentThread(cachedJvm);
```
调用`AttachCurrentThread`函数让application可以获得`JNIEnv`接口指针，它在当前的thread是有效的。已经attached了的native thread再attach也没有问题。当native thread执行完时，可以使用`DetachCurrentThread`函数将它从虚拟机上detached。

# 跟踪调试
## Logging
Android的logging框架logger是作为一个内核模块实现。
native层想使用log功能步骤：
1. 引入头文件`#include <android/log.h>`
2. `Android.mk`文件中配置log库，`LOCAL_LDLIBS`的设置必须在配置编译shared lib之前：
```mk
LOCAL_MODULE := custom_jni
...
LOCAL_LDLIBS += -llog
...
include $(BUILD_SHARED_LIBRARY)
```
### Logging函数
`android/log.h`头文件中声明的打印log的函数接口：
* `__android_log_write`： 输出一个简单字string的log信息，传入log优先级、log的tag和log信息
```c++
__android_log_write(ANDROID_LOG_WARN, "custom_jni", "simple warning log");
```
* `__android_log_print`：输出一个格式化的string信息，传入log优先级、log的tag、log信息的格式化字符以及格式化所需的参数
```c++
__android_log_print(ANDROID_LOG_ERROR, "custom_jni", "format string %d", param_value);
```
* `__android_log_vprint`：类似于`__android_log_print`，只是传入的参数是`va_list`
```c++
void log_verbose(const char* format, ...) {
 va_list args;
 va_start(args, format);
 __android_log_vprint(ANDROID_LOG_VERBOSE, "custom_jni", format, args);
 va_end(args);
}
```
* `__android_log_assert`：用于assertion错误，没有log等级设置。
```c++
if (0 != errno) {
 __android_log_assert("0 != errno", "custom_jni",
 "There is an error.");
}
```
### native层控制log的输出
java层很容易通过配置Proguard来达到release版本中取出log的目的，native层就没有这么方便的方法了。
#### console log的显示
stdout和stderr默认在Android中时不显示的。为了将这些log重定向到Android的log系统中，需要执行下面adb命令：
```sh
adb shell stop
adb shell setprop log.redirect-stdio true
adb shell start
```

## 调试
TODO


# Bionic API基础
## 执行shell命令
* 头文件
  `#include <stdlib.h>`
* 使用system函数接口
  `int result = system("mkdir /data/data/com.example.hellojni/temp");`
* 使用`popen`和`pclose`接口
  该函数用于打开父子进程间的双向管道
  `FILE *popen(const char* command, const char* type);`
  当子进程完成执行时关闭stream
  `int pclose(FILE* stream)`

## 系统配置
* 头文件
  `#include <sys/system_properties.h>`，其中`PROP_NAME_MAX `用于表示最长属性名，`PROP_VALUE_MAX`用于表示最长字符值。
* 由名字获取系统属性值
  `__system_property_get`函数通过名字查询系统属性
  `__system_property_find`函数可以用来获取直接指向系统属性的一个指针，再由`__system_property_read`函数通过上面的指针获取属性值。
```c++
const prop_info* property;
/* Gets the product model system property. */
property = __system_property_find("ro.product.model");
char name[PROP_NAME_MAX];
char value[PROP_VALUE_MAX];
/* Get the system property name and value. */
if (0 == __system_property_read(property, name, value)) { }
```

## 用户和群组
* 头文件
  `#include <unistd.h>`
* 获取App的User和Group ID
```c++
uid_t uid;
/* Get the application user ID. */
uid = getuid();

gid_t gid;
/* Get the application group ID. */
gid = getgid();

char* username;
/* Get the application user name. */
username = getlogin();
```

# Native Threads
## Posix Threads
* 头文件
  `#include <pthread.h>`
* Threads的创建
```c++
int pthread_create(pthread_t* thread,
   pthread_attr_t const* attr,
   void* (*start_routine)(void*),
   void* arg);
```
* Thread返回值
```c++
// 调用pthread_join会挂起调用线程的执行，知道新线程结束
int pthread_join(pthread_t thread, void** ret_val);
```

## Posix线程同步
两种同步机制：mutex和semaphore
### Mutex互斥锁
**初始化mutex**：
```c++
// 初始化方法1
int pthread_mutex_init(pthread_mutex_t* mutex,
       const pthread_mutexattr_t* attr);
// 初始化方法2
pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
```
**Locking mutex**：
```c++
// 如果mutex已经被锁，调用lock后线程会挂起，直到mutex被unlock
int pthread_mutex_lock(pthread_mutex_t* mutex);
```
**Unlocking mutex**：
```c++
int pthread_mutex_unlock(pthread_mutex_t* mutex);
```
### Semaphore信号量
需要添加`#include <semaphore.h>`头文件。
**初始化信号量**：
```c++
// sem表示要初始化的信号量  pshared共享标志  value初始化值
extern int sem_init(sem_t* sem, int pshared, unsigned int value);
```
**Locking Semaphore**：
```c++
// 如果sem的值大于0，则locking成功，并对sem值减1；
//    如果等于0，则调用线程会挂起，直到另一线程unlocking信号量并使其值增加
extern int sem_wait(sem_t* sem);
```
**Unlocking Semaphore**：
```c++
// unlock后信号量的值会相应+1，调度策略决定哪些因此信号量阻塞的线程中某个线程执行
extern int sem_post(sem_t* sem);
```
**Destroying Semaphores**：
```c++
// 如果销毁时，仍有其他线程被blocked可能出现未知的结果。
extern int sem_destroy(sem_t* sem);
```

# POSIX Socket 
* 主要用到的头文件
```c++
// JNI
#include <jni.h>
// NULL
#include <stdio.h>
// va_list, vsnprintf
#include <stdarg.h>
// errno
#include <errno.h>
// strerror_r, memset
#include <string.h>
// socket, bind, getsockname, listen, accept, recv, send, connect
#include <sys/types.h>
#include <sys/socket.h>
// sockaddr_un
#include <sys/un.h>
// htons, sockaddr_in
#include <netinet/in.h>
// inet_ntop
#include <arpa/inet.h>
// close, unlink
#include <unistd.h>
// offsetof
#include <stddef.h>
```






































[string_operations]: https://docs.oracle.com/javase/8/docs/technotes/guides/jni/spec/functions.html#string_operations
[array_operations]: https://docs.oracle.com/javase/8/docs/technotes/guides/jni/spec/functions.html#array_operations
[nio_support]: https://docs.oracle.com/javase/8/docs/technotes/guides/jni/spec/functions.html#nio_support
[accessing_fields_of_objects]: https://docs.oracle.com/javase/8/docs/technotes/guides/jni/spec/functions.html#accessing_fields_of_objects
[accessing_static_fields]: https://docs.oracle.com/javase/8/docs/technotes/guides/jni/spec/functions.html#accessing_static_fields
[calling_instance_methods]: https://docs.oracle.com/javase/8/docs/technotes/guides/jni/spec/functions.html#calling_instance_methods
[calling_static_methods]: https://docs.oracle.com/javase/8/docs/technotes/guides/jni/spec/functions.html#calling_static_methods


