# 货物入库扫描 App — Spec & Plan

代号 `GoodsScanner`，中文名「入库量方」。调研见 [research.md](research.md)。

## 1. 范围

**做：** 单台 iPhone 离线使用的入库登记工具。
- 客户管理：名称、客户代码（唯一）、联系人、电话、地址、备注。
- 入库单：客户、入库时间、操作员、备注，含多件货物。
- 货物（每件/每批同规格）：长宽高(cm)、件数、重量(kg，选填)、品名/备注、照片(≥0 张)、测量方式(LiDAR/手动)、测量置信度。体积自动算(m³)。
- LiDAR 扫描量方 + 实时 3D 线框 + 拍照；无 LiDAR / 模拟器自动降级为手动录入 + 系统相机拍照。
- 报表：按日期区间 + 客户筛选；汇总(单数/件数/总体积/总重量)；导出 CSV 明细、PDF 报表(含缩略图)、照片 ZIP，走系统分享。

**不做（YAGNI，需要时再加）：** 多设备同步/云后端、登录权限、出库/库位/库存余额、条码打印、真 xlsx。

## 2. 架构决策（不得改动，除非回到本文件修订）

| # | 决策 | 理由 |
|---|---|---|
| A1 | 原生 SwiftUI，iOS 17.0+，**Swift 5 语言模式**（避免 ARKit/SwiftData 严格并发耗时），竖屏锁定，**零第三方依赖** | LiDAR 只能原生；SwiftData 需 17 |
| A2 | 工程由 XcodeGen `project.yml` 生成，`.xcodeproj` 不入库 | 可复现、无冲突 |
| A3 | 测量算法放本地 SPM 包 `Packages/BoxMeasureKit`（纯 Swift + simd，无 ARKit 依赖），`swift test` 在 macOS 上直接跑 | 核心算法可快速单测，与 UI 解耦 |
| A4 | ARKit 采集（深度→世界点云）放 App 内 `Scan/`，只负责把 `[SIMD3<Float>]` + 种子点交给 BoxMeasureKit | ARKit 不可在 macOS 测试，边界清晰 |
| A5 | 持久化 SwiftData；照片 JPEG 存 `Application Support/Photos/<uuid>.jpg`，模型只存文件名 | 数据库小、导出照片方便 |
| A6 | 删除客户：有入库单则禁止删除；删除入库单级联删除货物及照片文件 | 防数据丢失 |
| A7 | 尺寸内部统一存 **cm (Double)**，体积显示 m³（3 位小数），CSV 同时给 cm 和 m³ | 仓库常用 |
| A8 | 入库单号 `RK` + `yyyyMMdd` + `-` + 当日 3 位流水，如 `RK20261001-001` | 可读、唯一 |
| A9 | 导出：CSV UTF-8 BOM、PDF 用 `UIGraphicsPDFRenderer`、ZIP 用 `NSFileCoordinator(.forUploading)` | 零依赖 |
| A10 | UI 文案中文（硬编码），不做多语言 | 内部工具 |

## 3. 数据模型 (SwiftData)

```swift
@Model final class Customer {
  @Attribute(.unique) var code: String   // 客户代码
  var name: String; var contact: String; var phone: String
  var address: String; var note: String; var createdAt: Date
  @Relationship(deleteRule: .deny, inverse: \InboundOrder.customer) var orders: [InboundOrder]
}
@Model final class InboundOrder {
  @Attribute(.unique) var orderNo: String
  var customer: Customer?; var receivedAt: Date; var operatorName: String; var note: String
  @Relationship(deleteRule: .cascade, inverse: \CargoItem.order) var items: [CargoItem]
  // computed: totalPieces, totalVolumeM3, totalWeightKg
}
@Model final class CargoItem {
  var order: InboundOrder?; var name: String
  var lengthCm, widthCm, heightCm: Double; var quantity: Int; var weightKg: Double?
  var photoFiles: [String]; var method: String /* "lidar"|"manual" */; var confidence: Double?
  var createdAt: Date
  // computed: unitVolumeM3 = l*w*h/1e6, totalVolumeM3 = unit*quantity
}
```
（单号流水按 `receivedAt` 所在日计算，不用 `Date()`。实现时若 `.deny` 在 SwiftData 不生效，则在 UI 层删除前检查 `orders.isEmpty`。）

## 4. 测量算法（BoxMeasureKit）

公开 API：
```swift
public struct BoxEstimate { public var length, width, height: Float /*m, length>=width*/; public var center: SIMD3<Float>; public var yaw: Float; public var planeY: Float; public var pointCount: Int }
public enum BoxMeasurer {
  public static func estimate(points: [SIMD3<Float>], seed: SIMD3<Float>, params: Params = .init()) -> BoxEstimate?
}
public struct BoxAggregator { mutating func add(_:); func median() -> BoxEstimate?; var spread: Float /*最大相对离散度*/ }
public func minAreaRect(_ pts: [SIMD2<Float>]) -> (center: SIMD2<Float>, size: SIMD2<Float>, angle: Float)
```
世界坐标 y 向上（ARKit 重力对齐）。步骤见 research.md §4，并做以下修订：
- **种子** = 中心 5×5 窗口内高置信度点反投影后的中位数（不是单个像素）；高置信点太少时退回 ≥medium。
- **支撑面** = 从 `seedY − 3cm` 往下扫 y 直方图，取**第一个**点数 ≥ `max(minPlanePoints, 5% 半径内点数)` 的桶（最近的支撑面：托盘顶/桌面优先于远处地面）。搜索半径从 1.0m 起，点数不足时扩到 2.0m。
- **长宽** 只用**顶面薄层**点（`y ∈ seedY ± 2cm`）做 flood-fill + 最小外接矩形，排除轮廓处深度渗出的中间高度点；薄层太稀（<50 点）时退回全部箱体点。
- **高** = 全部箱体点 y 的 98 分位 − planeY。
- **v3 起默认 `maxExtent = true`（见 §10 C4）**：footprint 用全部高度点，高度取有支撑的最高面；上面的顶面薄层法 + 98 分位仅在 `maxExtent = false` 时使用（瞄准阶段单帧估计用它，避免单视角轮廓渗出把尺寸放大）。

参数 `Params`：半径 1.0→2.0m、直方图桶 1cm、离面阈值 1.5cm、顶层厚度 ±2cm、XZ 网格 1cm、高度分位 0.98、每格最少点数 2、最大箱体 2.5m。

单测（合成点云，加 ±3mm 噪声）：
1. 地面上 40×30×20cm 旋转 30° 的箱 → 各边误差 < 1cm。
2. 地面上 + 旁边 20cm 处另一箱 → 只测种子所在箱。
3. 桌面上箱 + 远处地面 → planeY = 桌面；**15cm 托盘上的箱 + 地面 → planeY = 托盘顶**（托盘可见点数少于地面）。
3b. 轮廓渗出：箱四周加中间高度的渗出点（2cm 宽带）→ 长宽误差仍 < 1cm。
4. `minAreaRect` 对旋转矩形 / 退化输入（<3 点、共线）。
5. Aggregator 中位数与 spread。

## 5. App 结构

```
GoodsScanner/
  App.swift                    // @main, modelContainer, TabView
  Models.swift                 // 3 个 @Model + 计算属性 + 单号生成
  PhotoStore.swift             // 保存/读取/删除 JPEG
  Views/CustomersView.swift    // 列表+搜索+编辑表单
  Views/OrdersView.swift       // 入库单列表(按日期分组)+详情+新建/编辑
  Views/ItemEditView.swift     // 货物编辑: 尺寸/件数/重量/照片, 入口: LiDAR 扫描 | 拍照
  Views/ReportsView.swift      // 筛选+汇总+导出
  Views/SettingsView.swift     // 操作员默认名、校准偏置(cm)、LiDAR 状态
  Scan/ScanView.swift          // UIViewRepresentable(ARSCNView) + HUD + 锁定按钮
  Scan/ScanSession.swift       // ARSessionDelegate: 深度→点云→BoxMeasureKit, 线框节点, 拍照
  Export/Exporter.swift        // CSV / PDF / ZIP
GoodsScannerTests/            // 单号、体积计算、CSV 转义 (XCTest, 模拟器)
Packages/BoxMeasureKit/       // Sources + Tests
project.yml
```

### 扫描交互
1. 打开扫描页：全屏相机 + 中心十字 + 顶部提示（"对准箱顶，周围留出地面"）。
2. 每 ~0.2s 跑一次估算，屏幕显示实时 L×W×H，AR 中画绿色线框箱体。
3. 点「锁定」→ 取最近 10 帧中位数、spread → 拍当前帧照片 → 回填到货物编辑页（可手动修正）。spread > 5% 标黄提示"不稳定，建议重扫"。
4. 不支持 LiDAR：扫描按钮置灰并说明，手动录入。

### 导出列（CSV，一行一件货物）
入库单号, 入库时间, 客户代码, 客户名称, 联系人, 电话, 操作员, 品名, 长cm, 宽cm, 高cm, 件数, 单件体积m³, 总体积m³, 重量kg, 测量方式, 照片文件, 入库备注

## 6. 执行计划（Subagent 分工）

| 阶段 | 负责 | 内容 | 验收 |
|---|---|---|---|
| P0 | 主会话(Opus) | 调研、本 Spec、审核 | ✅ |
| P1a | worker (Opus) | `Packages/BoxMeasureKit` 算法 + 单测 | ✅ 10/10 |
| P1b | worker (Opus)，与 P1a 并行 | project.yml、模型、客户/入库/报表/设置、PhotoStore、Exporter、手动录入+系统相机、XCTest；扫描入口先放占位 | ✅ |
| P2 | worker (Opus) | `Scan/` ARKit 采集接入 BoxMeasureKit、线框、拍照、回填 | ✅ 模拟器 + 真机(generic)编译 |
| P3 | explorer (Sonnet) 代码审阅 + 主会话复核 | 对照本 Spec 逐条核对、找 bug | ✅ 17 项修复 |
| P4 | 主会话 | 模拟器跑起来截图核对主要流程 | ✅ 5 个流程通过 |
| P5 | **用户真机** | 用已知尺寸纸箱校准（设置里偏置） | 每边误差 ≤2cm |

## 7. 实现注意
- `NSFileCoordinator(.forUploading)` 给的 zip 临时 URL 只在 block 内有效，必须在 block 内拷走。
- 模拟器无相机：`UIImagePickerController(.camera)` 先判 `isSourceTypeAvailable`，否则用 `PhotosPicker`。
- `project.yml` 顶层留 `DEVELOPMENT_TEAM` / bundle id，用户真机安装前填写。
- research.md 里的 API 片段来自记忆，以 Xcode 27 编译结果为准。

## 8. 回滚 / 风险
- LiDAR 精度不达标 → 设置里调偏置；仍不行时手动录入始终可用。
- 支撑面误判（箱放桌上、旁边贴墙）→ 提示用户留出周围地面；P5 根据真机数据调 `Params`。
- 真机验证只能由用户完成（开发机无 LiDAR 设备连接）。

## 9. v2：环绕扫描（2026-10-01 用户真机反馈）

用户反馈：静态识别要求手机不动，不符合预期；希望**绕箱子走一圈、扫过的表面变色、扫完自动出尺寸**（Polycam / 3D Scanner App 式体验）。

决策：
| # | 决策 | 理由 |
|---|---|---|
| B1 | 单一流程替换静态模式：**瞄准 → 自动锁定箱体 → 环绕 → 自动完成**；「完成」按钮可随时提前结束（等价旧静态模式） | 不加模式开关 |
| B2 | `sceneReconstruction = .mesh`，ARMeshAnchor 转 SCNGeometry 半透明叠加；顶点落在当前估计箱体（外扩 3cm）内染**绿色**，其余淡蓝 → "扫过变色" | 系统 mesh 免费给覆盖反馈 |
| B3 | 测量点云 = 整个环绕过程的深度点**体素融合**（5mm 体素，命中≥2 次才算，存质心），仅保留锁定种子水平 2m 内的点；每 0.5s 对融合点云跑 `BoxMeasurer.estimate` | 四周侧面都被看到，比单帧准；命中计数滤飞点 |
| B4 | 种子锁定：准星种子 1s 内漂移 <5cm 且已有估计 → 固定种子（世界坐标，箱子不动），震动提示"绕箱子走一圈" | 环绕时准星不再对准箱顶 |
| B5 | 覆盖度：以箱体中心为圆心把相机方位角分 12 扇区（30°），相机距 0.3–2.5m 且箱心在画面内才计入；HUD 显示环形进度 | 用户知道还差哪边 |
| B6 | 自动完成：覆盖 ≥ 9/12 扇区（270°）且最近 5 次估计 spread ≤ 2% → 自动锁定 + 震动；照片取锁定种子时那一帧（正对箱子） | "扫描完毕自动获得尺寸" |
| B7 | BoxMeasureKit 接口不变；新增 `VoxelCloud`（纯 Swift，可 macOS 单测） | 算法仍可单测 |

## 10. v3：多角度标注照片 + 不规则物体按最大外形（2026-10-01 用户真机反馈：v2 效果不错）

| # | 决策 | 理由 |
|---|---|---|
| C1 | 环绕中自动拍照：锁定时 1 张，之后每当新覆盖扇区与已拍扇区角距 ≥ 90°（3 扇区）再拍 1 张，**最多 4 张** | 四个方向的入库凭证 |
| C2 | 拍照时只存原图 + 相机 transform/intrinsics/分辨率；**完成时用最终估计**把 3D 线框投影到每张照片，画线框 + 长/宽/高标签（UIGraphicsImageRenderer），只保存标注后的照片 | 标注用最准的结果 |
| C3 | `ScanResult.photo` → `photos: [UIImage]`，ItemEditView 全部加入照片 | |
| C4 | **按最大外形计量**：footprint 用连通域**全部高度**点（经格子/邻居过滤 + 修剪）的最小外接矩形；高度取有支撑的最高点（稳健最大值而非 p98）。`Params.maxExtent = true` 默认开；旧的顶面薄层法保留为 `false` 供对比测试 | 规则箱结果不变，不规则物体（上小下大、袋装、异形）不漏算 |
| C5 | 扫描 HUD 小字提示「按最大外形尺寸计量」 | 让操作员知道口径 |

## 11. v4：侧面瞄准 + 照片查看 + 调试模式（2026-10-02 用户反馈）

| # | 决策 | 理由 |
|---|---|---|
| D1 | 瞄准支持**箱顶或侧面**：准星窗口点用 `isVerticalSurface` 判断竖直/水平；侧面 → `Params.seedOnSide = true`（物体点上限 seed.y + maxBoxSize，强制最大外形路径），体素云纵向裁剪同样放宽到 maxBoxSize | 大件货物箱顶拍不全 |
| D2 | 侧面种子的 flood-fill 从种子 XZ 所在列开始（侧面点投影即箱体边缘格子），无需先找到箱顶 | 复用现有分割 |
| D3 | 照片点击 → 全屏查看器（分页滑动、双指缩放、分享） | |
| D4 | 「设置 → 调试模式」开关（所有构建可用，不另做 Debug 版）：扫描 HUD 显示种子类型、planeY、帧点数/体素数/上限、估计耗时、失败原因、L/W/H 历史；完成后可 3D 查看点云（物体绿 / 支撑面蓝 / 其他灰） | 现场看问题 |
| D5 | 调试模式下每次扫描保存 `Documents/ScanLogs/<时间>/scan.json + points.ply`；`UIFileSharingEnabled` 让「文件」App 可见；开发机用 `xcrun devicectl device copy from` 拉取 | 离线回放调参 |
| D6 | BoxMeasureKit 增加 macOS 可执行目标 `bmk-replay <dir> [--param k=v ...]`：读取日志、重跑估计、打印对比、输出分割着色 PLY | 不用真机即可迭代参数 |
| D7 | `estimate` 返回 nil 时 HUD 显示具体原因（无支撑面 / 准星处无物体 / 点太少 / 尺寸超范围）——由 `estimateDebug` 提供 | 替换笼统的"未识别到箱体" |

## 12. 计量口径确认（2026-10-02 用户确认）

- **按最大外形计量**：鼓包、提手、凸起都计入（软包装 / 鼓起纸箱读数会大于卷尺量顶边）。用于体积计费与装箱。
- 真机回放基线（礼盒 35.5×7×38，加绳≈40，中部鼓包实宽≈8.5–9）：L/H 误差 ≤1.5 cm；W 残余边缘噪声 ≈1 cm。回归用例见 `Packages/BoxMeasureKit/Tests/BoxMeasureKitTests/DeviceLogTests.swift` + `Fixtures/`。
- 待办：更多硬纸箱真机日志，进一步收紧 W 噪声（`trimFraction` / `wallBand` 仅在一个盒子一种地面上调过）。

## 13. v5：自动形状识别（2026-10-02 用户确认）

用户确认：鼓包纸箱读数大于标称属正常（按最大外形）；圆柱 Ø26 是**盖子边沿**（柱身 ≈22.5），按最大外形应读 26；要求**自动判断类型**。

| # | 决策 |
|---|---|
| E1 | `BoxEstimate.shape: ShapeKind {box, cylinder, irregular}`（旧日志解码为 .box）。融合点云估计时自动分类：分高度切片，比较圆拟合 vs 矩形拟合残差；都差 → irregular |
| E2 | cylinder：L = W = 最大直径。逐 1cm 高度带求半径，**只取角度覆盖 ≥ ~60% 的整圈带**（盖沿是整圈，轮廓渗出是零散的）→ 边沿保留、毛刺排除；H 同现有 |
| E3 | box / irregular：沿用现有 `.fused` 路径（最大外形） |
| E4 | App：`CargoItem.shape`（默认 "box"，SwiftData 轻量迁移）；扫描 HUD/结果显示类型；圆柱显示「直径」；照片标注圆柱画上下圆环 + 竖线、标「直径 / 高」；CSV 增加「形状」列（末尾追加，不改原列顺序）；体积仍按外接长方体 L×W×H（运输计费口径） |
| E5 | 回放验证：大箱子按鼓包外形（≈42.8×33.5×31.5）、礼盒按现有口径、圆柱 26×26×25.5±1.5 |

## 14. 相机模式（无 LiDAR，2026-10-03）

| # | 决策 | 理由 |
|---|---|---|
| F1 | 无 LiDAR 的 ARKit 机型自动用相机模式；有 LiDAR 时「设置 → 开发者 → 强制相机模式」可切换测试 | 非 Pro iPhone 也能扫描；Pro 机上可直接对比 |
| F2 | 每帧 Vision `VNGenerateForegroundInstanceMaskRequest`（960 px 宽）取物体轮廓；瞄准时取准星处实例，锁定后取锚点投影处实例 | 系统自带、无授权问题；YOLO 无「纸箱」类别且为 AGPL |
| F3 | 地面 = ARKit 水平面检测（优先 .floor 分类，否则最低的 ≥0.3 m² 水平面）；锚点 = 轮廓底边射线与地面的最近交点内推 5 cm，稳定 1 s 锁定 | 锚点总在物体占地范围内，任意视角都投影在物体轮廓上 |
| F4 | `BoxMeasureKit.SilhouetteHull`：轮廓视锥求交（visual hull），2.5 cm 粗网格 → 5 mm 细网格（≤300 万体素）；需在至少一半视图中可见；地面 = ARKit 平面 ±15 cm 内截面停止增大的高度（ARKit 曾低 7.5 cm）；箱体占地 = 地面上 3 cm 最小外接矩形；圆形（占地/外接矩形 < 0.9）= 各高度最大外形，标为圆柱；高 = 顶面高度外推到边缘 | 研究：docs/research/hull_rgb.py，3 次 40×30×30 实扫误差 ≤1.6 cm |
| F5 | 覆盖 ≥6 个扇区（180°）后才估计；自动完成 = 9 扇区 + 5 次估计离散度 ≤2 %；结果标记 method = "camera"（相机） | 少于半圈时轮廓在纵深方向不闭合 |
| F6 | 调试记录：位姿 + JPEG；LiDAR 机型上同时记录 LiDAR 深度作参照（不参与测量，没有深度的帧不记录），否则 frames.bin 无深度（width = height = 0）；lockSeed = 锚点，lockPlaneY = ARKit 地面 | 可用 docs/research 脚本离线复算，并用 LiDAR 核对地面和轮廓误差 |
