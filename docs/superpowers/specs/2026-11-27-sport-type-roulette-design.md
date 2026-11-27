# 训练页运动类型轮盘

日期：2026-11-27  
范围：iOS 训练开始页（`StartMapView`）  
状态：设计已对齐，待实现

## 背景

训练页左侧工具栏点「类型」时，当前会拉起底部 `TypeSheet` 列表。目标改为屏幕内弧线轮盘（遮罩 + 可沿弧滚动的类型列表），对齐参考稿与示意图：

- 参考：[`docs/design/visuals/sport-type-roulette-reference.png`](../../design/visuals/sport-type-roulette-reference.png)
- 示意图：[`sport-type-roulette-schematic.jpg`](./sport-type-roulette-schematic.jpg)

「设置」等其它入口的底部浮层保持不变。本次只改 iOS；Android 无对等训练地图 UI，不动。

## 目标

1. 点击「类型」不再拉起底部浮层。
2. 打开全屏半透明遮罩，并在左侧工具栏旁展示弧线轮盘。
3. 轮盘是可上下滚动的类型列表，位移沿圆弧；滚动方向顺着弧线。
4. 每项：圆点内为运动类型图标，右侧为名称。
5. 圆弧水平中线与左侧工具栏水平中线对齐。
6. 交互为中线吸附选中；选中实时写入 `draft.sport`。

## 非目标

- 不改「路线」「组队」「设置」的现有交互。
- 不改 `SportKind` 列表内容与顺序。
- 不做 Android 对等实现。
- 不改开始按钮、底栏、地图本身。

## 交互

| 步骤 | 行为 |
| --- | --- |
| 打开 | 点「类型」→ 遮罩 + 轮盘；当前 `draft.sport` 位于中线并略放大 |
| 拖动 | 手指上下拖，各项沿弧线移动；`scale` / 透明度随相对中线角度连续变化（约 1.0→1.2） |
| 松手 | 弹簧吸附到最近类型；中线项立刻 `draft.sport = …`，工具栏图标同步 |
| 点击非中线项 | 该项丝滑滚到中线（约 0.35–0.45s 弹簧），到达后同样写入 `draft.sport` |
| 关闭 | 点遮罩空白，或再点「类型」→ 关闭轮盘；不回滚已写入的类型 |

选中时机：**滚到中线即生效**（不是关闭时才确认）。

## 布局

- 圆弧圆心在屏幕左侧外；可见段呈 `)` 形，凸向右侧（贴参考稿）。
- 圆弧水平中线 = 左侧工具栏水平中线。工具栏仍由 `StartMapChrome.toolColumnOriginY` 按屏高垂直居中；轮盘中线复用同一水平参考。
- 圆点列紧挨工具栏右侧；名称在圆点右侧。
- 同时约可见 5 项；列表覆盖完整 `SportKind.allCases`，可滚出可视弧段。
- 遮罩盖满地图区域；工具栏、「开始」、底栏在遮罩之上仍可见。「类型」在打开态用于关闭；其它工具按钮是否可点：保持可点（点其它工具时先关轮盘再走原逻辑，避免叠层冲突）。

## 视觉

- 圆点：深色底（贴近 `starryGray`）+ 该类型 `SportKind.symbol`。
- 中线项：`scale ≈ 1.2`，名称字重略强。
- 两侧：随角度缩小，透明度略降；无突跳。
- 无底部 Sheet、无「类型」标题栏、无勾选行样式。

## 组件与数据流

```
StartMapView
  ├─ showSportRoulette: Bool          // 替代 sheet = .type
  ├─ toolColumn / startButton         // 现有
  └─ SportRouletteOverlay             // 新增，打开时叠在地图上
        ├─ 遮罩（点空白关闭）
        ├─ 弧线几何（角度 → 位置 / scale / opacity）
        └─ SportRouletteItem × N      // 图标 + 名称
              └─ 绑定 draft.sport
```

- `StartMapView`：`StartSheet.type` / `TypeSheet` 训练页入口移除；`StartSheet.settings` 与 `StartSettingsSheet` 保留。
- `SportRouletteOverlay`：拥有滚动角偏移、吸附、点击滚入中线；吸附或动画到位后写 `draft.sport`。
- `SportRouletteItem`：展示单个 `SportKind`；视觉量由相对中线的角度驱动，不单独维护选中边框。
- 打开时以当前 `draft.sport` 的索引为初始中线角。
- 工具栏「类型」按钮继续用 `draft.sport.symbol`，实时反映选中。

## 动效

- 拖动：角度偏移跟手；无额外延迟。
- 松手吸附：弹簧动画到最近刻度角。
- 点击滚入：与吸附同一套弹簧参数，目标为被点项的刻度角，时长约 0.35–0.45s。
- `scale` / `opacity`：纯由当前角度插值，不另开独立突变动画，保证「滚动 + 放大」一体丝滑。

## 测试要点

1. 点「类型」出现遮罩轮盘，不出现底部 Sheet。
2. 打开时当前运动类型在中线且偏大。
3. 拖动与点击非中线项均可滚到中线；动画连续、无跳动。
4. 中线变化后 `draft.sport` 与工具栏图标立即一致。
5. 点遮罩或再点「类型」关闭；关闭后类型保持关闭前中线项。
6. 「设置」仍为底部浮层；「路线」「组队」行为不变。
7. 圆弧中线与工具栏中线水平对齐（不同屏高抽查）。

## 实现备注

- 几何：用固定半径与每项角间距；`x = cx + r * cos(θ)`，`y = cy + r * sin(θ)`（或等价参数），`cy` 取工具栏中线。
- 手势：优先 `DragGesture` + 松手速度估算，再弹簧吸附；避免嵌套系统 `ScrollView` 与弧线位置抢手势。
- `TypeSheet`：若无其它引用可删；若仍被测试或预览引用则仅从 `StartMapView` 断开。
