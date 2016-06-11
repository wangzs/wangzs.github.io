title: ServiceManager管理注册服务
date: 2016-05-01  10:06
tag: [Android, Binder, ServiceManager]
---

# Framework下与binder相关的native层代码
* 头文件：[/frameworks/native/include/binder/][1]
* 具体实现：[`/frameworks/native/libs/binder/`][2]

**一些命名的规则：**
**Ixxx**: 如IBinder/IServiceManager等，表示了Binder接口、ServiceM接口； I的前缀就是Interface(接口)的意思
**Bpxxx**: 如BpBinder/BpServiceManager等，表示了Binder的代理 ServiceManager的代理； Bp的前缀就是Binder Proxy（client端使用的代理）
**Bnxxx**: 如BnServiceManager/BnMediaPlayerService等，表示了ServiceManager服务的binder native； Bn的前缀就是Binder Native（Server端与Binder Proxy间接打交道的东西）
**BC_XXX**: BC的前缀表示Binder command（binder driver command protocol ）
**BR_XXX**: BR的前缀表示Binder return（binder driver return protocol）

<!-- more -->

# 获取ServiceManager的Binder引用
在文件[`/frameworks/native/libs/binder/IServiceManager.cpp`][6]中，android命名空间下有
`sp<IServiceManager> defaultServiceManager()`函数让任何Client获取ServiceManager的Binder代理（BpServiceManager对象）：
```c++
// IServiceManager的几个接口
//    1.根据名字获取服务的IBinder（若不存在会阻塞一会）： sp<IBinder> getService(const String16& name);
//    2.检查是否存在name的服务（非阻塞）：sp<IBinder> checkService( const String16& name);
//    3.注册服务：status_t addService(name, server, allowIsolated=false);
//    4.返回当前的server列表：Vector<String16> listServices();
sp<IServiceManager> defaultServiceManager()
{
    // 单例模式，如果gDefaultServiceManager不为空，直接返回
    if (gDefaultServiceManager != NULL) return gDefaultServiceManager;  // ====> gDefaultServiceManager的定义见[gDefaultServiceManager定义]
    {
        AutoMutex _l(gDefaultServiceManagerLock);
        while (gDefaultServiceManager == NULL) {
            // ProcessState::self()->getContextObject(NULL)得到handle=0的sp<IBinder>对象
            //  interface_cast的模板定义见[interface_cast模板定义]
            //  其实际就是调用IServiceManager::asInterface(obj)接口（此接口定义与实现在两个宏定义中）
            //  此处asInterfce的参数为BpBinder（即ServerManager的Binder引用,其handle为0）类型
            //  最终在asInterface接口中创建一个BpServiceManager(BpBinder)对象[详见BpServiceManager构造函数定义]
            gDefaultServiceManager = interface_cast<IServiceManager>(
                ProcessState::self()->getContextObject(NULL));
            if (gDefaultServiceManager == NULL)
                sleep(1);
        }
    }
    // gDefaultServiceManager即是一个实际类型为BpServiceManager，内部拥有了一个handle为0的远程Binder引用
    return gDefaultServiceManager;
}
```
## `ProcessState`类中如何获得ServiceManager的Binder引用
```c++
// 位置：/frameworks/native/libs/binder/ProcessState.cpp
sp<ProcessState> ProcessState::self()
{
    Mutex::Autolock _l(gProcessMutex);
    if (gProcess != NULL) {
        return gProcess;
    }
    gProcess = new ProcessState;    // ====> gProcess的定义见[gProcess定义]
    return gProcess;
}

// 此处函数参数无用，直接获取handle为0的IBinder
sp<IBinder> ProcessState::getContextObject(const sp<IBinder>& /*caller*/)
{
    return getStrongProxyForHandle(0);
}

// 经由ProcessState::self()->getContextObject(NULL)调用后，传给函数参数handle值为0
sp<IBinder> ProcessState::getStrongProxyForHandle(int32_t handle)
{
    sp<IBinder> result;
    AutoMutex _l(mLock);
    // 查找handle索引对应的handle_entry类型对象，没有则会先创建（初始成员都为null），需要在外部设置
    handle_entry* e = lookupHandleLocked(handle);     // ====> 定义见[lookupHandleLocked函数定义]
    if (e != NULL) {
        // 第一次handle所以不到，e是新建的，其成员binder还是null
        IBinder* b = e->binder;
        if (b == NULL || !e->refs->attemptIncWeak(this)) {
            if (handle == 0) {
                // 只有在获取ServiceManager时，handle值是0
                Parcel data;
                status_t status = IPCThreadState::self()->transact(
                        0, IBinder::PING_TRANSACTION, data, NULL, 0);
                if (status == DEAD_OBJECT)
                   return NULL;
            }
            b = new BpBinder(handle);
            e->binder = b;  // 为第一次创建handle=0的handle_entry类型对象赋值BpBinder对象
            if (b) e->refs = b->getWeakRefs();
            result = b;
        } else {
            // This little bit of nastyness is to allow us to add a primary
            // reference to the remote proxy when this team doesn't have one
            // but another team is sending the handle to us.
            result.force_set(b);
            e->refs->decWeak(this);
        }
    }
    return result;
}
```

* [gDefaultServiceManager定义][7]

* [interface_cast模板定义](#interface_cast_def)

* [IServiceManager::asInterface函数定义](#asInterface_server_mng_def)

* [BpServiceManager构造函数定义](#BpServiceManager_detail_def)

* [ProcessState类的详细分析](#ProcessState_detail_def)

* [gProcess定义][5]
> 其定义在`/frameworks/native/libs/binder/Static.cpp`中为: `sp<ProcessState> gProcess`

* [lookupHandleLocked函数定义](#lookupHandleLocked_func_def)

* [handle_entry类型定义](#handle_entry_def)

* [BpBinder类定义][8]（[类的实现][9]）

* [IBinder接口][10]（[非纯虚函数定义][11]）



# 添加Server到ServiceManager中的流程
此处以媒体服务的server注册到ServiceManager中为例：
位置：[/frameworks/av/media/mediaserver/main_mediaserver.cpp][12]
```c++
int main(int argc __unused, char** argv)
{
  if (doLog && (childPid = fork()) != 0) {
    // 此部分fork了一个子进程，记录media服务相关log记录
  } else {
    // ICU 字符编码相关的配置
    InitializeIcuOrDie();
    // 当前进程ProcessState对象：管理了通过handle查询Binder代理；打开的binder驱动的fd
    sp<ProcessState> proc(ProcessState::self());
    // 获取ServiceManager的BpServiceManager对象
    sp<IServiceManager> sm = defaultServiceManager();
    ALOGI("ServiceManager: %p", sm.get());
    AudioFlinger::instantiate();          // 下面的所有instantiate()具体实现都很类似
    MediaPlayerService::instantiate();
    ResourceManagerService::instantiate();
    CameraService::instantiate();
    AudioPolicyService::instantiate();
    SoundTriggerHwService::instantiate();
    RadioService::instantiate();        // ====> 看2.1 [RadioService如何注册]
    registerExtensions();       // 此函数是个空函数
    // ====> 最后会创建一个新线程用于处理client发送的服务请求
    ProcessState::self()->startThreadPool();    // ====> 见[ProcessState类的详细分析]
    // =====> 此调用在进程中，即也将主线程设置用于处理client经过binder驱动发送过来的服务请求
    IPCThreadState::self()->joinThreadPool();   // ====> 见[IPCThreadState的joinThreadPool详细分析]
  }
}
```
* [ProcessState类的详细分析](#ProcessState_detail_def)
* [IPCThreadState的joinThreadPool详细分析](IPCThreadState_joinThreadPool_def)



## addService的大致流程
* [RadioService进程空间] 在RadioService进程中，调用`defaultServiceManager()`获取到ServiceManager的客户端代理：
> 1. ServiceManager在客户端这边的代理类型是BpServiceManager，每个进程中都是有一个唯一的实例，即`gDefaultServiceManager`
  1. 本身RadioService属于Server，但是对于ServiceManager进程（Server）来说，RadioService又是属于Client，需要将RadioService注册到ServiceManager中管理

* [RadioService进程空间] addService的参数中会创建`new RadioService()`对象
> 1. RadioService对象创建时，会打开binder设备，内核空间和进程空间建立一个大小为（1M-8K）的共享内存区
  1. 在打开binder设备时，在内核中会创建一个与RadioService进程相关的`binder_proc`对象

* [RadioService进程空间] BpServiceManager的addService逻辑
> 1. 向Parcel中主要设置的内容（需要传到binder内核）：服务的name和服务的对象（就是RadioService服务，在写入服务对象(writeStrongBinder)的时候，`writeStrongBinder`函数会调用`flatten_binder`函数，而该函数调用service的localBinder()获取binder引用或者实体，因为此处为本地service实体不为空，则此处设置了`flat_binder_object`类型的type成员为`BINDER_TYPE_BINDER`;
  1. BpServiceManager的父类BpInterface<IServiceManager>的父类BpRefBase中一个重要成员`IBinder* mRemote`，该mRemote就是获取`gDefaultServiceManager`过程中，创建的一个handle为0的BpBinder对象；
  2. addService最后调用到该BpBinder的`transact`函数，BpBinder的`transact`函数的第一参数code实际代表的是IServiceManager提供的功能（get/check/add/list）,就类似将不同的函数功能映射到code上；
  3. `transact`函数实际调用`IPCThreadState::self()`对象的`transact`函数；IPCThreadState是线程相关的类，进程内不同进程会产生不同的`IPCThreadState::self()`对象；
  4. 在BpBinder中的`transact`函数内，会用到handle（此处的就是ServiceManager的handle），作为参数传到IPCThreadState的`transact`函数中；

* [RadioService进程空间] IPCThreadState的transact逻辑：
> 1. 将handle、对应了IServiceManager的函数功能的code、传输的parcel数据（server name和obj）放到`binder_transaction_data`类型对象中
  1. cmd + `binder_transaction_data`再被打包到parcel中（cmd命令为BC_TRANSACTION），此时的parcel才是真正即将从用户空间传到binder内核空间的数据（此处的cmd表示了transact的类型，而上面的code实际表示了server中提供的某函数服务）
  2. 打包完cmd和具体的通信数据后，进入`waitForResponse`函数；

* [RadioService进程空间] IPCThreadState的waitForResponse逻辑：
  > 1. `waitForResponse`函数中`while(1)`循环中，首先调用`talkWithDriver`与binder驱动打交道；
    1. `talkWithDriver`函数中，将上面打包的parcel数据放到`binder_write_read`中，此类型数据是实际用于同binder驱动交互的数据格式；
    2. 设置好`binder_write_read`类型数据后，正式调用`ioctl`开始与binder驱动通信了,其第一个参数是binder设备fd，第二个是binder驱动通信最原始cmd类型BINDER_WRITE_READ（只有5种类型），第三个参数类型是用于用户空间和内核空间互相传输数据的类型

* [Binder内核空间] 用户空间调用的`ioctl`会调用到内核空间的`binder_ioctl`函数：
> 1. 根据ioctl调用时的cmd类型BINDER_WRITE_READ，进入了内核中的`binder_ioctl_write_read`函数
  1. `binder_ioctl_write_read`函数的最后一个参数是binder_thread类型，所以在进入`binder_ioctl_write_read`函数前会根据`binder_proc`对象在内核中创建一个`binder_thread`对象，`binder_proc`的对象是在`RadioService`构造时打开binder时创建的；

* [Binder内核空间] 进入内核的`binder_ioctl_write_read`函数：
> 1. 首先需要将用户空间的数据拷贝到内核中`binder_write_read`类型bwr局部对象中；
  1. 当bwr中write_size（即用户空间传过来的数据大小）大于0，则需要执行`binder_thread_write`内核函数
  2. 当bwr中read_size（即内核空间需要传给用户空间数据的大小）大于0，则需要执行`binder_thread_read`内核函数；执行完`binder_thread_read`后，检查此RadioService进程在内核中`binder_proc`对象中的todo事务列表是否为空，不为空，则唤醒`proc->wait`队列中的线程开始干活（注册本服务过程中，todo为空）
  3. 内核中的任务执行完，还需要将返回的数据从内核中拷贝到用户空间。

* [Binder内核空间] 内核的`binder_thread_write`函数（用户空间数据->内核空间）执行逻辑：
> 1. 读出RadioService进程调用ServiceManager的transact函数时传入的cmd（BC_TRANSACTION），并进入对应的case中，将用户空间的存放了handle、ServiceManager的addService函数对应的code、RadioService服务的名和对象的binder_transaction_data类型对象拷贝到内核空间的binder_transaction_data类型对象tr中；
  1. 执行`binder_transaction`内核函数，传到该函数的最后一个参数根据cmd是否等于BC_REPLY表示是否需要replay，此处不需要replay，进入非replay条件句；
  2. 进入`binder_transaction`内核函数的非replay条件句后，因为注册service传入的handle为0，则直接将ServiceManager的binder实例（binder_node类型）赋给target_node变量；创建binder_transaction对象，并将本次执行的进程/线程、ServiceManager工作的进程/线程、以及前面拷贝到内核空间的`binder_transaction_data`类型对象中的code、flags、buffer等数据赋值给刚刚的`binder_transaction`对象（其buffer成员的内存是在ServiceManager进程中分配的）；
  3. `binder_transaction`对象成员赋值完，根据在RadioService进程包裹IBinder时设置了`flat_binder_object`成员type为`BINDER_TYPE_BINDER`，进入对应的处理case；
  4. 查询是否有当前服务的binder实体（binder_node），此时没有，创建`binder_node`的RadioService的内核实体（拥有跟该service相关进程、线程等信息）。并为ServerManager进程添加对该RadioService binder实体的引用；同时会设置flat_binder_object的fp对象type为BINDER_TYPE_HANDLE，因为该fp修改其实作用在binder_transaction类型t数据中（其实就是type类型在开始是因为RadioService注册，属于本地，填写的是BINDER_TYPE_BINDER，而这部分数据在注册的过程中需要传给ServerManager，ServiceManager只能是引用，所以再给事务对象操作过程中，将类型设置成了BINDER_TYPE_HANDLE）
  5. 完成注册事务对象的设置后，将此事务添加到ServiceManager中的线程的todo列表中；此时ServiceManager线程处于休眠状态，将其唤醒处理本次注册事务；

* [Binder内核空间] 内核的`binder_thread_read`函数（内核空间->用户空间数据）执行逻辑：
> 1. 因bwr的的consume为0，所以会设回一个BR_NOOP值到RadioService所在进程
  1. 在上面的binder_transaction中，设置了tcomplete的type为BINDER_WORK_TRANSACTION_COMPLETE事务到thread的todo列表中，故thread的todo列表不为空，即暂时RadioService进程还不处于等待工作阶段；
  2. 进入while循环，取出todo中的事务，即去除了type为BINDER_WORK_TRANSACTION_COMPLETE的事务，进入该类型处理域中，设回值为BR_TRANSACTION_COMPLETE的cmd到用户空间，然后释放该事务内存；
  3. 因其中的t为null，continue到循环开始处，此时todo列表为空，则退出循环。最后设置consume的值，结束binder_thread_read内的工作。

* [RadioService进程空间] 内核空间逻辑处理完，回到了用户空间的`talkWithDriver`函数内，继续执行进入内核空间`ioctl`后面的代码：
> 1. 清除mOut数据，同时设置mIn的大小和数据位置（内核应该将数据传回了）用于后面的读出；
  1. 执行完一次`talkWithDriver`函数，此时仍然在`IPCThreadState::waitForResponse`函数内的while循环内，读出mIn内的第一个整数BR_NOOP(内核中thread_read函数中设置的)，调用`executeCommand`函数，根据其cmd值，不做任何事；
  2. 回到while循环的开始，调用`talkWithDriver`函数，因为mIn内还有一个数据未读出，既是bwr未做好读的准备，不会进行ioctl，直接返回了NO_ERROR
  3. 继续读出mIn中的`BR_TRANSACTION_COMPLETE`，进入对应case，因为最开始调用addService时，传给`IPCThreadState::self()->transact`函数reply参数了，即此时不会finish，会继续待在`IPCThreadState::waitForResponse`函数内；

* [RadioService进程空间] 继续执行waitForResponse函数，此时mIn和mOut内都是空的：
> 1. 设置bwr内read/write的相关数据，write的数据为空，read设置成了mIn可接收数据大小；
  1. 即调用`ioctl'时，没有任何数据从用户空间传到内核空间；
  2. 因write_size为0，进到内核时，直接执行到`binder_thread_read`内；

* [Binder内核空间] 进入内核的`binder_thread_read`函数：
  > 1. 进入binder_thread_read内后，会执行到`wait_event_interruptible`函数，让RadioService进程进入休眠状态，等待ServiceManager的唤醒

* addService到此算是基本完成


## RadioService如何注册详细分析
```c++
// 位置：/frameworks/av/services/radio/RadioService.h
class RadioService :
    public BinderService<RadioService>,     // ====> [BinderService类的定义]
    public BnRadioService
{
  // RadioService::instantiate()实际是调用了父类BinderService中的instantiate()
  //      具体见[BinderService类的定义]
  static char const* getServiceName() { return "media.radio"; }

  // ====> instantiate()的定义相当于：
  static void instantiate() { 
    // sm的实际类型BpServiceManager
    sp<IServiceManager> sm(defaultServiceManager());
    // ====> 见[BpServiceManager的addService接口定义]
    sm->addService("media.radio", new RadioService(), false);
  }
}
```

* [BinderService类的定义](#BinderService_def)

* [BpServiceManager的addService接口定义](#addService_func_def)




---------------------------
**<span id = "BinderService_def">BinderService类的定义:</span>**
```c++
template<typename SERVICE>
class BinderService {
public:
    static status_t publish(bool allowIsolated = false) {
        sp<IServiceManager> sm(defaultServiceManager());
        return sm->addService(
                String16(SERVICE::getServiceName()),
                new SERVICE(), allowIsolated);
    }

    static void publishAndJoinThreadPool(bool allowIsolated = false) {
        publish(allowIsolated);
        joinThreadPool();
    }

    static void instantiate() { publish(); }

    static status_t shutdown() { return NO_ERROR; }

private:
    static void joinThreadPool() {
        sp<ProcessState> ps(ProcessState::self());
        ps->startThreadPool();
        ps->giveThreadPoolName();
        IPCThreadState::self()->joinThreadPool();
    }
}
```

**<span id = "addService_func_def">BpServiceManager的addService接口定义</span>**
```c++
// 位置：/frameworks/native/libs/binder/IServiceManager.cpp
virtual status_t addService(const String16& name, const sp<IBinder>& service,
        bool allowIsolated)
{
    Parcel data, reply;
    data.writeInterfaceToken(IServiceManager::getInterfaceDescriptor());  // ?getInterfaceDescriptor不是静态成员函数，为何能这么调用
    data.writeString16(name);
    // 此处的service是属于server端的，此处的类型为 RadioService
    data.writeStrongBinder(service);
    data.writeInt32(allowIsolated ? 1 : 0);
    // ====> remote()返回父类BpRefBase中的mRemote成员（IBinder* const类型），
    //    实际就是开始为获取ServiceManager时，创建的BpBinder对象；用于同ServiceManager进程通信
    status_t err = remote()->transact(ADD_SERVICE_TRANSACTION, data, &reply);
    return err == NO_ERROR ? reply.readExceptionCode() : err;
}

// 如何向binder驱动发送数据
status_t BpBinder::transact(
    uint32_t code, const Parcel& data, Parcel* reply, uint32_t flags)
{
    // Once a binder has died, it will never come back to life.
    if (mAlive) {
        // ====> 见[IPCThreadState如何进行transact]
        status_t status = IPCThreadState::self()->transact(
            mHandle, code, data, reply, flags);   // mHandle=0
        if (status == DEAD_OBJECT) mAlive = 0;
        return status;
    }
    return DEAD_OBJECT;
}
```




* [IPCThreadState如何进行transact](#IPCThreadState_def)

* [writeTransactionData函数分析](#writeTransactionData_def)

* [waitForResponse函数分析](#waitForResponse_def)




**<span id = "ProcessState_detail_def">ProcessState类的详细分析</span>**
```c++
// ====> 重点关注的一些成员
// 调用ProcessState::self()->getStrongProxyForHandle接口时，会先在mHandleToObject内查询
//    如果存在对应handle的handle_entry对象，则返回对象的binder成员；
//    不存在，则创建handle_entry（会放到mHandleToObject中），并将创建的BpBinder(handle)赋值给成员binder
 Vector<handle_entry> mHandleToObject;
 
 // ====> /dev/binder虚拟设备的文件描述符
 int mDriverFD;
 
 // ====> ProcessState对象的初始化工作（一个进程中只有一个ProcessState实例，即sp<ProcessState> gProcess实例）
 //   gProcess实例通过ProcessState::self()的静态成员函数获得
 ProcessState::ProcessState()
    : mDriverFD(open_driver())      // ====> 打开/dev/binder设备
    , mVMStart(MAP_FAILED)
    , mThreadCountLock(PTHREAD_MUTEX_INITIALIZER)
    , mThreadCountDecrement(PTHREAD_COND_INITIALIZER)
    , mExecutingThreadsCount(0)
    , mMaxThreads(DEFAULT_MAX_BINDER_THREADS) // DEFAULT_MAX_BINDER_THREADS 15
    , mManagesContexts(false)
    , mBinderContextCheckFunc(NULL)
    , mBinderContextUserData(NULL)
    , mThreadPoolStarted(false)
    , mThreadPoolSeq(1)
{
    if (mDriverFD >= 0) {
        // XXX Ideally, there should be a specific define for whether we
        // have mmap (or whether we could possibly have the kernel module
        // availabla).
#if !defined(HAVE_WIN32_IPC)
        // mmap the binder, providing a chunk of virtual address space to receive transactions.
        // ====> BINDER_VM_SIZE为(1*1024*1024) - (4096 *2)
        //   进程空间与binder内核空间的内存映射（Client发送的数据拷贝到binder内核后，直接映射在server此段内存中，无需2次拷贝）
        mVMStart = mmap(0, BINDER_VM_SIZE, PROT_READ, MAP_PRIVATE | MAP_NORESERVE, mDriverFD, 0);
        if (mVMStart == MAP_FAILED) {
            ALOGE("Using /dev/binder failed: unable to mmap transaction memory.\n");
            close(mDriverFD);
            mDriverFD = -1;
        }
#else
        mDriverFD = -1;
#endif
    }
    LOG_ALWAYS_FATAL_IF(mDriverFD < 0, "Binder driver could not be opened.  Terminating.");
}

// ====> open_driver具体内容
static int open_driver()
{
    // 打开binder虚拟设备，会在binder内核中创建一个binder_proc对象，该对象内也保存了server进程信息
    int fd = open("/dev/binder", O_RDWR);
    if (fd >= 0) {
        // 设置文件描述符标记，FD_CLOEXEC表示执行exec调用新程序中会关闭该fd
        fcntl(fd, F_SETFD, FD_CLOEXEC);
        int vers = 0;
        // 同ServiceManager启动时类似，对比binder内核的版本与用户空间的binder版本是否一致
        status_t result = ioctl(fd, BINDER_VERSION, &vers);
        if (result == -1) {
            ALOGE("Binder ioctl to obtain version failed: %s", strerror(errno));
            close(fd);
            fd = -1;
        }
        if (result != 0 || vers != BINDER_CURRENT_PROTOCOL_VERSION) {
            ALOGE("Binder driver protocol does not match user space protocol!");
            close(fd);
            fd = -1;
        }
        // 设置binder内核支持的最大线程数
        size_t maxThreads = DEFAULT_MAX_BINDER_THREADS;
        result = ioctl(fd, BINDER_SET_MAX_THREADS, &maxThreads);
        if (result == -1) {
            ALOGE("Binder ioctl to set max threads failed: %s", strerror(errno));
        }
    } else {
        ALOGW("Opening '/dev/binder' failed: %s\n", strerror(errno));
    }
    return fd;    // 返回打开的/dev/binder虚拟设备的文件描述符
}

// ====> [1]启动线程池
void ProcessState::startThreadPool()
{
    AutoMutex _l(mLock);
    if (!mThreadPoolStarted) {  // mThreadPoolStarted构造时为false
        mThreadPoolStarted = true;
        spawnPooledThread(true);  // 见[2]
    }
}
// ====> [2]
void ProcessState::spawnPooledThread(bool isMain)
{
    if (mThreadPoolStarted) {
        String8 name = makeBinderThreadName();  // 见[3]
        ALOGV("Spawning new pooled thread, name=%s\n", name.string());
        sp<Thread> t = new PoolThread(isMain);  // ====> 见[PoolThread类分析]
        // ====> 实际调用到Thread类的_threadLoop函数，继而调用到纯虚函数threadLoop
        //    最终调用的是IPCThreadState::self()->joinThreadPool(isMain)函数（isMain)此处为true）
        t->run(name.string());
    }
}
// ====> [3]
String8 ProcessState::makeBinderThreadName() {
    int32_t s = android_atomic_add(1, &mThreadPoolSeq); // mThreadPoolSeq构造时为1，即不断+1
    String8 name;
    name.appendFormat("Binder_%X", s);  // 返回形如Binder_1/Binder_2的字符串
    return name;
}
```

* [PoolThread类分析](#PoolThread_def)
* [Thread类头文件][16]/[Thread定义文件][17]
* [IPCThreadState的joinThreadPool详细分析](IPCThreadState_joinThreadPool_def)


**<span id = "PoolThread_def">PoolThread类分析</span>**
```c++
class PoolThread : public Thread
{
public:
    PoolThread(bool isMain)
        : mIsMain(isMain)
    { }
protected:
    virtual bool threadLoop()   // thread中run实际会调用到此函数
    {
        IPCThreadState::self()->joinThreadPool(mIsMain);
        return false;
    }
    const bool mIsMain;
};
```





**<span id = "IPCThreadState_joinThreadPool_def">IPCThreadState的joinThreadPool详细分析</span>**
```c++
void IPCThreadState::joinThreadPool(bool isMain/*=true*/)
{
    mOut.writeInt32(isMain ? BC_ENTER_LOOPER : BC_REGISTER_LOOPER);
    // This thread may have been spawned by a thread that was in the background
    // scheduling group, so first we will make sure it is in the foreground
    // one to avoid performing an initial transaction in the background.
    set_sched_policy(mMyThreadId, SP_FOREGROUND);
    status_t result;
    do {
        processPendingDerefs();
        // now get the next command to be processed, waiting if necessary
        // ====> 1.等待client发起某个服务（如RadioService的某个服务函数）的请求命令
        //  2.并调用executeCommand执行相应的功能处理
        //  3.后面会执行到the_context_object->transact()函数，即BBinder的transact函数
        //  4.最后执行到BBinder::onTransact函数内，因该函数为虚函数，实际service继承了BBinder后覆写该接口，
        //      如RadioService就是调用了BnRadioService::onTransact函数，在该函数内才真正处理client端ipc调用的service函数请求
        result = getAndExecuteCommand(); 

        if (result < NO_ERROR && result != TIMED_OUT && result != -ECONNREFUSED && result != -EBADF) {
            ALOGE("getAndExecuteCommand(fd=%d) returned unexpected error %d, aborting",
                  mProcess->mDriverFD, result);
            abort();
        }

        // Let this thread exit the thread pool if it is no longer
        // needed and it is not the main process thread.
        if(result == TIMED_OUT && !isMain) {
            break;
        }
    } while (result != -ECONNREFUSED && result != -EBADF);

    LOG_THREADPOOL("**** THREAD %p (PID %d) IS LEAVING THE THREAD POOL err=%p\n",
        (void*)pthread_self(), getpid(), (void*)result);

    mOut.writeInt32(BC_EXIT_LOOPER);
    talkWithDriver(false);
}
```


**<span id = "IPCThreadState_def">IPCThreadState如何进行transact</span>**
[IPCThreadState.h][3]和[IPCThreadState.cpp][4]代码段：
```c++
  // IPCThreadState对象中用于和Binder内核交流数据的两个成员：Parcel mIn/mOut;
  // ====> 创建每个线程自己的IPCThreadState对象
  //    初始构造中会保存自己所在进程ProcessState指针
  IPCThreadState* IPCThreadState::self()
  {
    if (gHaveTLS) {
  restart:
        const pthread_key_t k = gTLS;
        IPCThreadState* st = (IPCThreadState*)pthread_getspecific(k);
        if (st) return st;
        return new IPCThreadState;
    }
    if (gShutdown) return NULL;
    pthread_mutex_lock(&gTLSMutex);
    if (!gHaveTLS) {
        if (pthread_key_create(&gTLS, threadDestructor) != 0) {
            pthread_mutex_unlock(&gTLSMutex);
            return NULL;
        }
        gHaveTLS = true;
    }
    pthread_mutex_unlock(&gTLSMutex);
    goto restart;
  }
    
  status_t IPCThreadState::transact(int32_t handle,
                                    uint32_t code, const Parcel& data,
                                    Parcel* reply, uint32_t flags)
  {
      status_t err = data.errorCheck();
      flags |= TF_ACCEPT_FDS;
      if (err == NO_ERROR) {
          // 此处传入的code为 ADD_SERVICE_TRANSACTION 
          err = writeTransactionData(BC_TRANSACTION, flags, handle, code, data, NULL);  // ====> 见[writeTransactionData函数分析]
      }
      if (err != NO_ERROR) {
          if (reply) reply->setError(err);
          return (mLastError = err);
      }
      if ((flags & TF_ONE_WAY) == 0) {  // flags=0  TF_ONE_WAY=0x01
          #endif
          if (reply) {  // service 在addService调用时是由reply的
              err = waitForResponse(reply);   // ====> 见[waitForResponse函数分析]
          } else {
              Parcel fakeReply;
              err = waitForResponse(&fakeReply);
          }
      } else {
          err = waitForResponse(NULL, NULL);
      }
      return err;
  }
```

* [writeTransactionData函数分析](#writeTransactionData_def)

* [waitForResponse函数分析](#waitForResponse_def)

* [talkWithDriver函数分析](#talkWithDriver_def)


**<span id = "writeTransactionData_def">writeTransactionData函数分析</span>**
```c++
// ====> 参数：cmd为BC_TRANSACTION | binderFlags为0 |  handle为0 | code为ADD_SERVICE_TRANSACTION
//    将需要传给binder内核数据放到mOut中
status_t IPCThreadState::writeTransactionData(int32_t cmd, uint32_t binderFlags,
  int32_t handle, uint32_t code, const Parcel& data, status_t* statusBuffer)
{
    binder_transaction_data tr;
    tr.target.ptr = 0; /* Don't pass uninitialized stack data to a remote process */
    tr.target.handle = handle;    // server端使用时，该handle值为0，表示使用的是ServiceManager的代理
    tr.code = code;
    tr.flags = binderFlags;
    tr.cookie = 0;
    tr.sender_pid = 0;
    tr.sender_euid = 0;
    const status_t err = data.errorCheck();
    if (err == NO_ERROR) {
        tr.data_size = data.ipcDataSize();
        tr.data.ptr.buffer = data.ipcData();
        tr.offsets_size = data.ipcObjectsCount()*sizeof(binder_size_t);
        tr.data.ptr.offsets = data.ipcObjects();
    } else if (statusBuffer) {
        tr.flags |= TF_STATUS_CODE;
        *statusBuffer = err;
        tr.data_size = sizeof(status_t);
        tr.data.ptr.buffer = reinterpret_cast<uintptr_t>(statusBuffer);
        tr.offsets_size = 0;
        tr.data.ptr.offsets = 0;
    } else {
        return (mLastError = err);
    }
    mOut.writeInt32(cmd);   // 当转入到binder内核处理ioctl时，其命令类型BC_TRANSACTIO
    mOut.write(&tr, sizeof(tr));
    return NO_ERROR;
}
```

**<span id = "waitForResponse_def">waitForResponse函数分析</span>**
```c++
status_t IPCThreadState::waitForResponse(Parcel *reply, status_t *acquireResult)
{
    uint32_t cmd;
    int32_t err;
    while (1) {
        if ((err=talkWithDriver()) < NO_ERROR) break;
        // ====> ServiceManager对于此次addService的回应会在talkWithDriver结束后设置到mIn中
        err = mIn.errorCheck();
        if (err < NO_ERROR) break;
        if (mIn.dataAvail() == 0) continue;
        cmd = (uint32_t)mIn.readInt32();
        IF_LOG_COMMANDS() {
            alog << "Processing waitForResponse Command: "
                << getReturnString(cmd) << endl;
        }
        switch (cmd) {
        case BR_TRANSACTION_COMPLETE:
            if (!reply && !acquireResult) goto finish;
            break;
        case BR_DEAD_REPLY:
            err = DEAD_OBJECT;
            goto finish;
        case BR_FAILED_REPLY:
            err = FAILED_TRANSACTION;
            goto finish;
        case BR_ACQUIRE_RESULT:
            {
                ALOG_ASSERT(acquireResult != NULL, "Unexpected brACQUIRE_RESULT");
                const int32_t result = mIn.readInt32();
                if (!acquireResult) continue;
                *acquireResult = result ? NO_ERROR : INVALID_OPERATION;
            }
            goto finish;
        case BR_REPLY:
            {
                binder_transaction_data tr;
                err = mIn.read(&tr, sizeof(tr));
                ALOG_ASSERT(err == NO_ERROR, "Not enough command data for brREPLY");
                if (err != NO_ERROR) goto finish;

                if (reply) {
                    if ((tr.flags & TF_STATUS_CODE) == 0) {
                        reply->ipcSetDataReference(
                            reinterpret_cast<const uint8_t*>(tr.data.ptr.buffer),
                            tr.data_size,
                            reinterpret_cast<const binder_size_t*>(tr.data.ptr.offsets),
                            tr.offsets_size/sizeof(binder_size_t),
                            freeBuffer, this);
                    } else {
                        err = *reinterpret_cast<const status_t*>(tr.data.ptr.buffer);
                        freeBuffer(NULL,
                            reinterpret_cast<const uint8_t*>(tr.data.ptr.buffer),
                            tr.data_size,
                            reinterpret_cast<const binder_size_t*>(tr.data.ptr.offsets),
                            tr.offsets_size/sizeof(binder_size_t), this);
                    }
                } else {
                    freeBuffer(NULL,
                        reinterpret_cast<const uint8_t*>(tr.data.ptr.buffer),
                        tr.data_size,
                        reinterpret_cast<const binder_size_t*>(tr.data.ptr.offsets),
                        tr.offsets_size/sizeof(binder_size_t), this);
                    continue;
                }
            }
            goto finish;
        default:
            err = executeCommand(cmd);
            if (err != NO_ERROR) goto finish;
            break;
        }
    }
finish:
    if (err != NO_ERROR) {
        if (acquireResult) *acquireResult = err;
        if (reply) reply->setError(err);
        mLastError = err;
    }
    return err;
}
```

** <span id = "talkWithDriver_def">talkWithDriver函数分析</span>：**
```c++
status_t IPCThreadState::talkWithDriver(bool doReceive /*=true*/)
{
    if (mProcess->mDriverFD <= 0) {
        return -EBADF;
    }
    binder_write_read bwr;
    // Is the read buffer empty?
    // ====>  检查当前mIn内从binder内核接收的数据已读完
    const bool needRead = mIn.dataPosition() >= mIn.dataSize();
    // We don't want to write anything if we are still reading
    // from data left in the input buffer and the caller
    // has requested to read the next data.
    // ====> 如果不需要接收返回或者mIn数据已读完，则mOut可以传数据给binder内核了
    const size_t outAvail = (!doReceive || needRead) ? mOut.dataSize() : 0;
    bwr.write_size = outAvail;
    bwr.write_buffer = (uintptr_t)mOut.data();
    if (doReceive && needRead) {                  // 需要接收返回 && read buffer为空
        bwr.read_size = mIn.dataCapacity();
        bwr.read_buffer = (uintptr_t)mIn.data();
    } else {
        bwr.read_size = 0;
        bwr.read_buffer = 0;
    }
    // Return immediately if there is nothing to do.
    if ((bwr.write_size == 0) && (bwr.read_size == 0)) return NO_ERROR;
    bwr.write_consumed = 0;
    bwr.read_consumed = 0;
    status_t err;
    do {
        // ====> 发送本次注册RadioService的请求到binder，
        //         同serviceManager启动时一样，最后会进入binder_thread_write中
        //         因bwr.read_size不为0，binder_thread_write执行结束后会进入binder_thread_read
        if (ioctl(mProcess->mDriverFD, BINDER_WRITE_READ, &bwr) >= 0)
            err = NO_ERROR;
        else
            err = -errno;
        if (mProcess->mDriverFD <= 0) {
            err = -EBADF;
        }
    } while (err == -EINTR);
    if (err >= NO_ERROR) {
        if (bwr.write_consumed > 0) {
            if (bwr.write_consumed < mOut.dataSize())
                mOut.remove(0, bwr.write_consumed);
            else
                mOut.setDataSize(0);
        }
        if (bwr.read_consumed > 0) {
            mIn.setDataSize(bwr.read_consumed);
            mIn.setDataPosition(0);
        }
        return NO_ERROR;
    }
    return err;
}
```

** cmd为BC_TRANSACTIO的[binder_thread_write][13]操作**
```c++
case BC_TRANSACTION:
case BC_REPLY: {
  struct binder_transaction_data tr;
  if (copy_from_user(&tr, ptr, sizeof(tr)))
    return -EFAULT;
  ptr += sizeof(tr);
  binder_transaction(proc, thread, &tr, cmd == BC_REPLY); // cmd是BC_TRANSACTION
  break;
}
```


** [binder_transaction][14]的处理逻辑**
```c++
static void binder_transaction(struct binder_proc *proc,
                    struct binder_thread *thread,
                    struct binder_transaction_data *tr, int reply) {
        // reply是由(cmd == BC_REPLY)判断的，此时为false，且tr->target.handle为0
        //  故在cmd为BC_TRANSACTIO调用逻辑
        struct binder_transaction *t;
        struct binder_work *tcomplete;
        target_node = binder_context_mgr_node;  // ServiceManager在binder内核的管理实体
        target_proc = target_node->proc;    // ServiceManager服务进程
        target_list = &target_proc->todo;
        target_wait = &target_proc->wait;
        t = kzalloc(sizeof(*t), GFP_KERNEL);
        binder_stats_created(BINDER_STAT_TRANSACTION);
        tcomplete = kzalloc(sizeof(*tcomplete), GFP_KERNEL);
        binder_stats_created(BINDER_STAT_TRANSACTION_COMPLETE);
        copy_from_user(t->buffer->data, (const void __user *)(uintptr_t)
			   tr->data.ptr.buffer, tr->data_size);    // 拷贝RadioService进程传送的数据到binder内核binder_transaction对象中
        // 创建binder_node节点，并放到serverManager的binder_proc对象内的红黑树中
        ref = binder_get_ref_for_node(target_proc, node);
        t->work.type = BINDER_WORK_TRANSACTION;
        list_add_tail(&t->work.entry, target_list);
        tcomplete->type = BINDER_WORK_TRANSACTION_COMPLETE;
        list_add_tail(&tcomplete->entry, &thread->todo);
        if (target_wait) {
          wake_up_interruptible(target_wait); // 将ServerManager从启动looper后一直休眠状态中唤醒
        }  
}
```
** [binder_thread_read][15]操作**
```c++
case BINDER_WORK_TRANSACTION: {
			t = container_of(w, struct binder_transaction, work);
		} break;
		case BINDER_WORK_TRANSACTION_COMPLETE: {
			cmd = BR_TRANSACTION_COMPLETE;
			if (put_user(cmd, (uint32_t __user *)ptr))
				return -EFAULT;
			ptr += sizeof(uint32_t);

			binder_stat_br(proc, thread, cmd);
			binder_debug(BINDER_DEBUG_TRANSACTION_COMPLETE,
				     "%d:%d BR_TRANSACTION_COMPLETE\n",
				     proc->pid, thread->pid);

			list_del(&w->entry);
			kfree(w);
			binder_stats_deleted(BINDER_STAT_TRANSACTION_COMPLETE);
		} break
```







** <span id = "interface_cast_def">interface_cast模板函数定义</span>：**
```c++
template<typename INTERFACE>
inline sp<INTERFACE> interface_cast(const sp<IBinder>& obj)
{
    return INTERFACE::asInterface(obj);
}
```

<span id = "asInterface_server_mng_def">IServiceManager::asInterface函数定义</span>：
```c++
// 通过下面两个宏，完成了对IServiceManager的部分定义
#define DECLARE_META_INTERFACE(INTERFACE)
#define IMPLEMENT_META_INTERFACE(INTERFACE, NAME)
// ====> 实际定义
class IServiceManager : public IInterface
{
public:
    static const android::String16 descriptor;
    static android::sp<IServiceManager> asInterface(const android::sp<android::IBinder>& obj);
    virtual const android::String16& getInterfaceDescriptor() const;
    IServiceManager();
    virtual ~IServiceManager();
    ...
}
    // ====> 具体实现
    const android::String16 ServiceManager::descriptor("android.os.IServiceManager");
    const android::String16& IServiceManager::getInterfaceDescriptor() const {
        return IServiceManager::descriptor;
    }
    android::sp<IServiceManager> IServiceManager::asInterface(const android::sp<android::IBinder>& obj)                   \
    {
        android::sp<IServiceManager> intr;
        if (obj != NULL) {
            intr = static_cast<IServiceManager*>(
                // 传入的obj类型实际是BpBinder，其queryLocalInterface集成自父类，父类中是返回NULL
                obj->queryLocalInterface(IServiceManager::descriptor).get());
            if (intr == NULL) {
                intr = new BpServiceManager(obj);
            }
        }
        return intr;
    }
    IServiceManager::IServiceManager() { }
    IServiceManager::~IServiceManager() { }
```

** <span id = "BpServiceManager_detail_def">BpServiceManager类的具体定义</span>：**
```c++
class BpServiceManager : public BpInterface<IServiceManager>
{
public:
    BpServiceManager(const sp<IBinder>& impl)
        : BpInterface<IServiceManager>(impl)
    { }
    ...
}

// ====> 模板类BpInterface构造函数定义
inline BpInterface<IServiceManager>::BpInterface(const sp<IBinder>& remote)
    : BpRefBase(remote)
{}  

// =====> BpRefBase中一个成员为 （IBinder* const mRemote;）
BpRefBase::BpRefBase(const sp<IBinder>& o)
    : mRemote(o.get()), mRefs(NULL), mState(0)
{
    extendObjectLifetime(OBJECT_LIFETIME_WEAK);
    if (mRemote) {
        mRemote->incStrong(this);           // Removed on first IncStrong().
        mRefs = mRemote->createWeak(this);  // Held for our entire lifetime.
    }
}
```






** <span id = "lookupHandleLocked_func_def">lookupHandleLocked函数定义</span>：**
```c++
ProcessState::handle_entry* ProcessState::lookupHandleLocked(int32_t handle)
{ 
    // mHandleToObject是存放handle_entry类型对象的Vector [handle_entry类型定义见下面]
    const size_t N = mHandleToObject.size();
    if (N <= (size_t)handle) {
        // handle索引不到对应的handle_entry类型对象，创建一个handle_entry类型对象
        //    插入到mHandleToObject中,创建的handle_entry类型对象目前成员都为null
        handle_entry e;
        e.binder = NULL;
        e.refs = NULL;
        status_t err = mHandleToObject.insertAt(e, N, handle+1-N);
        if (err < NO_ERROR) return NULL;
    }
    // 返回handle对应的handle_entry类型对象用于后面的操作（返回的对象可修改）
    return &mHandleToObject.editItemAt(handle);
}
```

** <span id = "handle_entry_def">handle_entry类型定义</span>：**
```c++
// ====> handle_entry类型
struct handle_entry {
   IBinder* binder;
   RefBase::weakref_type* refs;
};
```








搜索这个宏，可搜到有很多系统服务 DECLARE_META_INTERFACE



[1]: http://androidxref.com/6.0.1_r10/xref/frameworks/native/include/binder/
[2]: http://androidxref.com/6.0.1_r10/xref/frameworks/native/libs/binder/
[3]: http://androidxref.com/6.0.1_r10/xref/frameworks/native/include/binder/IPCThreadState.h
[4]: http://androidxref.com/6.0.1_r10/xref/frameworks/native/libs/binder/IPCThreadState.cpp
[5]: http://androidxref.com/6.0.1_r10/xref/frameworks/native/libs/binder/Static.cpp#76
[6]: http://androidxref.com/6.0.1_r10/xref/frameworks/native/libs/binder/IServiceManager.cpp
[7]: http://androidxref.com/6.0.1_r10/xref/frameworks/native/include/private/binder/Static.h#39
[8]: http://androidxref.com/6.0.1_r10/xref/frameworks/native/include/binder/BpBinder.h
[9]: http://androidxref.com/6.0.1_r10/xref/frameworks/native/libs/binder/BpBinder.cpp
[10]: http://androidxref.com/6.0.1_r10/xref/frameworks/native/include/binder/IBinder.h
[11]: http://androidxref.com/6.0.1_r10/xref/frameworks/native/libs/binder/Binder.cpp#42
[12]: http://androidxref.com/6.0.1_r10/xref/frameworks/av/media/mediaserver/main_mediaserver.cpp
[13]: http://lxr.free-electrons.com/source/drivers/android/binder.c#L1755
[14]: http://lxr.free-electrons.com/source/drivers/android/binder.c#L1317
[15]: http://lxr.free-electrons.com/source/drivers/android/binder.c#L2142
[16]: http://androidxref.com/6.0.1_r10/xref/system/core/include/utils/Thread.h
[17]: http://androidxref.com/6.0.1_r10/xref/system/core/libutils/Threads.cpp#654
