title: ServiceManager事务处理逻辑分析
date: 2016-05-01  00:15
tag: [Android, Binder, ServiceManager]
---

# ServiceManager事务处理逻辑分析
主要涉及代码：
[service_manager][1]
[binder.h][2]
[binder.c][3]
[内核中的binder.c][4]

<!-- more -->

ServiceManager处理事务都是在其进程执行binder_loop后：
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



ServiceManager的事务都是由其它client向binder内核发出请求后，binder内核在处理完client的ioctl的请求后，唤醒ServiceManager在启动时进入睡眠的线程，继续执行`binder_thread_read`阻塞后面的代码。
ServiceManager需要处理的事务主要就是为client提供其它服务的binder的引用。

`binder_thread_read`函数的事务处理分析：
ServiceManager的todo列表中类型：
* addService时： BINDER_WORK_TRANSACTION
* getService时： 


## addService时功能分析
```c++
while (1) {
    ...
    BUG_ON(t->buffer == NULL);
    // 1.注册服务时，该target_node即是ServiceManager的binder实体
    if (t->buffer->target_node) {
        // 取出相应server在内核中的binder实体
        struct binder_node *target_node = t->buffer->target_node;

        tr.target.ptr = target_node->ptr;
        tr.cookie =  target_node->cookie;
        t->saved_priority = task_nice(current);
        if (t->priority < target_node->min_priority &&
            !(t->flags & TF_ONE_WAY))
            binder_set_nice(t->priority);
        else if (!(t->flags & TF_ONE_WAY) ||
             t->saved_priority > target_node->min_priority)
            binder_set_nice(target_node->min_priority);
        cmd = BR_TRANSACTION;
    } else {
        tr.target.ptr = 0;
        tr.cookie = 0;
        cmd = BR_REPLY;
    }
    tr.code = t->code;
    tr.flags = t->flags;
    tr.sender_euid = from_kuid(current_user_ns(), t->sender_euid);

    if (t->from) {
        struct task_struct *sender = t->from->proc->tsk;

        tr.sender_pid = task_tgid_nr_ns(sender,
                        task_active_pid_ns(current));
    } else {
        tr.sender_pid = 0;
    }

    tr.data_size = t->buffer->data_size;
    tr.offsets_size = t->buffer->offsets_size;
    tr.data.ptr.buffer = (binder_uintptr_t)(
                (uintptr_t)t->buffer->data +
                proc->user_buffer_offset);
    tr.data.ptr.offsets = tr.data.ptr.buffer +
                ALIGN(t->buffer->data_size,
                    sizeof(void *));

    if (put_user(cmd, (uint32_t __user *)ptr))
        return -EFAULT;
    ptr += sizeof(uint32_t);
    if (copy_to_user(ptr, &tr, sizeof(tr)))
        return -EFAULT;
    ptr += sizeof(tr);
    // ====> 注册服务时，上面部分就想到通过内核与ServiceManager的共享内存区域，将添加服务的事务数据传到了ServiceManager进程中

    list_del(&t->work.entry);
    t->buffer->allow_user_free = 1;
    if (cmd == BR_TRANSACTION && !(t->flags & TF_ONE_WAY)) {
        // 注册服务时，注册的服务进程需要注册这个事务执行结束的返回，所以此处将事务再挂在ServiceManager的事务堆栈中
        t->to_parent = thread->transaction_stack;
        t->to_thread = thread;
        thread->transaction_stack = t;
    } else {
        t->buffer->transaction = NULL;
        kfree(t);
        binder_stats_deleted(BINDER_STAT_TRANSACTION);
    }
    break;
}
```

* 注册服务的事务数据传到ServiceManager进程后，会进入ServiceManager的`binder_loop`中的`binder_parse`函数中：
addService时cmd为BR_TRANSACTION
```c++
// 
int binder_parse(struct binder_state *bs, struct binder_io *bio,
                 uintptr_t ptr, size_t size, binder_handler func)
{
    int r = 1;
    uintptr_t end = ptr + (uintptr_t) size;

    while (ptr < end) {
        uint32_t cmd = *(uint32_t *) ptr;
        ptr += sizeof(uint32_t);
#if TRACE
        fprintf(stderr,"%s:\n", cmd_name(cmd));
#endif
        switch(cmd) {
        case BR_NOOP:
            break;
        case BR_TRANSACTION_COMPLETE:
            break;
        ...
        case BR_TRANSACTION: {
            struct binder_transaction_data *txn = (struct binder_transaction_data *) ptr;
            if ((end - ptr) < sizeof(*txn)) {
                ALOGE("parse: txn too small!\n");
                return -1;
            }
            binder_dump_txn(txn);
            if (func) {
                unsigned rdata[256/4];
                struct binder_io msg;
                struct binder_io reply;
                int res;

                bio_init(&reply, rdata, sizeof(rdata), 4);
                bio_init_from_txn(&msg, txn);   // 将内核与ServiceManager的共享内存中数据msg拷贝到txn中
                res = func(bs, txn, &msg, &reply);  // func实际指向的是ServiceManager中的svcmgr_handler函数
                binder_send_reply(bs, &reply, txn->data.ptr.buffer, res); 
            }
            ptr += sizeof(*txn);
            break;
        }
        ...
}
```

* svcmgr_handler处理客户端的addService请求
```c++
int svcmgr_handler(struct binder_state *bs,
                   struct binder_transaction_data *txn,
                   struct binder_io *msg,
                   struct binder_io *reply)
{
    struct svcinfo *si;
    uint16_t *s;
    size_t len;
    uint32_t handle;
    uint32_t strict_policy;
    int allow_isolated;
    if (txn->target.ptr != BINDER_SERVICE_MANAGER)
        return -1;

    if (txn->code == PING_TRANSACTION)
        return 0;

    // Equivalent to Parcel::enforceInterface(), reading the RPC
    // header with the strict mode policy mask and the interface name.
    // Note that we ignore the strict_policy and don't propagate it
    // further (since we do no outbound RPCs anyway).
    strict_policy = bio_get_uint32(msg);
    s = bio_get_string16(msg, &len);      // "android.os.IServiceManager"
    if (s == NULL) {
        return -1;
    }
    // svcmgr_id等同"android.os.IServiceManager"
    // 其中sizeof(svcmgr_id) = 52  类型是16位的uint_16
    if ((len != (sizeof(svcmgr_id) / 2)) ||
        memcmp(svcmgr_id, s, sizeof(svcmgr_id))) {
        fprintf(stderr,"invalid id %s\n", str8(s, len));
        return -1;
    }
    // code对应了客户端调用的是ServiceManager的什么函数接口
    switch(txn->code) {
    case SVC_MGR_GET_SERVICE:
    case SVC_MGR_CHECK_SERVICE:
        s = bio_get_string16(msg, &len);
        if (s == NULL) {
            return -1;
        }
        handle = do_find_service(bs, s, len, txn->sender_euid, txn->sender_pid);
        if (!handle)
            break;
        bio_put_ref(reply, handle);
        return 0;

    case SVC_MGR_ADD_SERVICE: // client调用了addService接口
        s = bio_get_string16(msg, &len);  // 获取client传入的name
        if (s == NULL) {
            return -1;
        }
        handle = bio_get_ref(msg);        // 获取传入的client的服务的binder的handler
        allow_isolated = bio_get_uint32(msg) ? 1 : 0;
        // ====> 添加服务到ServiceManager中的一个struct svcinfo链表结构类型成员svclist的首部
        if (do_add_service(bs, s, len, handle, txn->sender_euid,
            allow_isolated, txn->sender_pid))
            return -1;
        break;
        ...
    }

    bio_put_uint32(reply, 0);
    return 0;
}
```

** 添加完服务后，还要回到内核中清理addService中创建的事务相关对象的内存 **













[1]:http://androidxref.com/6.0.1_r10/xref/frameworks/native/cmds/servicemanager/service_manager.c
[2]:http://androidxref.com/6.0.1_r10/xref/frameworks/native/cmds/servicemanager/binder.h
[3]:http://androidxref.com/6.0.1_r10/xref/frameworks/native/cmds/servicemanager/binder.c
[4]:http://lxr.free-electrons.com/source/drivers/android/binder.c
