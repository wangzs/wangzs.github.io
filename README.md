# wangzs.github.io
存放blog的原始markdown内容

## 使用
* 其它电脑上只同步markdown文件（当然也可以配置hexo，然后pull该分支到本地，再提交md内容以及发布blog）
* 由自己笔记本同意发布blog
  ```
  $ git pull origin hexo:master  将远程hexo分支同步到本地）
  // 本地有添加新的md文件则再提交本地修改到hexo分支
  $ git push origin master:hexo
  
  // 生产并发布内容到远程master(_config.yml中配置的)
  $ hexo g
  $ hexo d
  ```
