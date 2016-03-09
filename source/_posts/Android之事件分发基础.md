title: Android之事件分发基础
date: 2016-03-08 20:36
tag: Android
---

# Android事件分发
#### 一、三个事件相关函数
* `public boolean dispatchTouchEvent(MotionEvent event)`:
touch事件发生时，会通过该函数一层一层的下发，如一个Activity中有一个ViewGroup，ViewGroup中有一个Button，按到Button时，touch事件先触发activity的`dispatchTouchEvent`再触发ViewGroupp的`dispatchTouchEvent`，然后触发Button的`dispatchTouchEvent`

* `public boolean onInterceptTouchEvent(MotionEvent ev)`（ViewGroup和其子类才有）:
如果上层`dispatchTouchEvent`到该层ViewGroup，此层`onInterceptTouchEvent`返回了true，则会拦截touch事件，下层的ViewGroup或View都不会再触发`dispatchTouchEvent`；
<!--more-->

* `public boolean onTouchEvent(MotionEvent event)`(响应touch事件):
会在相应控件执行`setOnTouchListener`中的onTouch执行结束（且返回值为false）后才执行`onTouchEvent`中的逻辑。

#### 二、执行顺序
|组件|向下执行(false) ↓||向右再上执行(false) ↑||
|---|--|--|--|--|
|Activity|dispatchTouchEvent||onTouchEvent||
|ViewGroup|dispatchTouchEvent → onInterceptTouchEvent|(true)→|(setOnTouchListener)onTouch→onTouchEvent|(true)→stop|
|ViewGroup|dispatchTouchEvent → onInterceptTouchEvent|(true)→|(setOnTouchListener)onTouch→onTouchEvent|(true)→stop|
|View|dispatchTouchEvent|→|(setOnTouchListener)onTouch→onTouchEvent|(true)→stop|
上表中`onTouch`或者`onTouchEvent`两个函数任何函数的返回值为`ture`，都会终止后面的流程。
如果`dispatchTouchEvent `函数的返回值是否为`true`不会停止后面的流程
如果`onInterceptTouchEvent`函数的返回值为`true`，则流程不再向下进行，而是向右再往上进行
