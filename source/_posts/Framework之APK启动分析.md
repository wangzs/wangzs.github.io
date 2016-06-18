title:  Framework之APK启动分析
date: 2016-06-18 18:14
tag: [Android, Framework]
---

# TODO

由[Framework的漫漫长路](http://wangzs.github.io/2016/06/01/Framework的漫漫长路)这篇文章中`一窥APK的main activity的启动过程`部分的内容可知，[startProcessLocked函数][1]内有`Process.start()`会启动新的process，并触发ActivityThread的main调用的流程；





[可以参考的文章](http://gityuan.com/2016/03/26/app-process-create/)









[1]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/services/core/java/com/android/server/am/ActivityManagerService.java#3247