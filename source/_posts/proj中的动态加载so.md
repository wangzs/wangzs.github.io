title:  动态加载so
date: 2016-07-19 00:01
tag: [Android, 项目Log]
---

# 简介
在xx项目中，因为用到了一个直播库（主要使用它的语音功能）。整个库有多个so，将所有so直接放到项目中，会使得APK包直接大了6~7M，比以前的apk包大了差不多一倍，所以就有了需要将语音功能以插件形式提供给用户，让想使用语音功能的用户去下载这些so，这样apk本身就不会增长太大。

# 思路
1. 因为有多个so文件，所以要将这些so打包成zip文件并传到CDN；
2. 客户端下载打包了的zip文件（校验MD5）；
3. 解压zip文件；
4. 拷贝所有的so文件到`/data/data/project_directory/app_lib`中；
5. 加载so，初始化库，使用库功能

# 具体步骤
## 打包so文件
使用7zip工具，将6个so文件打包压缩，并上传到公司的CDN上；计算打包后文件的MD5值，用于代码中对下载的zip包的校验。

## 客户端的下载、校验和解压
### 下载
可以写http下载，也可以用第三方开源库，此处用的是[FileDownloader](https://github.com/lingochamp/FileDownloader)
### MD5校验
因为手机的内存资源有限，而zip包文件也比较大，所以计算MD5是不断读入数据流，更新`MessageDigest`对象，最终算出zip包的MD5值：
```java
String getMd5(File zipSoFile) {
  // 计算zip文件md5的值
  String md5Str = null;
  try {
    FileInputStream fileInputStream = new FileInputStream(zipSoFile);
    MessageDigest messageDigest = MessageDigest.getInstance("MD5");
    byte[] buffer = new byte[8192];	// 每次读1kB数据
    int readNumber;
    while ((readNumber = fileInputStream.read(buffer)) > 0) {
      messageDigest.update(buffer, 0, readNumber);
    }
    byte[] digestValue = messageDigest.digest();
    md5Str = String.format("%032x", new BigInteger(1, digestValue)); 
  } catch (Exception e) {
    e.printStackTrace();
  }
  return md5Str;
}
// 对比存储的originMd5与md5Str做对比
StringUtils.equalsIgnoreCase(md5Str, originMd5);
```
### zip文件解压
使用java本身提供的zip工具类即可，也可以使用apache提供的zip工具类。

## 拷贝so
利用Application对象的`getDir('lib', Context.MODE_PRIVATE)`函数无法获取到`/data/data/lib`，实际获取到的是`/data/data/app_lib`，该目录不存在时，自动创建，所以最后拷贝so文件到了`/data/data/app_lib`目录下。

## 加载so
so的加载直接调用函数`System.load(soAbsolutePath)`函数，因为`System.loadLibrary("myso")`函数会从系统lib路径中查找名为`libmyso.so`的文件，所以此处加载so是调用`System.load`函数，直接传入so的绝对路径，进行加载。

# 部分实现代码
* 管理so压缩文件下载、校验、解压缩和自动加载so
```java
public class XxSoLoaderManager {
    private static XxSoLoaderManager ourInstance = new XxSoLoaderManager();

    public static XxSoLoaderManager getInstance() {
        return ourInstance;
    }

    private XxSoLoaderManager() {
    }

    /**
     * 0-未查询 或 查询结果不完整 或 查询出错
     * 1-app_lib目录中有所有的so
     * 2-当前已经加载了so
     */
    private int mSoStatus = 0;
    private String mSoLibName = "lib";
    private String mZipFileMd5 = "md5计算工具得到的zip文件的md5";
    private String mZipFileName = "xx_zip_so.file";
    private String mDownloadUrl = "http://xxx_zip_file.download.url.path";

    private String[] mNeedLoadSo = {
            "libxxx0.so",
            "libxxx1.so",
            "libxxx2.so",
            "libxxx3.so",
            "libxxx4.so",
            "libxxx5.so"
    };
	// 初始化，如果已经下载了zip包或者so已在app_lib中，动态加载这些so
    public void init() {
        if (mSoStatus == 0) {
            Observable.create(new Observable.OnSubscribe<Boolean>() {
                @Override
                public void call(Subscriber<? super Boolean> subscriber) {
                    if (existSoInLib() || unzipSoToLibs()) {
                        subscriber.onNext(true);
                    } else {
                        subscriber.onNext(false);
                    }
                }
            }).subscribeOn(Schedulers.io())
              .observeOn(AndroidSchedulers.mainThread())
              .subscribe(needLoad -> {
                if (needLoad) {
                  loadSo();
                }
              }, Throwable::printStackTrace);
        }
    }
    
    // 是否已经加载so到内存
    public boolean isLoadedSo() {
        return mSoStatus == 2;
    }
    // 动态加载so
    private void loadSo() {
    	// App.get()得到的Application对象
        File libFile = App.get().getDir(mSoLibName, Context.MODE_PRIVATE);
        try {
            for (String soName : mNeedLoadSo) {
                String soAbsolutePath = new File(libFile, soName).getAbsolutePath();
                System.load(soAbsolutePath);
            }
            mSoStatus = 2;
        } catch (UnsatisfiedLinkError e) {
            // 无法加载so，禁用语音
            forbidUseVoice();
        }
    }
    // 判断/data/data/xx.yy.zz/app_lib中是否已经存在所有需要下载的so文件
    private boolean existSoInLib() {
        if (mSoStatus == 0) {
            File libFile = App.get().getDir(mSoLibName, Context.MODE_PRIVATE);
            final String[] allSo = libFile.list();
            int loadSoNum = mNeedLoadSo.length;
            if (allSo == null || allSo.length < loadSoNum) {
                return false;
            }
            for (String oneSo : allSo) {
                for (String aDynamicLoadSo : mNeedLoadSo) {
                    if (aDynamicLoadSo.contains(oneSo)) {
                        loadSoNum--;
                        break;
                    }
                }
            }
            if (loadSoNum == 0) {
                mSoStatus = 1;
            }
            return loadSoNum == 0;
        } else {
            return true;
        }
    }
    /**
     * 解压下载的so的zip包
     */
    private boolean unzipSoToLibs() {
        try {
            String libPath = App.get().getDir(mSoLibName,
            						Context.MODE_PRIVATE).getAbsolutePath();
            // 获取sdcard中xx目录
            File zipFilePath = FileUtil.getXXExternalDirectory();
            File zipFile = new File(zipFilePath, mZipFileName);
            if (zipFile.exists()		// 存在此mZipFileName的File
                    && zipFile.isFile()	// mZipFileName是文件（以上两个表示已经下载过so的zip文件）
                    && FileUtil.checkFileMd5(zipFile, mZipFileMd5)) {	// 校验MD5
                // 利用解压工具解压zip文件到/data/data/xxx.yyy/app_lib目录下
                ZipUtil.unzip(zipFile.getAbsolutePath(), libPath, false);
                mSoStatus = 1;
                return true;
            }
        } catch (Exception e) {
            StatisticWorkFlow.reportHjyVoice("unzip_so_failure");
            e.printStackTrace();
        }
        return false;
    }
     // 是否需要下载so：只有sdcard的xx目录中没有so的压缩包并且app_lib目录中也没有对应so
    public boolean isNeedDownloadSo() {
        return !hasZipSo() && !existSoInLib();
    }
    // 外部存储是否存在so的zip包
    private boolean hasZipSo() {
        File zipFilePath = FileUtil.getXXExternalDirectory();
        File zipFile = new File(zipFilePath, mZipFileName);
        return zipFile.exists()
                && zipFile.isFile()
                && FileUtil.checkFileMd5(zipFile, mZipFileMd5);
    }
    // zip文件下载
    public void downloadZipSo(){
    	// 省略，需要注意下载进度、下载完成时自动load so等
    }
```
动态加载so成功后，就可以进行库的实际初始化相关逻辑了。

实际项目中，动态加载了so后，仍然有其他的坑，一个坑是jar包中仍然调用了`System.loadLibrary`的方法，而实际lib目录中没有相应的so， 还好是公司内的库，在内部的仓库中找到了java部分的源代码，替换jar包，屏蔽所有`System.loadLibrary`的调用。另一个大坑是某个so内部某个xx方法调用了`System.loadLibrary`的函数，而该方法最后在java层调用，尝试过两种方法，最终用通过替换已载入内存中so的lib字符串为app_lib方法解决了（替换也可能有风险，因为修改了lib字符串起始位置起+后面四位的内存，幸运后四位内存修改没对其他部分逻辑有影响）。

