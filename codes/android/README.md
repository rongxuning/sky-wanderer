# sky-wanderer Android

Kotlin、Jetpack Compose、Hilt、Health Connect 的脚手架。页面是占位，没有把 iOS 功能搬过来，也没有服务端接口。

用 Android Studio（带 Android Gradle Plugin 9.4 的当前稳定版）打开 **`codes/android`**，不要把仓库根目录当 Android 工程打开。Studio 会使用已提交的 Gradle Wrapper（Gradle 9.6.0）。本机 JDK 17 或更新即可。第一次 Sync 会下载依赖。`local.properties` 里的 `sdk.dir` 由 Studio 生成，不要提交。

## 和 iOS 的 id

| | id |
| --- | --- |
| Android `applicationId` / namespace | `com.rongxuning.skywanderer` |
| iOS bundle id | `com.rongxuning.sky-wanderer` |

Android 的 `applicationId` 不能带连字符，所以去掉了 iOS id 里的 `-`。两边指的是同一个应用。手表仍是 iOS 工程里的 `com.rongxuning.sky-wanderer.watchkitapp`，不在这个目录。

## 模块

- `:app`：`@HiltAndroidApp`、Compose Navigation。目的地是首页、登录、记录、训练、路线、我。主题色对齐 iOS 的浅色画布（`OmniCanvas` / `OmniCobalt`），字体和图标还是占位。
- `:core`：纯 Kotlin。`SportKind`、`WorkoutRecord` 和距离、配速、时长格式化，对应 `codes/ios/Shared` 里的一小部分。`./gradlew :core:test`。
- `:coros`：COROS 占位。同步走云端 OAuth / Partner API，不是手表应用。这里没有 client id，也没有请求。

`:app` 里 Room、DataStore、Health Connect 只有空实现。Hilt 在进入首页时建好这张图，并打开一个空的本地数据库。界面还不读这些数据。Health Connect 的读取权限写在 Manifest 里，没有授权界面。`minSdk` 是 26。

## 版本

Compose BOM `2026.09.00`（Compose 1.12）和 `androidx.core` 1.19 要求 `compileSdk` 37。`targetSdk` 仍是 36，等确认 API 37 行为后再升。Kotlin 用 2.3.21：AGP 9.4 自带 Kotlin，但当前稳定的 Hilt 2.60.1 还不接受 2.4 的 metadata，KSP 2.3.12 也跟 2.3 编译器走。

这台脚手架没有 Flutter。
