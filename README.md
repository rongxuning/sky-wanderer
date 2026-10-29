# sky-wanderer

iPhone 和 Apple Watch 上的徒步、跑步应用。用 Xcode 16 或更新版本打开 `codes/ios/sky-wanderer.xcodeproj`。部署目标是 iOS 26 和 watchOS 10。

## 目录

- `codes/ios`：iPhone、Apple Watch 和共用代码
- `codes/web`：Web 端
- `codes/core`：Go HTTP 网关（健康检查、登录路由；运动和轨迹的扩展点）
- `codes/user`：登录与账号（手机号、微信、Google）
- `codes/analytics`：数据分析与 AI（本阶段只有说明）
- `deploy`：发布流程和脚本
- `docs/planning`、`docs/proposals`、`docs/design`：规划、方案、设计

这台开发环境不能编译 Apple 平台，仓库里的工程没有在这里跑过构建。请在 Mac 上用 Xcode 编译 iPhone 和 Watch 两个 scheme。签名时选自己的开发团队。HealthKit 能力要在开发者账号里打开；仓库里的 entitlements 只是占位，没有密钥。

Bundle ID：`com.rongxuning.sky-wanderer`，手表是 `com.rongxuning.sky-wanderer.watchkitapp`。

推到 `main` 且改动 `codes/ios/**` 时，GitHub Actions 会归档并上传 TestFlight。第一次成功运行前，需要仓库管理员按 [docs/ci-testflight.md](docs/ci-testflight.md) 配好签名和 App Store Connect 的 secrets。工作流不会把构建号提交回仓库。

## 真实和模拟

真实路径：HealthKit 授权后读取心率、睡眠、步数，并记录徒步和跑步；地图用 MapKit 和系统定位。手机号、微信、Google 默认请求 `https://api.sky-wanderer.online`：短信验证码、微信授权码和 Google ID token 都在服务端核对。同一个身份再次登录回到同一个用户；把已经属于别人的身份绑过来时，合并进更早创建的账号。服务在 `codes/core` 和 `codes/user`，部署说明在 [docs/deploy-sky.md](docs/deploy-sky.md)。临时环境是 Vercel + Neon；同机 `/opt/sky-wanderer` 暂缓。`Config/Sky.xcconfig` 里的 `SKY_API_BASE_URL` 可以改成 Vercel 域名；留空或把 `SKY_AUTH_DEMO` 设为 `1` 时，仍用本机目录 `codes/ios/Shared/AccountIdentity.swift`。登录页调用 `PhoneAppState` 上的 `signInPhone`、`signInWeChat`、`signInGoogle`。

iPhone 必须登录后才能进入首页。未登录只显示全屏登录页，不能关掉它继续使用。退出登录会立刻回到这页。会话写在本机 `phone.json`，同时把 session token 和账号标识放进 Keychain。冷启动时先读这两处，再决定进首页还是登录页。

模拟路径：没有 HealthKit 或锻炼启动失败时，运动数据在本机生成，界面会写「本地模拟」。组队没有服务器，`LocalTeammateSimulator` 按 `TeammateSync` 在本机移动示例队友。账号服务地址为空或打开 `SKY_AUTH_DEMO` 时，手机号不发短信，验证页给出演示验证码 `SKY-LOCAL`；微信和 Google 用本机占位身份。密码重置仍使用演示码 `OMNI-LOCAL`，登录页不再进入注册、忘记密码或重置密码。社交示例帖和示例训练记录是本地种子数据。手表和手机的记录各自存在本机，没有同步。手表上的社交、组队、我、周/月/年统计是更短的一版，没有手机上的密图表。

训练负荷、体能储备、休息建议的公式在 `Shared/TrainingEstimate.swift`。图表 Z1–Z5 的分界在 `Shared/ZoneScale.swift`，只用于着色，不是医疗标准。
