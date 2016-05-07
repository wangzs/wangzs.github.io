title: ServiceManager服务的启动
date: 2016-04-29  09:32
tag: [Android, Binder, ServiceManager]
---

# ServiceManager服务进程的启动
主要代码的路径：
> [/frameworks/native/cmds/servicemanager/binder.h][1]
 [/frameworks/native/cmds/servicemanager/binder.c][2]
 [/frameworks/native/cmds/servicemanager/service_manager.c][3]

<!-- more -->

###### service_manager.c代码分析
```c++
// 将16位的字符截断只要低b位的数据
const char *str8(const uint16_t *x, size_t x_len)
{
    static char buf[128];
    size_t max = 127;
    char *p = buf;

    if (x_len < max) {
        max = x_len;
    }

    if (x) {
        // 超出16位字符数组长度或配到16位数据的低8位数据为0x00的字符
        while ((max > 0) && (*x != '\0')) {
            *p++ = *x++;
            max--;
        }
    }
    *p++ = 0;
    return buf;
}

// 16位数组与8位数组的数据是否相等判断 1-相等  0-不等
int str16eq(const uint16_t *a, const char *b)
{
	while (*a && *b)
		if (*a++ != *b++) return 0;
	if (*a || *b)
		return 0;
	return 1;
}


static int selinux_enabled;             // 
static char *service_manager_context;   // 
static struct selabel_handle* sehandle; // 


// service_manager服务进程的启动main函数
int main(int argc, char **argv)
{
    struct binder_state *bs;
    // 1.打开binder虚拟设备，会在binder内核中创建一个binder_proc对象，该对象内也保存了service_manager进程信息
    //    这样service_manager进程相关信息就在binder内核有了一席之地，为后面设置service_manager为context的manager做基础
    // 2.内核binder的版本与用户层binder版本对比
    // 3.映射设备的一段内容到本进程的一段内存中（binder_mmap）
    //      其实就是将binder驱动所在的内核区内存映射到service_manager进程空间中
    bs = binder_open(128*1024);
    if (!bs) {
        ALOGE("failed to open binder driver\n");
        return -1;
    }
    // 通过ioctl向驱动层发送BINDER_SET_CONTEXT_MGR设置service_manager进程为context manager
    //    主要是在binder内核中通过binder_new_node来创建binder_context_mgr_node对象（内部也有service_manager进程相关信息）
    if (binder_become_context_manager(bs)) {
        ALOGE("cannot become context manager (%s)\n", strerror(errno));
        return -1;
    }
    // selinux权限相关检查验证
    selinux_enabled = is_selinux_enabled();
    sehandle = selinux_android_service_context_handle();
    selinux_status_open(true);
    if (selinux_enabled > 0) {
        if (sehandle == NULL) {
            ALOGE("SELinux: Failed to acquire sehandle. Aborting.\n");
            abort();
        }
        // 检索当前进程的context，service_manager_context只能由freecon释放
        if (getcon(&service_manager_context) != 0) {
            ALOGE("SELinux: Failed to acquire service_manager context. Aborting.\n");
            abort();
        }
    }
    union selinux_callback cb;
    cb.func_audit = audit_callback;
    selinux_set_callback(SELINUX_CB_AUDIT, cb);
    cb.func_log = selinux_log_callback;
    selinux_set_callback(SELINUX_CB_LOG, cb);
    // service_manager进程进入无限循环（没有事务处理时会进入阻塞休眠状态）
    // ====> 1.分析无事务时的状况（详见binder_loop无事务逻辑分析）
    // ====> 2.分析有事务需要处理的状况（详见binder_loop事务处理逻辑分析）
    binder_loop(bs, svcmgr_handler);  // svcmgr_handler是ServiceManager的server端具体处理客户端调用的函数的实际调用处
    return 0;
}
```


###### 代码中相关结构体的定义：
* [binder_state](#binder_state_def)
* [binder_write_read](#binder_write_read_def)

###### 代码中相关函数的定义：
* [binder_open](#binder_open_def)
* [binder_become_context_manager](#binder_become_context_manager_def)
* [selinux_android_service_context_handle](#selinux_android_service_context_handle_def)
* [is_selinux_enabled](#is_selinux_enabled_def)
* [selinux_status_open](#selinux_status_open_def)
* [binder_loop](#binder_loop_def)
* [binder_write](#binder_write_def)
* [binder_loop无事务逻辑分析](#binder_loop_def)
* [binder_loop事务处理逻辑分析][5]

【注】：代码中`open`、`ioctl`、`mmap`等系统调用，最后都会调用到binder内核驱动内的代码`binder_open`、`binder_ioctl`、`binder_mmap`相应的函数调用。


--------------
<span id = "binder_state_def">binder_state结构体定义</span>：
```c++
struct binder_state
{
    int fd;
    void *mapped;
    size_t mapsize;
};
```

<span id = "binder_write_read_def">binder_write_read结构体定义</span>：
```c++
struct binder_write_read {
 signed long write_size;
 signed long write_consumed;
 unsigned long write_buffer;
 signed long read_size;
 signed long read_consumed;
 unsigned long read_buffer;
};
```

<span id = "binder_open_def">binder_open函数定义</span>：
```c++
// 传入的mapsize = 128*1024
struct binder_state *binder_open(size_t mapsize)
{
    struct binder_state *bs;
    struct binder_version vers;   // 有一个类型 unsigned int的protocol_version成员
    bs = malloc(sizeof(*bs));
    if (!bs) {
        errno = ENOMEM;
        return NULL;
    }
    // 调用到binder驱动代码中的binder_open函数，该函数会创建一个binder_proc对象(该对象在Binder内核中很重要)
    // binder_proc对象内保存了当前server_manager进程信息等(binder_proc对象在内核进程中)
    bs->fd = open("/dev/binder", O_RDWR);   // 未设置O_NONBLOCK模式，后面service_manager在内核中的binder_thread_read就会进行阻塞
    if (bs->fd < 0) {
        fprintf(stderr,"binder: cannot open device (%s)\n",
                strerror(errno));
        goto fail_open;
    }
     // 向binder驱动层查询binder的内核驱动版本，并对比与用户空间的binder协议版本是否一致
    if ((ioctl(bs->fd, BINDER_VERSION, &vers) == -1) ||
        (vers.protocol_version != BINDER_CURRENT_PROTOCOL_VERSION)) {
        fprintf(stderr,
                "binder: kernel driver version (%d) differs from user space version (%d)\n",
                vers.protocol_version, BINDER_CURRENT_PROTOCOL_VERSION);
        goto fail_open;
    }
    // 需要的内存映射大小128*1024
    bs->mapsize = mapsize;
    // 1.addr参数为NULL表示由内核选择映射的地址
    // 2.length参数表示将要映射文件的offset到offset+length这段内容到进程空间
    // 3.prot参数描述映射的内存的保护方式:pages可被执行/可读/可写/禁止访问
    // 4.flags参数是关于其他进程共同映射同一文件时的更新机制：MAP_PRIVATE表示会创建一个私用的写时拷贝映射，
    //    即此进程对映射内存的修改不会写回到文件，映射该文件的其他进程也看不到此进程的修改
    // 5.fd参数是文件描述符，代表了映射的文件
    // 6.offset参数表示文件开始处偏移量，必须是page的整数倍
    //    内存映射的优点就是：client空间数据拷贝到binder内核后，server因此内存映射，不需要再从binder内核中拷贝数据了
    bs->mapped = mmap(NULL, mapsize, PROT_READ, MAP_PRIVATE, bs->fd, 0);
    // mmap函数执行结束后，会映射binder虚拟设备(128*1024大小的文件内容)到server_manager进程内
    if (bs->mapped == MAP_FAILED) {
        fprintf(stderr,"binder: cannot map device (%s)\n",
                strerror(errno));
        goto fail_map;
    }
    // binder_state对象内的内容是：binder虚拟设备的文件描述符
    //            进程内映射binder设备的内存起始地址
    //            映射的内存大小
    return bs;

fail_map:
    close(bs->fd);
fail_open:
    free(bs);
    return NULL;
}
```

* [binder内核中binder_open函数具体定义][6]


<span id = "binder_become_context_manager_def">binder_become_context_manager函数定义</span>：
```c++
int binder_become_context_manager(struct binder_state *bs)
{
    // 向binder内核驱动层进行类型为BINDER_SET_CONTEXT_MGR的通信，设置当前的server_manager进程为context manager
    //    最终调用到binder驱动层的binder_ioctl_set_ctx_mgr函数；在binder_ioctl_set_ctx_mgr函数内会通过binder_new_node函数
    //    创建一个内核中全局的binder_context_mgr_node对象，binder_new_node函数调用时会将最开始open时在binder内核中产生的
    //    binder_proc对象（内部有service_manager进程相关信息）作为参数最后设置到binder_context_mgr_node对象内
    //    全局的binder_context_mgr_node的对象在client和ServiceManager之间通讯时起重要作用(该对象就是ServiceManager在内核中的Binder实体)
    return ioctl(bs->fd, BINDER_SET_CONTEXT_MGR, 0);
}
```
很多博客中的Binder实体，其实就是server进程相关信息绑定到了binder内核产生的一个struct binder_node对象。

<span id = "binder_loop_def">binder_loop函数定义</span>：
```c++
void binder_loop(struct binder_state *bs, binder_handler func)
{
    int res;
    struct binder_write_read bwr;
    uint32_t readbuf[32];

    bwr.write_size = 0;
    bwr.write_consumed = 0;
    bwr.write_buffer = 0;
    // binder_write函数执行完BC_ENTER_LOOPER命令后，会对内核中的binder_thread类型的looper成员进行或运算
    //    thread->looper |= BINDER_LOOPER_STATE_ENTERED， 即调用完后就设置了thread->looper的状态
    readbuf[0] = BC_ENTER_LOOPER;                   // ====> 详见见下面binder驱动中BC_ENTER_LOOPER内的处理逻辑
    binder_write(bs, readbuf, sizeof(uint32_t));    // ====> 看binder_write函数定义（因read_size=0只会执行binder_thread_write）
    // service_manager进入无限循环
    for (;;) {
        bwr.read_size = sizeof(readbuf);  // 大小32
        bwr.read_consumed = 0;
        bwr.read_buffer = (uintptr_t) readbuf;
        // 因write_size=0，故只会执行binder内核中的binder_thread_read函数
        //  无事务时会阻塞进入休眠状态
        res = ioctl(bs->fd, BINDER_WRITE_READ, &bwr);   // ====> 此处的主要操作逻辑参见下面的binder_thread_read函数分析

        if (res < 0) {
            ALOGE("binder_loop: ioctl failed (%s)\n", strerror(errno));
            break;
        }

        res = binder_parse(bs, 0, (uintptr_t) readbuf, bwr.read_consumed, func);
        if (res == 0) {
            ALOGE("binder_loop: unexpected reply?!\n");
            break;
        }
        if (res < 0) {
            ALOGE("binder_loop: io error %d %s\n", res, strerror(errno));
            break;
        }
    }
}
```



* [BC_ENTER_LOOPER命令类型实际内核中的处理](#BC_ENTER_LOOPER_def)
* [binder_write](#binder_write_def)
* [binder_thread_read函数分析](#binder_thread_read_def)


<span id = "binder_write_def">`binder_write`函数方法定义如下</span>：
```c++
int binder_write(struct binder_state *bs, void *data, size_t len)
{
    // write表示service_manager进程需要写入到binder内核
    // read表示service_manager进程需要从binder内核读出
    struct binder_write_read bwr;
    int res;
    bwr.write_size = len;     // 传递的数据的长度
    bwr.write_consumed = 0;
    bwr.write_buffer = (uintptr_t) data; // 需要向binder内核传送的数据内容
    bwr.read_size = 0;
    bwr.read_consumed = 0;
    bwr.read_buffer = 0;
    // 会调用到binder内核中binder_ioctl
    //  进而调用binder_ioctl_write_read(bs->fd, BINDER_WRITE_READ, &bwr, thread)进入内核操作
    //  因为bwr.read_consumed为0，即不会进入binder内核中binder_thread_read函数进行操作，write后就返回了
    res = ioctl(bs->fd, BINDER_WRITE_READ, &bwr);
    if (res < 0) {
        fprintf(stderr,"binder_write: ioctl failed (%s)\n",
                strerror(errno));
    }
    return res;
}
```

--------------
<span id = "BC_ENTER_LOOPER_def">BC_ENTER_LOOPER命令类型对应到内核空间的处理逻辑</span>：
```c++
// binder内核中binder_thread_write函数的部分处理逻辑
case BC_ENTER_LOOPER:
  binder_debug(BINDER_DEBUG_THREADS,
  	     "%d:%d BC_ENTER_LOOPER\n",
  	     proc->pid, thread->pid);
  // thread->looper在创建后只和BINDER_LOOPER_STATE_NEED_RETURN进行了或运算
  if (thread->looper & BINDER_LOOPER_STATE_REGISTERED) {
  	thread->looper |= BINDER_LOOPER_STATE_INVALID;
  	binder_user_error("%d:%d ERROR: BC_ENTER_LOOPER called after BC_REGISTER_LOOPER\n",
  		proc->pid, thread->pid);
  }
  thread->looper |= BINDER_LOOPER_STATE_ENTERED;
  break;
```


<span id = "binder_thread_read_def">sercice_manager触发的binder_thread_read函数分析</span>：
```c++
static int binder_thread_read(struct binder_proc *proc,
                  struct binder_thread *thread,
                  binder_uintptr_t binder_buffer, size_t size,
                  binder_size_t *consumed, int non_block)
{
    void __user *buffer = (void __user *)(uintptr_t)binder_buffer;
    void __user *ptr = buffer + *consumed;
    void __user *end = buffer + size;
    int ret = 0;
    int wait_for_proc_work;
    if (*consumed == 0) {
        if (put_user(BR_NOOP, (uint32_t __user *)ptr))
            return -EFAULT;
        ptr += sizeof(uint32_t);
    }
retry:
    // service_manager开始时transaction_stack为null以及todo也是空
    // wait_for_proc_work为1，即正处于等待service_manager进程工作中
    wait_for_proc_work = thread->transaction_stack == NULL &&
                list_empty(&thread->todo);
    // 出错后的处理，此时service_manager未做任何事，无error
    if (thread->return_error != BR_OK && ptr < end) {
        if (thread->return_error2 != BR_OK) {
            if (put_user(thread->return_error2, (uint32_t __user *)ptr))
                return -EFAULT;
            ptr += sizeof(uint32_t);
            binder_stat_br(proc, thread, thread->return_error2);
            if (ptr == end)
                goto done;
            thread->return_error2 = BR_OK;
        }
        if (put_user(thread->return_error, (uint32_t __user *)ptr))
            return -EFAULT;
        ptr += sizeof(uint32_t);
        binder_stat_br(proc, thread, thread->return_error);
        thread->return_error = BR_OK;
        goto done;
    }
    // 设置thread->looper状态为等待中
    thread->looper |= BINDER_LOOPER_STATE_WAITING;
    if (wait_for_proc_work)
        proc->ready_threads++;  // service_manager进程内准备好工作的进程又多了一个了
    binder_unlock(__func__);
    trace_binder_wait_for_work(wait_for_proc_work,
                   !!thread->transaction_stack,
                   !list_empty(&thread->todo));
    if (wait_for_proc_work) {   // wait_for_proc_work为1，进入if条件句内
        // 在调用BC_REGISTER_LOOPER或者BC_ENTER_LOOPER前service_manager就进行工作是错的
        if (!(thread->looper & (BINDER_LOOPER_STATE_REGISTERED |
                    BINDER_LOOPER_STATE_ENTERED))) {
            binder_user_error("%d:%d ERROR: Thread waiting for process work before calling BC_REGISTER_LOOPER or BC_ENTER_LOOPER (state %x)\n",
                proc->pid, thread->pid, thread->looper);
            wait_event_interruptible(binder_user_error_wait,
                         binder_stop_on_user_error < 2);
        }
        // 将service_manager进程的优先级别设置为当前线程的优先级别
        binder_set_nice(proc->default_priority);
        if (non_block) {    // 如果是非阻塞模式(service_manager打开/dev/binder时没有设置非阻塞模式)
            if (!binder_has_proc_work(proc, thread))    // 当前无事务处理，即ret被设置成-EAGAIN
                ret = -EAGAIN;
        } else {
            // 如果是阻塞模式，则此线程进入睡眠，等待新事务出现唤醒
            //    （service_manager在open时未设置非阻塞模式，故会线程会进入休眠）
            ret = wait_event_freezable_exclusive(proc->wait, binder_has_proc_work(proc, thread));
        }
    } else {
        if (non_block) {
            if (!binder_has_thread_work(thread))
                ret = -EAGAIN;  //  #define EAGAIN  35   /* Try again */
        } else
            ret = wait_event_freezable(thread->wait, binder_has_thread_work(thread));
    }
    binder_lock(__func__);
    if (wait_for_proc_work)  {
        // 等待的线程都已经算是等待结束（非阻塞直接返回了，阻塞模式下线程到这也是被唤醒了）
        proc->ready_threads--;
    }
    // 去掉thread->looper的BINDER_LOOPER_STATE_WAITING的状态
    thread->looper &= ~BINDER_LOOPER_STATE_WAITING;
    if (ret)
        return ret;
    // 事务的处理逻辑
    。。。
}
```






<span id = "is_selinux_enabled_def">is_selinux_enabled函数定义</span>：
```c++
// 位置：/external/selinux/libselinux/src/enabled.c
int is_selinux_enabled(void)
{
	/* init_selinuxmnt() gets called before this function. We
 	 * will assume that if a selinux file system is mounted, then
 	 * selinux is enabled. */
	return (selinux_mnt ? 1 : 0);
}
```
<span id = "selinux_android_service_context_handle_def">selinux_android_service_context_handle函数定义</span>：
```c++
// 位置：/external/libselinux/src/android.c
struct selabel_handle* selinux_android_service_context_handle(void)
{
    struct selabel_handle* sehandle;

    set_policy_index();
    sehandle = selabel_open(SELABEL_CTX_ANDROID_PROP,
            &seopts_service[policy_index], 1);

    if (!sehandle) {
        selinux_log(SELINUX_ERROR, "%s: Error getting service context handle (%s)\n",
                __FUNCTION__, strerror(errno));
        return NULL;
    }
    selinux_log(SELINUX_INFO, "SELinux: Loaded service_contexts from %s.\n",
            seopts_service[policy_index].value);

    return sehandle;
}
```

<span id = "selinux_status_open_def">selinux_status_open函数定义</span>：
```c++
// 位置:/external/selinux/libselinux/src/sestatus.c
/*
 * selinux_status_open
 *
 * It tries to open and mmap kernel status page (/selinux/status).
 * Since Linux 2.6.37 or later supports this feature, we may run
 * fallback routine using a netlink socket on older kernels, if
 * the supplied `fallback' is not zero.
 * It returns 0 on success, or -1 on error.
 */
int selinux_status_open(int fallback)
{
	int	fd;
	char	path[PATH_MAX];
	long	pagesize;

	if (!selinux_mnt) {
		errno = ENOENT;
		return -1;
	}

	pagesize = sysconf(_SC_PAGESIZE);
	if (pagesize < 0)
		return -1;

	snprintf(path, sizeof(path), "%s/status", selinux_mnt);
	fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		goto error;

	selinux_status = mmap(NULL, pagesize, PROT_READ, MAP_SHARED, fd, 0);
	if (selinux_status == MAP_FAILED) {
		close(fd);
		goto error;
	}
	selinux_status_fd = fd;
	last_seqno = (uint32_t)(-1);

	return 0;

error:
	/*
	 * If caller wants fallback routine, we try to provide
	 * an equivalent functionality using existing netlink
	 * socket, although it needs system call invocation to
	 * receive event notification.
	 */
	if (fallback && avc_netlink_open(0) == 0) {
		union selinux_callback	cb;

		/* register my callbacks */
		cb.func_setenforce = fallback_cb_setenforce;
		selinux_set_callback(SELINUX_CB_SETENFORCE, cb);
		cb.func_policyload = fallback_cb_policyload;
		selinux_set_callback(SELINUX_CB_POLICYLOAD, cb);

		/* mark as fallback mode */
		selinux_status = MAP_FAILED;
		selinux_status_fd = avc_netlink_acquire_fd();
		last_seqno = (uint32_t)(-1);

		fallback_sequence = 0;
		fallback_enforcing = security_getenforce();
		fallback_policyload = 0;

		return 1;
	}
	selinux_status = NULL;

	return -1;
}
```


一些系统函数的基本定义：
[mmap][4]:内存映射文件的方法，可以将文件映射到调用进程的地址空间。















[1]:http://androidxref.com/6.0.1_r10/xref/frameworks/native/cmds/servicemanager/binder.h
[2]:http://androidxref.com/6.0.1_r10/xref/frameworks/native/cmds/servicemanager/binder.c
[3]:http://androidxref.com/6.0.1_r10/xref/frameworks/native/cmds/servicemanager/service_manager.c
[4]:http://man7.org/linux/man-pages/man2/mmap.2.html
[5]:./ServiceManager进程处理事务请求.md
[6]:http://lxr.free-electrons.com/source/drivers/android/binder.c#L2942
