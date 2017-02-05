title:  Framework之APK启动分析
date: 2016-06-18 18:14
tag: [Android, Framework]
---

因普通apk的启动都是通过点击桌面相应的图标进行的，点击桌面图标的行为即是触发了Launcher的相应操作，首先分析Launcher的启动流程，再分析如何由Launcher中图标的点击启动其他APK的流程。

# [Launcher][1]启动
Launcher也是一个Activity，其布局文件为`launcher.xml`（可以[下载][3]对应源码）
TODO

# 普通APK的启动
由[Framework的漫漫长路](http://wangzs.github.io/2016/06/01/Framework的漫漫长路)这篇文章中`一窥了APK的main activity的启动过程`部分的内容可知，[startProcessLocked函数][2]内有`Process.start()`会启动新的process，并触发ActivityThread的main调用的流程；
## 1. 点击Launcher中显示的icon
当点击桌面上某个apk的图标时，触发的[逻辑代码][4]如下：
```java
// Open shortcut
final Intent intent = ((ShortcutInfo) tag).intent;
int[] pos = new int[2];
v.getLocationOnScreen(pos);
intent.setSourceBounds(new Rect(pos[0], pos[1],
pos[0] + v.getWidth(), pos[1] + v.getHeight()));
boolean success = startActivitySafely(v, intent, tag);
```




可以参考的文章

http://gityuan.com/2016/03/26/app-process-create/

http://blog.csdn.net/luoshengyang/article/details/6689748










[1]: http://androidxref.com/6.0.1_r10/xref/packages/apps/Launcher3/src/com/android/launcher3/Launcher.java#Launcher
[2]: http://androidxref.com/6.0.1_r10/xref/frameworks/base/services/core/java/com/android/server/am/ActivityManagerService.java#3247
[3]: https://android.googlesource.com/platform/packages/apps/Launcher3/
[4]: http://androidxref.com/6.0.1_r10/xref/packages/apps/Launcher3/src/com/android/launcher3/Launcher.java#onClick