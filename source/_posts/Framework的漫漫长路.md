title:  Framework的漫漫长路
date: 2016-06-01 17:37
tag: [Android, Framework]
---

# [ActivityThread][1]

关键类型：[ApplicationThread][2]、[ApplicationThreadNative][3]、[ContextImpl][4]、[H(继承于Handler)][6]

[ActivityThread][1]在[ContextImpl][4]类中以`mMainThread`成员形式存在，并在[ContextImpl构造函数][5]中进行初始化。

>  [ContextImpl构造函数][5]是私有成员，`ContextImpl`对象的的创建可以通过`createSystemContext`/`createAppContext`和`createActivityContext`这三个静态成员函数来创建。

<!--more-->

## [createSystemContext函数][10]分析
* ActivityThread中[getSystemContext函数][11]调用了[createSystemContext函数][10]，将ActivityThread的this传给了[createSystemContext函数][10]，而[getSystemContext函数][11]在[SystemServer][12]类中有调用；
* 在[SystemServer][12]类创建时，会初始化system  context，其初始化是在[createSystemContext函数][13]中调用ActivityThread中[getSystemContext函数][11]后完成；
* [SystemServer][12]对象的创建是在其`main`函数内完成，该`main`函数是[zygote的主入口点][14]，即系统启动时创建的；
* 上面完成system context的创建，实际传给[createSystemContext函数][10]的`ActivityThread`对象就是在`ActivityThread`的静态[systemMain函数][15] 中创建并返回的；


创建SystemContext的流程如下：

> 1. 调用`ActivityThread.systemMain()`创建一个`ActivityThread`对象。
> 2. `ActivityThread`对象创建过程中，调用了`attach`函数：**a）** `attach`函数内调用了`getSystemContext`，会利用`ContextImpl.createSystemContext(this)`创建`ContextImpl`对象赋值给`mSystemContext`成员 ；`ContextImpl的createSystemContext`函数内，会通过`new LoadedApk(mainThread)`创建LoadedApk对象，并赋值给`ContextImpl的mPackageInfo`成员。**b）**  `attach`内调用`ContextImpl.createAppContext`创建context对象，并制造一个`Application`对象（`makeApplication`函数内通过反射机制创建了app实例）

所以创建system context前，首先需要通过`ActivityThread的systemMain函数`创建一个`ActivityThread`类型的thread对象，创建出thread对象创建后，调用`ActivityThread的attach函数`，[attach函数][16]此处的实际传参为`true`，对应到的实际逻辑如下：

```java
// ====> system thread attach的实际操作逻辑
// Don't set application object here -- if the system crashes,
// we can't display an alert, we just want to die die die.
android.ddm.DdmHandleAppName.setAppName("system_process",
                                        UserHandle.myUserId());
try {
  mInstrumentation = new Instrumentation();
  // getSystemContext().mPackageInfo即为new LoadedApk(ActivityThread.systemMain())对象
  ContextImpl context = ContextImpl.createAppContext(
    this, getSystemContext().mPackageInfo);
  // 创建类型为android.app.Application的对象
  mInitialApplication = context.mPackageInfo.makeApplication(true, null);
  mInitialApplication.onCreate();
} catch (Exception e) {
  throw new RuntimeException(
    "Unable to instantiate Application():" + e.toString(), e);
}
```

综合上述，当调用`ActivityThread.systemMain()`函数后，就创建了`ActivityThread`对象以及SystemContext(`ContextImpl.createSystemContext`函数创建的ContextImpl对象)的创建。



## [createAppContext函数][8]分析

主要在ActivityThread内的`handleCreateBackupAgent`/`handleCreateService`/`handleBindApplication`和`attach`中调用。

`handleBindApplication`函数(同时会进行[Application的创建][37]和Application的onCreate的触发`mInstrumentation.callApplicationOnCreate(app)`)调用时机：

​	`ActivityThread的handleBindApplication` <- `H的handleMessage` <- `ApplicationThread的bindApplication` <- `ActivityManagerService的attachApplicationLocked` <- `ActivityManagerService的attachApplication`  <-  `ActivityThread的attach`。

<strong style="background:#ff0000; color:#ffffff">所以ActivityThread创建之后，进行attach时，会触发Application的创建以及onCreate的调用，基本流程如下：</strong >

> 1. 需要打开某个apk， zygote会fork新的进程，调起ActivityThread的main
> 2. main中创建*ActivityThread*对象，并调用其attach(false)
> 3. attach内调用*ActivityManagerProxy* 的attachApplication(传参mAppThread，最后会传给*ActivityManagerService*)，利用其成员mRemote调用transact，进行IPC通信
> 4. 通过binder驱动，IPC通信调用到server端*ActivityManagerService*服务进程的attachApplication函数
> 5. *ActivityManagerService*的attachApplication函数执行attachApplicationLocked函数
> 6. attachApplicationLocked函数内执行*IApplicationThread*接口的bindApplication函数
> 7. 执行*IApplicationThread*接口的bindApplication函数，实际调用到*ApplicationThreadProxy*的bindApplication，然后通过其内的mRemote调用transact，进行IPC通信（注：实现了*IApplicationThread*接口的ApplicationThread对象thread是由client端传给server端*ActivityManagerService*的binder引用，用于server端控制client端的桥梁）
> 8. 通过binder驱动，又从ActivityManagerService服务端调回client端，IPC通信经过onTransact对应case为BIND_APPLICATION_TRANSACTION，从而实际调用到client端*ApplicationThread* 的bindApplication
> 9. bindApplication函数内进行` sendMessage(H.BIND_APPLICATION, data)`的消息发送
> 10. 发送message后，进入handleMessage函数内BIND_APPLICATION消息的处理，即调用handleBindApplication
> 11. handleBindApplication函数内调用*Instrumentation*的callApplicationOnCreate函数完成Application的onCreate的触发。

找到源头，开始从头分析：

A) 起点是[ActivityThread的attach函数][16]（attach的调用时机是main函数内）:  

```java
if (!system) {
  ...
  android.ddm.DdmHandleAppName.setAppName("<pre-initialized>",
                                          UserHandle.myUserId());
  RuntimeInit.setApplicationObject(mAppThread.asBinder());
  // 获取ActivityManagerService服务管理，详见 B)
  final IActivityManager mgr = ActivityManagerNative.getDefault();
  try {
    // 详见 C)，其中参数mAppThread类型为ApplicationThread
    mgr.attachApplication(mAppThread);
  } catch (RemoteException ex) { }
  ...
}
```

B) 然后调用`ActivityManagerNative.getDefault()`获取ActivityManager服务：

```java
private static final Singleton<IActivityManager> gDefault = new Singleton<IActivityManager>() {
  protected IActivityManager create() {
    // 此处是获取"activity"管理服务，其注册在ActivityManagerService的setSystemProcess内
    IBinder b = ServiceManager.getService("activity");
    IActivityManager am = asInterface(b);
    return am;
  }
};
```

[activity管理服务的注册过程][18]，有注册可以看出，实际`ActivityManagerNative.getDefault()`得到的对象类型是`ActivityManagerService`。

C) 接着IActivityManager调用的`attachApplication`实际是[ActivityManagerService的attachApplication][19]函数：

```java
public final void attachApplication(IApplicationThread thread) {
  synchronized (this) {
    int callingPid = Binder.getCallingPid();
    final long origId = Binder.clearCallingIdentity();
    // 详见 D)，其中thread类型是ApplicationThread
    attachApplicationLocked(thread, callingPid);
    Binder.restoreCallingIdentity(origId);
  }
}
```

D) [attachApplicationLocked][20]中会调用ApplicationThread的函数[bindApplication][21]，并在bindApplication中通过` sendMessage(H.BIND_APPLICATION, data)`触发[H中的`handleMessage`进行`BIND_APPLICAION`][22]消息类型的消息处理：

```java
// attachApplicationLocked函数
 thread.bindApplication(processName, appInfo, providers, app.instrumentationClass,
                    profilerInfo, app.instrumentationArguments, app.instrumentationWatcher,
                    app.instrumentationUiAutomationConnection, testMode, enableOpenGlTrace,
                    isRestrictedBackupMode || !normalMode, app.persistent,
                    new Configuration(mConfiguration), app.compat,
                    getCommonServicesLocked(app.isolated),
                    mCoreSettingsObserver.getCoreSettingsLocked());

// ApplicationThread的bindApplication函数内处理逻辑
sendMessage(H.BIND_APPLICATION, data);

// handleMessage内case处理逻辑
case BIND_APPLICATION:
  Trace.traceBegin(Trace.TRACE_TAG_ACTIVITY_MANAGER, "bindApplication");
  AppBindData data = (AppBindData)msg.obj;
  handleBindApplication(data);	// 见E)
  Trace.traceEnd(Trace.TRACE_TAG_ACTIVITY_MANAGER);
  break;
```

E) [handleBindApplication函数][23]中最终调用`createAppContext`创建context。



上面牵扯到的`ApplicationThreadNative`/`IApplicationThread`，在`ActivityManager`服务相关的接口调用中起到重要作用，以`startActivity`为例：

client端调用的是[ActivityManagerProxy的startActivity][24]：

一般由`ActivityManagerNative.getDefault()`获取`IActivityManager`对象，故实际调用[ActivityManagerProxy的startActivity][24]  逻辑是`ActivityManagerNative.getDefault().startActivity()`，为何如此的原因如下：

```java
// http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/app/ActivityManagerNative.java#gDefault
public abstract class ActivityManagerNative extends ... {
  	...
    /**
     * Retrieve the system's default/global activity manager.
     */
    static public IActivityManager getDefault() {
        return gDefault.get();
    }
	private static final Singleton<IActivityManager> gDefault = new Singleton<IActivityManager>() {
      protected IActivityManager create() {
        IBinder b = ServiceManager.getService("activity");
        if (false) {
          Log.v("ActivityManager", "default service binder = " + b);
        }
        IActivityManager am = asInterface(b);	// ===> 调用ActivityManagerNative的asInterface
        if (false) {
          Log.v("ActivityManager", "default service = " + am);
        }
        return am;
      }
	};
  	...
	static public IActivityManager asInterface(IBinder obj) {
      	// 会根据实际情况，返回binder实体或引用
        if (obj == null) {
            return null;
        }
        IActivityManager in =
            (IActivityManager)obj.queryLocalInterface(descriptor);
        if (in != null) {
            return in;
        }
        return new ActivityManagerProxy(obj);
    }
}
```

client端调用了`startActivity`后，就会通过binder，将本次请求发送给`ActivityManagerService`的server进程，触发对应`startActivity`的处理逻辑，见server端调用分析。

server端调用[ActivityManagerService的startActivity][25]：

接着client端的`startActivity`示例，server是从[ActivityMangerNative的onTransact函数][26]接收到client提交的`startActivity`事务，进入对应的事务处理逻辑；`START_ACTIVITY_TRANSACTION`的case 处理逻辑是调用了`IActivityManager接口的startActivity函数`，该函数的具体实现是在[ActivityManagerService的startActivity][25]中。



### [createActivityContext函数][17]分析

主要在ActivityThread内的[createBaseContextForActivity][27]中调用。

`createBaseContextForActivity`函数调用时机：

​	`ActivityThread的createBaseContextForActivity` <- `ActivityThread的performLaunchActivity` <- `ActivityThread的startActivityNow/handleLaunchActivity` 

* `handleLaunchActivity` <- `LAUNCH_ACTIVITY(即activityStart)`/`RELAUNCH_ACTIVITY(即activityRestart)` 跟Activity生命周期相关


* `startActivityNow` <- `LocalActivityManager的moveToState` <- `ActivityGroup`中有应用

ActivityGroup被Fragment替代，此处分析[`LAUNCH_ACTIVITY`时执行的handleLaunchActivity][28]：

```java
 case LAUNCH_ACTIVITY: {
   Trace.traceBegin(Trace.TRACE_TAG_ACTIVITY_MANAGER, "activityStart");
   final ActivityClientRecord r = (ActivityClientRecord) msg.obj;

   r.packageInfo = getPackageInfoNoCheck(
     r.activityInfo.applicationInfo, r.compatInfo);
   handleLaunchActivity(r, null);
   Trace.traceEnd(Trace.TRACE_TAG_ACTIVITY_MANAGER);
 } break;
```

由上面代码可以看出，在activity start时才会真正创建`ContextImpl`的对象。

发送消息类型为`LAUNCH_ACTIVITY`是在[scheduleLaunchActivity函数][29]内执行，[scheduleLaunchActivity函数][29]本身是在`ApplicationThreadNative`的`onTransact`函数中[case SCHEDULE_LAUNCH_ACTIVITY_TRANSACTION ][30]时执行（因ApplicationThread属于应用本身，即它本身也作为了binder通讯中的server，而此时的client是system process）。

该`onTransact`的触发时机是调用[ApplicationThreadProxy的scheduleLaunchActivity][32]，而该函数是在系统服务`ActivityStackSupervisor`的[realStartActivityLocked][32]中调用；两处`startSpecificActivityLocked`/`attachApplicationLocked`调用了`realStartActivityLocked`

；

此处仅分析`attachApplicationLocked`：

​	在ActivityManagerService的系统服务的[attachApplicationLocked][33]函数中调用，而该函数由ActivityManagerService的[attachApplication][34]调用。ActivityManager服务的`attachApplication`函数又需要client端通过binder进行调用，实际client触发调用是[AcctivityThread中attach函数][35]，attach的参数为false时才会执行到`attachApplication`逻辑，而[ActivityThread的attach(false)][36]执行处在ActivityThread的main中。

由上述可以看出，在用于的ActivityThread实例运行起来时，就建立了应用与ActivityManagerService之间的关联，应用通过binder将ApplicationThread的handle传给了ActivityManagerService，这样ActivityMangerService就可以控制应用相关Activity的生命周期了。

**经上面的分析可以知道，ContextImpl的实例对象是经过ActivityThread内的handleMessage后完成初始化的，初始化过后，ContextImpl内`mMainThread`也就指向了该UI主线程（ActivityThread对象）。**

## [Handle][7]简析

























[1]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/app/ActivityThread.java#150
[2]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/app/ActivityThread.java#ApplicationThread
[3]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/app/ApplicationThreadNative.java#51
[4]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/app/ContextImpl.java#125
[5]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/app/ContextImpl.java#1796
[6]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/app/ActivityThread.java#1227
[7]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/os/Handler.java
[8]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/app/ContextImpl.java#1783
[9]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/app/LoadedApk.java#572
[10]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/app/ContextImpl.java#1774
[11]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/app/ActivityThread.java#1886
[12]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/services/java/com/android/server/SystemServer.java#167
[13]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/services/java/com/android/server/SystemServer.java#309
[14]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/com/android/internal/os/ZygoteInit.java#516
[15]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/app/ActivityThread.java#5318
[16]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/app/ActivityThread.java#5230
[17]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/app/ContextImpl.java#1789
[18]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/services/core/java/com/android/server/am/ActivityManagerService.java#2174
[19]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/services/core/java/com/android/server/am/ActivityManagerService.java#6246
[20]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/services/core/java/com/android/server/am/ActivityManagerService.java#attachApplicationLocked
[21]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/app/ActivityThread.java#767
[22]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/app/ActivityThread.java#1402
[23]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/app/ActivityThread.java#handleBindApplication
[24]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/app/ActivityManagerNative.java#2631
[25]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/services/core/java/com/android/server/am/ActivityManagerService.java#3849
[26]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/app/ActivityManagerNative.java#143
[27]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/app/ActivityThread.java#2432
[28]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/app/ActivityThread.java#1338
[29]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/app/ActivityThread.java#662
[30]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/app/ApplicationThreadNative.java#163
[31]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/app/ApplicationThreadNative.java#791
[32]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/services/core/java/com/android/server/am/ActivityStackSupervisor.java#1179
[33]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/services/core/java/com/android/server/am/ActivityManagerService.java#attachApplicationLocked
[34]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/services/core/java/com/android/server/am/ActivityManagerService.java#attachApplication
[35]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/app/ActivityThread.java#attach
[36]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/app/ActivityThread.java#main
[37]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/app/ActivityThread.java#4681
