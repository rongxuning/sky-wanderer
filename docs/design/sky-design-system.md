# Sky 设计系统

版本 1.0.0。这一版只定义浅色界面（light-first）。

本文给人读。同目录的 [`tokens.json`](tokens.json) 给以后的 Android 和其他客户端读。两处的色值和数字保持一致。

这一份只写规范和 token。不新增 `SkyTheme.swift`，也不改现有 SwiftUI 页面。

## 1. 品牌

Sky 是户外运动数据应用。信息结构参考 Strava：运动动态、活动卡片、一眼能读的指标、地图和轨迹。品牌主色取自 Sky 机器人图标上的亮蓝 `#1E88FE`。

一句话：**Sky = 户外运动数据应用；Strava 的结构 + Sky 蓝。**

## 2. 颜色

新界面只用下表。主色是品牌蓝，不是多套页面点缀色。

| Token | Hex | 用途 |
| --- | --- | --- |
| `primary` | `#1E88FE` | 主按钮、选中的标签、链接、进度环、轨迹描边 |
| `primaryPressed` | `#1C7DEA` | 按下态。`primary` 的 R/G/B 各乘 0.92，约暗 8% |
| `background` | `#FFFFFF` | 页面底 |
| `grouped` | `#F5F5F7` | 分组列表、统计区底 |
| `card` | `#FFFFFF` | 卡片底 |
| `cardBorder` | `#E4F1FF` | 卡片描边。白底叠约 12% 的 `primary`。也可以改用下面的单层阴影 |
| `ink` | `#1C1C1E` | 主文字、标签 |
| `secondary` | `#8E8E93` | 次要文字、未选中的标签 |
| `tertiary` | `#C6C6C8` | 更弱的说明。分隔线与此同色，token 名 `separator` |
| `success` | `#34C759` | 完成、正向状态 |
| `warning` | `#FF9500` | 需要注意 |
| `danger` | `#FF3B30` | 破坏性操作、错误 |
| `onPrimary` | `#FFFFFF` | 铺在 `primary` 上的文字和图标 |
| `chartTrack` | `#1E88FE` | 轨迹、配速主线，等于 `primary` |
| `chartNeutral` | `#8E8E93` | 图表中性灰 |
| `chartNeutralMuted` | `#C6C6C8` | 图表第二条中性灰 |

图表的中性系列仍只用 `primary` 再加一到两条中性灰。记录列表和记录详情的指标另用下面的指标色，不另起一套页面色板。

### 运动指标色

记录列表和记录详情共用。数字和单位同一字重（Bold）、同一颜色。标签用 Caption，颜色 `secondary`。没有数值时用「—」，颜色 `secondary`，不用彩色的 0。

| Token | Hex | 用途 |
| --- | --- | --- |
| `metric.duration` | `#A16207` | 训练时间、经过时间、列表里的时长 |
| `metric.distance` | `#0277BD` | 距离。必须和 `primary` `#1E88FE` 分开 |
| `metric.pace` | `#0B7F7A` | 配速、步频、步幅 |
| `metric.heartRate` | `#D13924` | 心率。分段里变慢的箭头也用它 |
| `metric.elevation` | `#15803D` | 爬升、海拔。分段里变快的箭头也用它 |
| `metric.energy` | `#C2183B` | 能量 |
| `metric.load` | `#6D28D9` | 训练负荷 |
| `metric.score` | `#1E88FE` | 训练评分，等于 `primary` |

### 区间色

心率区间和配速区间共用，从易到难。浅色底上要能读清。分界仍是 `ZoneScale` 里已有的草稿（心率按 190 次/分的百分比，配速按固定的秒/公里），不把某一次运动的截图数字写死。

| Token | Hex | 名称 |
| --- | --- | --- |
| `zone.base` | `#1E88FE` | 有氧基础 |
| `zone.endurance` | `#15803D` | 有氧耐力 |
| `zone.threshold` | `#A16207` | 乳酸阈值 |
| `zone.speed` | `#C2410C` | 速度耐力 |
| `zone.sprint` | `#D13924` | 冲刺能力 |

卡片二选一：`cardBorder` 的极浅蓝边，或第 5 节的单层柔和阴影。不要又描边又叠多层阴影。

### 新界面停用的旧色

下面这些颜色留在现有代码里，等对应页面迁走后再删。新界面不要引用：

- `SkyHomeColor` 的多色点缀：`train`、`record`、`route`、`social`、`me`。首页和页轮目前给每一页一种颜色。
- `Color` 上的 `omni*`：`omniCanvas`、`omniIce`、`omniCobalt`、`omniDeep`、`omniInk`、`omniCoral`、`omniMuted`、`omniIdle`。其中包括珊瑚 `omniCoral` 和冰蓝 `omniIce`。
- 登录页的天空铺底：`LoginColor`、`LoginWash`、`LoginSkyBackground` 的全屏蓝色呼吸渐变，以及 `CanvasBackground` 在白底上呼吸的冰色晕染。它们只属于现有登录页，不能当作普通页面的背景。

## 3. 字体

字体是 SF Pro，并跟随系统 Dynamic Type。下表是默认字号（pt）。

| 样式 | 字号 | 字重 | 用途 |
| --- | --- | --- | --- |
| Large Title | 34 | Bold | 大指标、个人页名字 |
| Title | 28 | Bold | 少用的屏幕标题 |
| Title2 | 22 | Bold | 卡片标题 |
| Title3 | 20 | Semibold | 分区标题 |
| Headline | 17 | Semibold | 列表主行 |
| Body | 17 | Regular | 正文 |
| Callout | 16 | Regular | 稍强调的说明 |
| Subheadline | 15 | Regular | 辅助说明 |
| Footnote | 13 | Regular | 时间、单位 |
| Caption | 12 | Regular | 徽章、图例 |

未上色的指标：数字与所在层级同字号，字重用 Semibold 或 Bold；单位用 Footnote，颜色用 `secondary`。

记录列表和记录详情里用了指标色的数字：数字和单位同一字号、同一字重（Bold），颜色用上一节的指标色。标签仍是 Caption、`secondary`。

## 4. 间距

8pt 网格。刻度只有：4、8、12、16、24、32。

| 用途 | 值 |
| --- | --- |
| 屏幕左右边距 | 16 |
| 卡片内边距 | 16 |
| 列表行高度 | 约 52–64 |
| 相关元素间距 | 8 |
| 分区间距 | 24 |
| 最小可点区域 | 44×44 |
| 控件间距 | 至少 8 |

## 5. 圆角与阴影

| 对象 | 值 |
| --- | --- |
| 按钮、芯片 | Capsule，或圆角 12 |
| 卡片 | 16，continuous |
| 面板、sheet | 20–24。token 取 24 |
| 阴影 | 只一层。黑色透明度 8%–12%，y 偏移 4–8，模糊半径 12–16 |

`tokens.json` 里的卡片阴影取这个区间的中值：黑色、透明度 0.1、y 为 6、半径 14。不要做多层 elevation。

## 6. 组件

### 主按钮

填充 `primary`，文字 `onPrimary`。高度至少 44，形状 Capsule。一个屏幕只有一个主操作。

### 次按钮

`primary` 描边，或安静的灰色填充。文字按钮的文字色用 `primary`。

### 标签栏

用系统 Tab Bar。选中为 `primary`，未选中为 `secondary`。最多 5 项。

### 导航栏

白底或系统材质。适合大标题的页面用 Large Title。保留边缘滑动返回。

### 活动 / 动态卡片

白底，圆角 16。上方是头像、名字、时间。中间是轨迹缩略图或地图。下方是指标行：距离、配速、时长。数字 Bold，单位 Caption。

### 列表行

左侧图标或缩略图，主行 Headline，副行 Footnote，右侧 chevron。分隔线用 `tertiary`。

### 统计块

大数字加小单位。两列或三列，放在 `grouped` 背景上。

### 地图

通栏。浮动控件是白色圆形按钮。轨迹描边用 `primary`。

### 空状态

一句话，加一个主按钮。

### 不要这样做

- 为单个页面另写一套色板。
- 给页轮的每一页指定不同强调色。
- 使用 `omniCoral`、`omniIce` 以及其余 `omni*`。
- 把全屏呼吸渐变当作普通页面的背景。

## 7. 代码约定

这些约定从下一份实现开始生效。本文件不附带 Swift 代码。

- 新界面只使用 `SkyTheme.*`。`SkyTheme` 将在后续改动里新增，这一份不创建 `SkyTheme.swift`。
- 旧色板（`SkyHomeColor`、`omni*`、`LoginColor` 及登录天空渐变）保留到对应页面迁完，再删除。
- Android 以后直接消费 `docs/design/tokens.json`，不要在客户端里另抄一份色值。

## 8. 这一份不做

- 不新增 SwiftUI 主题文件。
- 不改现有页面的样式、导航或配色。
- 不删除现有颜色枚举。
