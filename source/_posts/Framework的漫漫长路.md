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
> 10. 发送message后，进入handleMessage函数内BIND_APPLICATION消息的处理，即调用handleBindApplication（ActivityThread的成员函数）
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

**由[ActivityManagerService的attachApplication][19]函数反推[一窥APK的main activity的启动过程](#sight_of_main_activity_launch)**



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



###  <span id = " sight_of_main_activity_launch">一窥APK的main activity的启动过程</span>

【1】 由[ActivityManagerService的attachApplication][19]函数定义:

```java
@Override
public final void attachApplication(IApplicationThread thread) {
  synchronized (this) {
    // 获取调用AMS的client的进程pid
    int callingPid = Binder.getCallingPid();
    final long origId = Binder.clearCallingIdentity();
    // 主要由此函数反推（该函数会触发binder通信，
    //		让应用端调用ApplicationThread的attachApplication）
    attachApplicationLocked(thread, callingPid);
    Binder.restoreCallingIdentity(origId);
  }
}
```

【2】[attachApplicationLocked][38]函数部分定义：

```java
ProcessRecord app;
// pid为上面函数传入的callingPid MY_PID是AMS所在的pid
if (pid != MY_PID && pid >= 0) {
  synchronized (mPidsSelfLocked) {
    // 根据pid获取一个保存了进程全部信息的ProcessRecord对象
    app = mPidsSelfLocked.get(pid);
  }
} else {
  app = null;
}
```

根据`mPidsSelfLocked.get(pid)`函数获取`ProcessRecord`对象，如果`mPidsSelfLocked`不存在对应pid的`ProcessRecord`对象，则会调用`Process.killProcessQuiet(pid)`结束该pid的进程。从这部分逻辑可以看出，正常情况下，get是可以得到`ProcessRecord`的对象的，则只要找到什么时候向`mPidsSelfLocked`中添加`ProcessRecord`对象，就能一步一步反推到启动main activity的源头。

【3】在`ActivityManagerService`类中搜索*mPidsSelfLocked.put*，发现有两处调用：`setSystemProcess`/`startProcessLocked`，而`setSystemProcess`是系统启动时启动ASM时调用的，可以看出启动新APK时创建的`ProcessRecord`对象最终调用的是[`startProcessLocked`函数][39]，并设置到ASM的`mPidsSelfLocked`成员中。

【4】startProcessLocked函数内进行了新的process的创建，则只需分析startProcessLocked在哪些地方调用，就可慢慢回溯到最开始调用处：

​    【4.1】[ActivityManagerService](http://androidxref.com/6.0.1_r10/xref/frameworks/base/services/core/java/com/android/server/am/ActivityManagerService.java)内部的基础定义和调用：
```java
// =============================================>>>>> 定义
// 所在行：3247（6个参数）
// hostingType:log用的调用类型名(如activity/service)
// hostingNameStr:一般赋值process的name
private final void startProcessLocked(ProcessRecord app, String hostingType,
            String hostingNameStr, String abiOverride, String entryPoint, String[] entryPointArgs) {
   ...
   // 最终会触发ActivityThread的main函数，即启动apk的运行进程
   Process.ProcessStartResult startResult = Process.start(entryPoint,
                    app.processName, uid, uid, gids, debugFlags, mountExternal,
                    app.info.targetSdkVersion, app.info.seinfo, requiredAbi, instructionSet,
                    app.info.dataDir, entryPointArgs);
}

// 所在行：3241（3个参数） -> 最终调用到（6个参数)版本函数
private final void startProcessLocked(ProcessRecord app,
            String hostingType, String hostingNameStr) {
        startProcessLocked(app, hostingType, hostingNameStr, null /* abiOverride */,
                null /* entryPoint */, null /* entryPointArgs */);
}

// 所在行：3116（14个参数） -> 最终调用到（6个参数)版本函数
final ProcessRecord startProcessLocked(String processName, ApplicationInfo info, boolean knownToBeDead, int intentFlags, String hostingType, ComponentName hostingName, boolean allowWhileBooting, boolean isolated, int isolatedUid, boolean keepIfLarge, String abiOverride, String entryPoint, String[] entryPointArgs, Runnable crashHandler) {
  ...
  // 已经有对应processName的ProcessRecord则直接get
  app = getProcessRecordLocked(processName, info.uid, keepIfLarge);
  ...
  // 没有则创建
  app = newProcessRecordLocked(info, processName, isolated, isolatedUid);
  // system is ready则启动进程
  startProcessLocked(app, hostingType, hostingNameStr, abiOverride, entryPoint, entryPointArgs);
}

// 所在行：3106（9个参数） -> 最终调用到（14个参数)版本函数
final ProcessRecord startProcessLocked(String processName, ApplicationInfo info, boolean knownToBeDead, int intentFlags, String hostingType, ComponentName hostingName, boolean allowWhileBooting, boolean isolated, boolean keepIfLarge) {
        return startProcessLocked(processName, info, knownToBeDead, intentFlags, hostingType,
                hostingName, allowWhileBooting, isolated, 0 /* isolatedUid */, keepIfLarge,
                null /* ABI override */, null /* entryPoint */, null /* entryPointArgs */,
                null /* crashHandler */);
}


// =============================================>>>>> 调用
// 内部调用startProcessLocked（9个参数）的几处函数
// hostingType: "backup" 
public boolean bindBackupAgent(ApplicationInfo app, int backupMode) {...}
// hostingType: "content provider"
private final ContentProviderHolder getContentProviderImpl(IApplicationThread caller,
            String name, IBinder token, boolean stable, int userId) {...}
// WebViewFactory中的LocalServices.getService(ActivityManagerInternal.class)最终调用
int startIsolatedProcess(String entryPoint, String[] entryPointArgs, String processName, String abiOverride, int uid, Runnable crashHandler) {...}

// 内部调用startProcessLocked（3/6个参数）的几处函数
// hostingType: "added application" 
final ProcessRecord addAppLocked(ApplicationInfo info, boolean isolated, String abiOverride) {}
// hostingType: "on-hold" 
final void finishBooting() {}
// hostingType: "link fail" / "bind fail"
 private final boolean attachApplicationLocked(IApplicationThread thread, int pid) {}
// hostingType: "restart"
private final boolean cleanUpApplicationRecordLocked(ProcessRecord app, boolean restarting, boolean allowRestart, int index) {}
```

​    【4.2】其它三处调用`startProcessLocked`（9个参数）：

```java
// ActiveServices类
private final String bringUpServiceLocked(ServiceRecord r, int intentFlags, boolean execInFg, boolean whileRestarting) {
  // hostingType: "service"
  mAm.startProcessLocked(procName, r.appInfo, true, 
                         intentFlags, "service", r.name, 
                         false, isolated, false)
}

// BroadcastQueue类
final void processNextBroadcast(boolean fromMsg) {
  ...
  // hostingType: "broadcast"
  mService.startProcessLocked(targetProcess,
                    info.activityInfo.applicationInfo, true,
                    r.intent.getFlags() | Intent.FLAG_FROM_BACKGROUND,
                    "broadcast", r.curComponent,
                    (r.intent.getFlags()&Intent.FLAG_RECEIVER_BOOT_UPGRADE) != 0, false, false)
}

// ActivityStackSupervisor类
void startSpecificActivityLocked(ActivityRecord r, boolean andResume, boolean checkConfig) {
  // hostingType: "activity"
  mService.startProcessLocked(r.processName, r.info.applicationInfo, true, 
                              0, "activity", r.intent.getComponent(),
                              false, false, true);
} 
```

【5】根据上面的各调用函数中hostingType，推断启动apk的main activity应该是调用了ActivityStackSupervisor的[startSpecificActivityLocked函数][40]， 函数定义：

```java
void startSpecificActivityLocked(ActivityRecord r,
                                 boolean andResume, boolean checkConfig) {
  // Is this activity's application already running?
  ProcessRecord app = mService.getProcessRecordLocked(r.processName,
                                                      r.info.applicationInfo.uid, true);
  r.task.stack.setLaunchTime(r);
  // 如果已经存在了ProcessRecord信息
  if (app != null && app.thread != null) {
    try {
      if ((r.info.flags&ActivityInfo.FLAG_MULTIPROCESS) == 0
          || !"android".equals(r.info.packageName)) {
        // Don't add this if it is a platform component that is marked
        // to run in multiple processes, because this is actually
        // part of the framework so doesn't make sense to track as a
        // separate apk in the process.
        app.addPackage(r.info.packageName, r.info.applicationInfo.versionCode,
                       mService.mProcessStats);
      }
      realStartActivityLocked(r, app, andResume, checkConfig);
      return;
    } catch (RemoteException e) {
      Slog.w(TAG, "Exception when starting activity "
             + r.intent.getComponent().flattenToShortString(), e);
    }
    // If a dead object exception was thrown -- fall through to
    // restart the application.
  }
  // 第一次启动新apk的main activity，需要创建ProcessRecord对象并启动process
  mService.startProcessLocked(r.processName, r.info.applicationInfo, true, 0,
                              "activity", r.intent.getComponent(), false, false, true);
}
```

【6】在[ActivityStack][41]类中三处调用startSpecificActivityLocked函数：

```java
// 函数内调用1次startSpecificActivityLocked
final void ensureActivitiesVisibleLocked(ActivityRecord starting, int configChanges) {
  mStackSupervisor.startSpecificActivityLocked(r, noStackActivityResumed, false);
}

// 函数内调用2次startSpecificActivityLocked
private boolean resumeTopActivityInnerLocked(ActivityRecord prev, Bundle options) {
  // Find the first activity that is not finishing.
  final ActivityRecord next = topRunningActivityLocked(null);
  if (next.app != null && next.app.thread != null)  {
    ...
    catch (Exception e) {
      // Resume failed, Restarting because process died
      mStackSupervisor.startSpecificActivityLocked(next, true, false);
    }
  } else {
    // resumeTopActivityLocked: Restarting 
    mStackSupervisor.startSpecificActivityLocked(next, true, true);
  }
}
```

由resumeTopActivityInnerLocked内的`topRunningActivityLocked`函数可推测获取栈顶的activity在第一次启动时会为null，应该会进入第二个startSpecificActivityLocked的调用，则继续跟踪[resumeTopActivityInnerLocked][42]函数的调用。

【7】resumeTopActivityInnerLocked函数调用处是ActivityStack的[resumeTopActivityLocked][43]函数，继续查找resumeTopActivityLocked的调用，[发现很多地方有调用](http://androidxref.com/6.0.1_r10/s?refs=resumeTopActivityLocked&project=frameworks)，感觉继续逆向查找有些费事。我们知道，打开桌面上的apk，其实也是通过调用`startActivity`函数调起的，所以此处逆向查找遇到难题，则再从源头分析，对接到此处；

【8】**正向推理：**Activity的[startActivity][52] -> Activity的[startActivityForResult][53]  -> Instrumentation的[execStartActivity][54] -> ActivityManagerNative内[ActivityManagerProxy的startActivity][55] -> 触发binder发送类型START_ACTIVITY_TRANSACTION的事务  -> [AMS收到事务请求][56]触发其[startActivity][57]  ->  AMS的[startActivityAsUser][58] -> ActivityStackSupervisor的[startActivityMayWait][59] -> ActivityStackSupervisor的[startActivityLocked][44](doResume参数传了true) ->  ActivityStackSupervisor的[startActivityUncheckedLocked][45] -> ActivityStack的[startActivityLocked][46] ->  因doResume为true调用ActivityStackSupervisor的[resumeTopActivitiesLocked][47] ->  ActivityStack的[resumeTopActivityLocked][48]；到此，终于和【7】中逆向查找得到的ActivityStack[resumeTopActivityLocked][43]函数对上了。

从上面的简单流程推断看出，当启动一个新的apk时，随着一级一级的函数调用，会在ActivityStackSupervisor的[startSpecificActivityLocked函数][40]中调用到AMS的[9个参数的startProcessLocked][61]，并经过[14个参数的startProcessLocked][62]函数（在该函数内如果不存在ProcessRecord会创建一个）转到调用[6个参数的startProcessLocked][60]的函数中，通过`Process.start`函数用zygote启动新的process。

回到开始，为了知道AMS的[attachApplicationLocked][38]函数中获取ProcessRecord对象是什么时候设置的，一路逆向查找，在碰到比较复杂的逆向线索后，再从期望的逆向查找结果开始分析，最终两边的分析可以连上，说明了ProcessRecord的对象在启动新的apk的过程是个很重要的线索。

[详细的启动apk流程分析](http://wangzs.github.io/2016/06/18/Framework之APK启动分析)




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
[38]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/services/core/java/com/android/server/am/ActivityManagerService.java#attachApplicationLocked
[39]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/services/core/java/com/android/server/am/ActivityManagerService.java#3247
[40]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/services/core/java/com/android/server/am/ActivityStackSupervisor.java#startSpecificActivityLocked
[41]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/services/core/java/com/android/server/am/ActivityStack.java
[42]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/services/core/java/com/android/server/am/ActivityStack.java#resumeTopActivityInnerLocked
[43]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/services/core/java/com/android/server/am/ActivityStack.java#resumeTopActivityLocked
[44]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/services/core/java/com/android/server/am/ActivityStackSupervisor.java#startActivityLocked

[45]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/services/core/java/com/android/server/am/ActivityStackSupervisor.java#startActivityUncheckedLocked
[46]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/services/core/java/com/android/server/am/ActivityStack.java#startActivityLocked
[47]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/services/core/java/com/android/server/am/ActivityStackSupervisor.java#2727
[48]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/services/core/java/com/android/server/am/ActivityStack.java#1540
[49]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/services/core/java/com/android/server/am/ActivityStack.java#resumeTopActivityInnerLocked
[50]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/services/core/java/com/android/server/am/ActivityStackSupervisor.java#startSpecificActivityLocked
[51]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/services/core/java/com/android/server/am/ActivityManagerService.java#startProcessLocked
[52]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/app/Activity.java#startActivity
[53]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/app/Activity.java#startActivityForResult
[54]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/app/Instrumentation.java#1481
[55]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/app/ActivityManagerNative.java#2631
[56]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/core/java/android/app/ActivityManagerNative.java#146
[57]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/services/core/java/com/android/server/am/ActivityManagerService.java#startActivity
[58]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/services/core/java/com/android/server/am/ActivityManagerService.java#startActivityAsUser
[59]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/services/core/java/com/android/server/am/ActivityStackSupervisor.java#startActivityMayWait
[60]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/services/core/java/com/android/server/am/ActivityManagerService.java#3247
[61]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/services/core/java/com/android/server/am/ActivityManagerService.java#3106
[62]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/services/core/java/com/android/server/am/ActivityManagerService.java#3116