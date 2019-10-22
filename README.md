# MJKLoadMethodTrace.h/.m 尽量放在动态库中

具体做法: 在Xcode工程中新建一个 Target，类型为 Framework，取名 LoadHook，并且保证 LoadHook 是 Target 中除了主 app 外最靠前的一个（如果不是，可以通过拖动到第二个）。
把MJKLoadMethodTrace.h/.m拖入到LoadHook中，之后编译LoadHook
