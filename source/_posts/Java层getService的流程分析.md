title: Java层调用ServiceManager
date: 2016-05-02  20:03
tag: [Android, Binder, ServiceManager]
---

# Java层获取Vibrator服务

1. `Vibrator systemService = (Vibrator) getSystemService(VIBRATOR_SERVICE);	// VIBRATOR_SERVICE="vibrator"`在Activity中调用时，实际调用的是Activity的`getSystemService`函数
2. Activity的`getSystemService`函数会调用到父类ContextThemeWrapper的`getSystemService`函数
3. ContextThemeWrapper的`getSystemService`函数最终调用的是ContextWrapper的`getBaseContext`函数得到的Context中的`getSystemService`函数
4. ContextWrapper的`getBaseContext`函数返回的Context是在其`attachBaseContext`函数内设置的，该函数在ContextThemeWrapper的`attachBaseContext`函数中调用，ContextThemeWrapper的`attachBaseContext`函数会在Activity的`attach`函数中被调用。
5. Activity的`attach`函数实际又会在ActivityThread的`performLaunchActivity`中被执行。终于找到在ContextWrapper的`getBaseContext`函数得到的Context真正面目：`Context appContext = createBaseContextForActivity(r, activity);`  <!--more-->
6. `createBaseContextForActivity`第一个参数类型为[ActivityClientRecord][5]（此类型对象是在`startActivity`调用时创建的），这个函数创建的context实际是由ContextImpl类`createActivityContext`函数new了一个ContextImpl对象；
7. ContextImpl类的`getSystemService`函数终于调用到了[SystemServiceRegistry][3]类的`getSystemService`函数了。
8. `getSystemService`函数通过名字key获取[SystemServiceRegistry][3]类的`SYSTEM_SERVICE_FETCHERS`（HashMap类型）成员的value，即获取[CachedServiceFetcher][23]类型对象，该对象将service缓存在[`ContextImpl`中][24]。
9. 通过`getSystemService`函数得到的是[注册Vibrator服务][25]时缓存在`ContextImpl`的`mServiceCache`的相应的服务，即获取到实现了[`Vibrator`接口][26]的[SystemVibrator类][2]对象。
10. [SystemVibrator类][2]对象的创建也就是通过ServiceManager获取vibrator服务的并赋值给其成员`IVibratorService mService`的过程，详细获取过程看下一节。





# 通过ServiceManager获取vibrator服务

* IServiceManager接口类：/frameworks/base/core/java/android/os/IServiceManager.java
  提供接口：getService、checkService、addService、listServices、setPermissionController

## ServiceManager管理类
位置：/frameworks/base/core/java/android/os/ServiceManager.java

###  根据service名获取对应服务

其静态函数`getService(name)`函数获取指定name的service的引用

```java
/**
 * Returns a reference to a service with the given name.
 * 
 * @param name the name of the service to get
 * @return a reference to the service, or <code>null</code> if the service doesn't exist
 */
public static IBinder getService(String name) {
    try {
        IBinder service = sCache.get(name);
        if (service != null) {
            return service;
        } else {
            return getIServiceManager().getService(name);
        }
    } catch (RemoteException e) {
        Log.e(TAG, "error in getService", e);
    }
    return null;
}
```
`getIServiceManager`用来获取IServiceManager类型的成员变量，如果为nul则先赋值。

```java
private static IServiceManager getIServiceManager() {
    if (sServiceManager != null) {
        return sServiceManager;
    }
    // Find the service manager
    sServiceManager = ServiceManagerNative.asInterface(BinderInternal.getContextObject());
    return sServiceManager;
}
```
#### 获取ServiceManager的Binder代理

其中BinderInternal.getContextObject()是一个native方法，获取系统全局的`context object`，即得到native层handle为0的BpBinder对象（就是ServiceManager在client端的Binder代理）

> * Java位置：/frameworks/base/core/java/com/android/internal/os/BinderInternal.java
```java
public static final native IBinder getContextObject();
```
> * native位置：/frameworks/base/core/jni/android_util_Binder.cpp
```cpp
static jobject android_os_BinderInternal_getContextObject(JNIEnv* env, jobject clazz)
{
    // 获取ServiceManager的BpBinder对象指针
    sp<IBinder> b = ProcessState::self()->getContextObject(NULL);
    return javaObjectForIBinder(env, b);	// 参见[如何将c/c++层获得到的BpBinder对象指针转为Java对象]
}
```
> [如何将c/c++层获得到的BpBinder对象指针转到Java层BinderProxy对象](#native_bpbinder_to_java)

`BinderInternal.getContextObject()`实际得到的是BinderProxy的对象，函数`ServiceManagerNative.asInterface(BinderInternal.getContextObject())`定义如下：
ServiceManagerNative类位置：[/frameworks/base/core/java/android/os/ServiceManagerNative.java][1]
```java
/**
 * Cast a Binder object into a service manager interface, generating
 * a proxy if needed.
 */
static public IServiceManager asInterface(IBinder obj)
{
    if (obj == null) {
        return null;
    }
    // obj为BinderProxy类型，其queryLocalInterface返回值为null
    IServiceManager in =
        (IServiceManager)obj.queryLocalInterface(descriptor);   // descriptor = "android.os.IServiceManager";
    if (in != null) {
        return in;
    }
    
    return new ServiceManagerProxy(obj);    // 以BinderProxy对象为参数创建一个ServiceManagerProxy对象
}
```
至此，`getIServiceManager()`函数终于得到了c/c++层的handle为0的ServiceManager的Binder引用
整个流程就是：Client的Java层想获取某个服务(`getService(name)`)，首先需要先获得ServiceManager的代理ServiceManagerProxy。
而ServiceManagerProxy是作为获取ServiceManager服务的Client的代理，该代理有个成员mRemote（类型实际为BinderProxy）指向了
c/c++层的handle为0的BpBinder对象。有了这个代理，Client就可以通过它向Binder驱动层发数据给ServiceManager进程了。

#### 获取指定name的service

经由`getIServiceManager()`获取到了ServiceManager的代理ServiceManagerProxy类。以[ServiceManager.getService("vibrator")][2]为例，调用[ServiceManagerProxy的`getService`函数][18]分析：

```java
// 传入的name为"vibrator"
public IBinder getService(String name) throws RemoteException {
        Parcel data = Parcel.obtain();
        Parcel reply = Parcel.obtain();
        data.writeInterfaceToken(IServiceManager.descriptor);
        data.writeString(name);
  		// 通过binder内核传需要获取的服务的名字给ServiceManager
  		// GET_SERVICE_TRANSACTION最后会传到ServiceManager的svcmgr_handler处理函数中
  		// 	进而调用到实际的处理函数逻辑
        mRemote.transact(GET_SERVICE_TRANSACTION, data, reply, 0);
  		// 获取到ServiceManager返回的对应name的服务的binder引用
        IBinder binder = reply.readStrongBinder();
        reply.recycle();
        data.recycle();
        return binder;
    }
```

其中`mRemote.transact`实际调用到[`transactNative`函数][6]，对应到native的函数是[`android_os_BinderProxy_transact`函数][7]：

```c++
static jboolean android_os_BinderProxy_transact(JNIEnv* env, jobject obj,
        jint code, jobject dataObj, jobject replyObj, jint flags) // throws RemoteException
{
  // 将java层的Parcel类型对象转成native层的Parcel对象
  Parcel* data = parcelForJavaObject(env, dataObj);
  Parcel* reply = parcelForJavaObject(env, replyObj);
  // gBinderProxyOffsets结构体中fieldId对应到了Java层BinderProxy类中成员
  // 即此处得到了ServiceManager的client端的代理binder（实际类型为BpBinder）
   IBinder* target = (IBinder*)
        env->GetLongField(obj, gBinderProxyOffsets.mObject);
  // 调用到BpBinder类中的transact函数
   status_t err = target->transact(code, *data, reply, flags);
}
```

调用到的[BpBinder的transact函数][8]：

```c++
status_t BpBinder::transact(
    uint32_t code, const Parcel& data, Parcel* reply, uint32_t flags)
{
   // mHandle为0 code为GET_SERVICE_TRANSACTION
   status_t status = IPCThreadState::self()->transact(
            mHandle, code, data, reply, flags);
}
```

调用到[IPCThreadState类中的transact函数][9]：

```c++
status_t IPCThreadState::transact(int32_t handle,
                                  uint32_t code, const Parcel& data,
                                  Parcel* reply, uint32_t flags)
{
   // 将需要传到ServiceManager进程的数据包裹为binder驱动可解析的数据格式
   // 此处包裹了的BC_TRANSACTION会在binder内核的binder_thread_write时解析
   err = writeTransactionData(BC_TRANSACTION, flags, handle, code, data, NULL);
   // 将包裹后获取服务的数据发到binder驱动层，并等待ServiceManager进程传回获取服务的返回值
   // 在waitForResponse内的talkWithDriver函数中，会调用ioctl，传入到内核的binder_ioctl函数
   //    中的cmd为BINDER_WRITE_READ
   err = waitForResponse(reply);
}
```

其中调用到的[`waitForResponse`函数][10]：

```c++
status_t IPCThreadState::waitForResponse(Parcel *reply, status_t *acquireResult)
{
   while (1) {
     	// talkWithDriver调用后会进入到内核中处理
        if ((err=talkWithDriver()) < NO_ERROR) break;
     	// 读出了在bidner内核设置的BR_TRANSACTION_COMPLETE
        cmd = (uint32_t)mIn.readInt32();
     	switch (cmd) {
            case BR_TRANSACTION_COMPLETE:
            	if (!reply && !acquireResult) goto finish;
            	break;
            ...
        }
   }
}
```

其中调用到的[`talkWithDriver`函数][11]：

```c++
status_t IPCThreadState::talkWithDriver(bool doReceive)
{
  // bwr用于用户空间和内核空间数据交换
  binder_write_read bwr;
  // 接着设置bwr ...
  // 进入到binder驱动的binder_ioctl，进入后首先需要将用户空间数据拷贝到binder内核中
  if (ioctl(mProcess->mDriverFD, BINDER_WRITE_READ, &bwr) >= 0)
      err = NO_ERROR;
}
```

进入到内核`binder_ioctl`函数后，首先会拷贝用户空间数据到内核空间（该内核空间在ServiceManager进程启动时做了内存映射），接着会进入`binder_thread_write`函数对用户空间传过来的数据（包裹着BC_TRANSACTION命令数据）做处理；处理完后会进入[`binder_thread_read`函数][12]，写入需要返回给用户空间请求的服务的Binder引用。

* `binder_thread_write`函数中主要工作：创建一个类型为`BINDER_WORK_TRANSACTION`事务（就是到ServiceManager进程调用getService获取指定服务的事务）添加到ServiceManager的todo列表中，并唤醒ServiceManager，处理刚刚创建的这个事务；创建一个类型为`BINDER_WORK_TRANSACTION_COMPLATE`事务添加到client调用`getService`所在线程的todo列表中；
* 进入到[`binder_thread_read`函数][12]，会对上面创建的类型为`BINDER_WORK_TRANSACTION_COMPLATE`的事务进行处理，会传回cmd为`BR_TRANSACTION_COMPLETE`到用户空间，这时事务处理完，释放事务所占用的内存；
* 回到[`waitForResponse`函数][10]内，读出内核中设置的`BR_TRANSACTION_COMPLETE`值，进入相应的case，因为需要有返回reply，所以继续在[`waitForResponse`函数][10]内，执行[`talkWithDriver`函数][11] ；
* 再次执行[`talkWithDriver`函数][11]进入内核，此时因用户空间没有数据传入，不会进入到`binder_thread_write`中，因需要返回值，进入到[`binder_thread_read`函数][12]中；
* 进入到[`binder_thread_read`函数][12]，如果此时ServiceManager已经处理完前面提交的事务，则此次就有事务处理了；如果ServiceManager未处理完上次的事务，此client线程会进入休眠状态，等待ServiceManager处理完事务唤醒；
* ServiceManager处理完getService的事务后，也会提交一个类型为`BINDER_WORK_TRANSACTION`的事务给client处理。

##### ServiceManager唤醒处理BINDER_WORK_TRANSACTION类型事务

ServiceManager工作线程也是在[`binder_thread_read`函数][12]中休眠，等待被唤醒处理新的事务。

上面的client在进入到`binder_thread_write`函数后提交了一个类型为`BINDER_WORK_TRANSACTION`事务，并唤醒了ServiceManager工作线程，ServiceManager继续执行[`binder_thread_read`函数][12]后面的代码：

```c++
case BINDER_WORK_TRANSACTION: {
  // 取出client提交的getService的事务
  t = container_of(w, struct binder_transaction, work);      
} break;

// 此处的target_node是在client创建事务（binder_transaction函数内）时设置，
//  其值为binder_context_mgr_node
if (t->buffer->target_node) {	
  cmd = BR_TRANSACTION;
}
//  1. 将用户空间传到binder内核中的数据再传到ServiceManager内存中
//		（内存映射，不同于用户->binder内核的数据拷贝）
//  2. 将事务从todo列表中移除，但将该事务赋值给ServiceManager线程的transaction_stack，
//		等待后面ServiceManager对该事务实际的处理
list_del(&t->work.entry);
if (cmd == BR_TRANSACTION && !(t->flags & TF_ONE_WAY)) {
	thread->transaction_stack = t;
}
```

ServiceManager执行完[`binder_thread_read`函数][12]后，回到其[`binder_loop`函数][13]中，继续后面的执行代码：

```c++
void binder_loop(struct binder_state *bs, binder_handler func)
{
   for (;;) {
   	 res = ioctl(bs->fd, BINDER_WRITE_READ, &bwr);
     // 解析binder_thread_read拷贝过来的数据（处理client的getService请求）
     res = binder_parse(bs, 0, (uintptr_t) readbuf, bwr.read_consumed, func);
   }
}
```

进入[`binder_parse`函数][14]解析传过来的client请求数据：

```c++
int binder_parse(struct binder_state *bs, struct binder_io *bio,
                 uintptr_t ptr, size_t size, binder_handler func)
{
  case BR_TRANSACTION: {
    struct binder_transaction_data *txn = (struct binder_transaction_data *) ptr;
    // 一些初始化操作
    bio_init(&reply, rdata, sizeof(rdata), 4);
    bio_init_from_txn(&msg, txn);
    // 调用实际的处理client的getService请求的函数，func函数指针指向的是svcmgr_handler函数
    res = func(bs, txn, &msg, &reply);
    // 传回getService得到结果给client
    binder_send_reply(bs, &reply, txn->data.ptr.buffer, res);
  }
}
```

[`svcmgr_handler`函数][15]处理逻辑：

```c++
int svcmgr_handler(struct binder_state *bs,
                   struct binder_transaction_data *txn,
                   struct binder_io *msg,
                   struct binder_io *reply)
{
   case SVC_MGR_GET_SERVICE:
   case SVC_MGR_CHECK_SERVICE:
  	// 获取对应name的service的handle（相应service启动时注册到ServiceManager中的）
  	// 	从svclist链表中找到对应的服务的handle
   	handle = do_find_service(bs, s, len, txn->sender_euid, txn->sender_pid);
  	// 写到reply中，用于后面binder_send_reply函数传回到client端
  	bio_put_ref(reply, handle);
}
```

[`binder_send_reply`函数][16]将ServiceManager取到的service的handle经过binder内核传回到client（唤醒睡眠中的client线程继续执行[`binder_thread_read`函数][12]）。

1. ServiceManager传回handle过程中，也会创建一个`BINDER_WORK_TRANSACTION`事务和一个`BINDER_WORK_TRANSACTION_COMPLETE`事务，前一个事务添加给client thread的todo列表中，后一个事务是ServiceManager自己处理完了此处`getService`请求后内核的一些收尾清理，然后ServiceManager进入loop，没有事务处理的情况下，继续进入休眠状态；
2. ServiceManager创建`BINDER_WORK_TRANSACTION`事务时，因在`binder_transaction`函数调用时reply为true，所以事务中的`target_node`为NULL；
3. 添加完相应的事务后，会唤醒client睡眠的线程，处理ServiceManager的函数`getService`返回;
4. client线程唤醒后，执行[`binder_thread_read`函数][12]将得到的handle传回用户空间，因上面创建`BINDER_WORK_TRANSACTION`事务的target为NULL，[此处][16]设置的cmd为`BR_REPLY`;

client执行完[`binder_thread_read`函数][12]后回到[`waitForResponse`函数][10]内：

```c++
status_t IPCThreadState::waitForResponse(Parcel *reply, status_t *acquireResult)
{
   while (1) {
   	if ((err=talkWithDriver()) < NO_ERROR) break;
   	// 读出的cmd为BR_REPLY
    cmd = (uint32_t)mIn.readInt32();
    case BR_REPLY: {
      // 读出binder内核传来的getService结果handle值存放到Parcel类的mObjects中
      reply->ipcSetDataReference(
        reinterpret_cast<const uint8_t*>(tr.data.ptr.buffer),
        tr.data_size,
        reinterpret_cast<const binder_size_t*>(tr.data.ptr.offsets),
        tr.offsets_size/sizeof(binder_size_t),
        freeBuffer, this);
    }
   }
}
```

此时，[Parcel类][19]对象就有了这个服务的handle了。我们回到[ServiceManagerProxy的`getService`函数][18]中：

```c++
// 传入的name为"vibrator"
public IBinder getService(String name) throws RemoteException {
  mRemote.transact(GET_SERVICE_TRANSACTION, data, reply, 0);
  // 终于获取到name对应的服务的binder引用
  IBinder binder = reply.readStrongBinder();
  reply.recycle();
  data.recycle();
  return binder;
}
```

从[`readStrongBinder`函数][20]中获取对应服务的binder引用实际是通过[` unflatten_binder`函数][21]得到：

```c++
status_t unflatten_binder(const sp<ProcessState>& proc,
    const Parcel& in, sp<IBinder>* out) {
    // ServiceManager返回的是handle
    case BINDER_TYPE_HANDLE:
                *out = proc->getStrongProxyForHandle(flat->handle);
                return finish_unflatten_binder(
                    static_cast<BpBinder*>(out->get()), *flat, in);
}
```

调用到ProcessState类的[`getStrongProxyForHandle`函数][22]，因为是首次，不存在该handle的BpBinder对象，所以会new一个`BpBinder(handler)`的对象，后面再次调用[`getStrongProxyForHandle`函数][22]时，则会直接从ProcessState类的`mHandleToObject`成员中找出来。即`ServiceManager.getService("vibrator")`得到了对应服务的一个BpBinder对象。

再回到[ServiceManager.getService("vibrator")][2]例子：

```c++
 public SystemVibrator() {
   mService = IVibratorService.Stub.asInterface(
     ServiceManager.getService("vibrator"));
 }
```

其中[IVibratorService][22]类是由aidl程序生成出来，即将BpBinder对象转成了与服务相关联的对象，只有就可以直接通过`mService`调用`vibrator`提供的hasVIbrator/vibrate/vibratePattern/cancelVibrate的函数功能了。



** <span id = "native_bpbinder_to_java">如何将c/c++层获得到的BpBinder对象指针转到Java层BinderProxy对象?</span>：**
```c++
// 其中val实际指向的类型为BpBinder
jobject javaObjectForIBinder(JNIEnv* env, const sp<IBinder>& val)
{
    if (val == NULL) return NULL;

    if (val->checkSubclass(&gBinderOffsets)) {  // val实际类型为BpBinder，未重写checkSubclass，此处返回false
        // One of our own!
        jobject object = static_cast<JavaBBinder*>(val.get())->object();
        LOGDEATH("objectForBinder %p: it's our own %p!\n", val.get(), object);
        return object;
    }

    // For the rest of the function we will hold this lock, to serialize
    // looking/creation of Java proxies for native Binder proxies.
    AutoMutex _l(mProxyLock);

    // Someone else's...  do we know about it?
    jobject object = (jobject)val->findObject(&gBinderProxyOffsets);
    if (object != NULL) {
        jobject res = jniGetReferent(env, object);
        if (res != NULL) {
            ALOGV("objectForBinder %p: found existing %p!\n", val.get(), res);
            return res;
        }
        LOGDEATH("Proxy object %p of IBinder %p no longer in working set!!!", object, val.get());
        android_atomic_dec(&gNumProxyRefs);
        val->detachObject(&gBinderProxyOffsets);
        env->DeleteGlobalRef(object);
    }

    // 创建BinderProxy类对象
    object = env->NewObject(gBinderProxyOffsets.mClass, gBinderProxyOffsets.mConstructor);
    if (object != NULL) {
        LOGDEATH("objectForBinder %p: created new proxy %p !\n", val.get(), object);
        // The proxy holds a reference to the native object.
        // BpBinder的对象地址赋值到java层的BinderProxy类的mObject成员（新SDK已经为long类型）
        env->SetIntField(object, gBinderProxyOffsets.mObject, (int)val.get());
        val->incStrong((void*)javaObjectForIBinder);

        // The native object needs to hold a weak reference back to the
        // proxy, so we can retrieve the same proxy if it is still active.
        // gBinderProxyOffsets.mSelf是指向BinderProxy this的WeakReference
        jobject refObject = env->NewGlobalRef(env->GetObjectField(object, gBinderProxyOffsets.mSelf));
        val->attachObject(&gBinderProxyOffsets, refObject,
                jnienv_to_javavm(env), proxy_cleanup);

        // Also remember the death recipients registered on this proxy
        sp<DeathRecipientList> drl = new DeathRecipientList;
        drl->incStrong((void*)javaObjectForIBinder);
        env->SetIntField(object, gBinderProxyOffsets.mOrgue, reinterpret_cast<jint>(drl.get()));

        // Note that a new object reference has been created.
        android_atomic_inc(&gNumProxyRefs);
        incRefsCreated(env);
    }

    return object;  返回java类型为BinderProxy的对象，其mObject成员指向的是BpBinder对象地址
}
```



# 如何通过Context获得相关服务的

从`ContextImpl`类中可以看出，每个Context都有缓存了多个系统服务的Binder代理：
```java
final Object[] mServiceCache = SystemServiceRegistry.createServiceCache();
```
`SystemServiceRegistry`类内的static域内缓存了多个系统服务的binder，注册的服务同时也会被缓存到`ContextImpl`的mServiceCache成员中。
`SystemServiceRegistry`类注册服务的代码中，就是调用形如`IBinder b = ServiceManager.getService(Context.ACCOUNT_SERVICE);`代码，来获取相关的服务的Binder代理。

调用了ContextImpl类的getSystemService获取对应服务
```java
// ContextImpl类
@Override
 public Object getSystemService(String name) {
     return SystemServiceRegistry.getSystemService(this, name);
 }
```
而其实际最终调用到的服务的binder代码段如下：
```java
// SystemServiceRegistry类
/**
 * Gets a system service from a given context.
 */
public static Object getSystemService(ContextImpl ctx, String name) {
    ServiceFetcher<?> fetcher = SYSTEM_SERVICE_FETCHERS.get(name);  // SYSTEM_SERVICE_FETCHERS是map数据，key为服务名，value为相应的服务binder
    return fetcher != null ? fetcher.getService(ctx) : null;    // 如果服务的binder还不存在，则创建，并缓存到ContextImpl类中的mServiceCache对象数组中
}
```


[1]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/os/ServiceManagerNative.java
[2]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/os/SystemVibrator.java#36
[3]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/app/SystemServiceRegistry.java
[4]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/app/ActivityThread.java
[5]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/app/ActivityThread.java#2216
[6]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/os/Binder.java#501
[7]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/jni/android_util_Binder.cpp#1083
[8]: http://androidxref.com/6.0.1_r10/xref/frameworks/native/libs/binder/BpBinder.cpp#159

[9]: http://androidxref.com/6.0.1_r10/xref/frameworks/native/libs/binder/IPCThreadState.cpp#548
[10]: http://androidxref.com/6.0.1_r10/xref/frameworks/native/libs/binder/IPCThreadState.cpp#712
[11]: http://androidxref.com/6.0.1_r10/xref/frameworks/native/libs/binder/IPCThreadState.cpp#talkWithDriver
[12]: http://lxr.free-electrons.com/source/drivers/android/binder.c#L2142
[13]: http://androidxref.com/6.0.1_r10/xref/frameworks/native/cmds/servicemanager/binder.c#390
[14]: http://androidxref.com/6.0.1_r10/xref/frameworks/native/cmds/servicemanager/binder.c#binder_parse
[15]: http://androidxref.com/6.0.1_r10/xref/frameworks/native/cmds/servicemanager/service_manager.c#svcmgr_handler
[16]: http://androidxref.com/6.0.1_r10/xref/frameworks/native/cmds/servicemanager/binder.c#170
[17]: http://lxr.free-electrons.com/source/drivers/android/binder.c#L2376
[18]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/os/ServiceManagerNative.java#118
[19]: http://androidxref.com/6.0.1_r10/xref/frameworks/native/libs/binder/Parcel.cpp#1573
[20]: http://androidxref.com/6.0.1_r10/xref/frameworks/native/libs/binder/Parcel.cpp#1334
[21]: http://androidxref.com/6.0.1_r10/xref/frameworks/native/libs/binder/Parcel.cpp#293
[22]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/os/IVibratorService.aidl
[23]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/app/SystemServiceRegistry.java#753
[24]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/app/ContextImpl.java#mServiceCache
[25]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/app/SystemServiceRegistry.java#460
[26]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/os/Vibrator.java