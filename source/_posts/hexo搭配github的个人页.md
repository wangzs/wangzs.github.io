title: Hexo配置博客
date: 2016-03-08 23::15
tag: [Hexo, github]
---

# Hexo配置过程
## 1. 安装node.js
[node.js下载][1]
```
// 配置国内npm源
npm config set registry https://registry.npm.taobao.org
// 查看配置是否成功
npm info express
```

## 2. 安装Hexo
```cmd
npm install hexo-cli -g

npm install hexo --save

// 查看安装的hexo信息
hexo -v
```
<!--more-->

## 3. 配置hexo
```sh
// 找到需要放置的目录，初始化
hexo init
// 在当前目录下执行
npm install

// 安装插件，使用git方式部署
npm install hexo-deployer-git --save
```
* 修改`_config.yml`配置文件：
```file
# 找到deploy模块，修改成下面内容
deploy:
  type: git
  repo: https://github.com/wangzs/wangzs.github.io.git
  branch: master
```

* 本地预览
```sh
hexo s
// 根据输出结果提示，在浏览器中输入http://localhost:4000 进行本地预览
```

## 4. 主题配置
```
// 当前目录继续执行，clone他人的theme到本地themes目录下
git clone -b master https://github.com/iissnan/hexo-theme-next.git themes/next
// 修改_config.yml中
# Extensions
## Plugins: https://hexo.io/plugins/
## Themes: https://hexo.io/themes/
theme: next
// 预览替换theme后的效果
hexo s

// 更新theme（可能此repo主人对此主题做过新的修改）
cd themes/next
git pull origin master 
```
**[主题详细配置][2]**

## 5. 发布到github.io
```sh
hexo g
hexo d
```

## 6. 不同机器上记录
* github上创建分支：master/hexo
* 本地创建hexo目录，并进行上述各种hexo配置等操作
* 当前hexo目录进行如下git操作：
```sh
$ git init
// 添加远程仓库
$ git remote add origin https://github.com/wangzs/wangzs.github.io.git
// 查看远程主机的branch
$ git branch -r
    origin/hexo
    origin/master
// 拉取远程主机某个分支的更新 git pull <远程主机名> <远程分支名>:<本地分支名>  #远程hexo分支与本地的master分支合并
$ git pull origin  hexo:master
// 再推送到远程仓库 git push <远程主机名> <本地分支名>:<远程分支名>
$ git push origin master:hexo
```

-------
## 7. 新增Menu项
* 添加menu item
```
$ hexo new page "libs"
```
* 修改`themes\_config.yml`文件中menu下选项
```
  menu:
    home: /
    ...
    libs: /Libs 
  ```
* 添加对应menu item的icon,自行去[Font-Awesome][4]网站查自己想放的icon
  ```
  menu_icons:
    enable: true
    # Icon Mapping.
    home: home
    ...
    libs: gears   # 添加的新的
  ```
* 修改`themes\next\languages\zh-Hans.yml`中menu部分（根据自己设定的语言添加相应的修改）:
  ```
  menu:
    home: 首页
    ...
    libs: Libs
  ```






-----
** 别人用Hexo搭建博客的相关教程 **
> [Hexo搭建Github博客教程][3]
  [NexT主题配置相关][5]
  [Hexo静态博客搭建教程][6]







[1]:http://nodejs.org/
[2]:http://theme-next.iissnan.com/theme-settings.html
[3]:http://www.selfrebuild.net/2015/06/24/Github-Hexo搭建博客教程/
[4]:http://fortawesome.github.io/Font-Awesome/icons/
[5]:http://zhiho.github.io/2015/09/29/hexo-next/
[6]:http://lovenight.github.io/2015/11/10/Hexo-3-1-1-静态博客搭建指南/
