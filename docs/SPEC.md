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
| P1a | worker (Opus) | `Packages/BoxMeasureKit` 算法 + 单测 | `swift test` 全绿 |
| P1b | worker (Opus)，与 P1a 并行 | project.yml、模型、客户/入库/报表/设置、PhotoStore、Exporter、手动录入+系统相机、XCTest；扫描入口先放占位 | `xcodegen` + 模拟器 `xcodebuild test` 全绿 |
| P2 | worker (Opus) | `Scan/` ARKit 采集接入 BoxMeasureKit、线框、拍照、回填 | 模拟器编译通过；模拟器显示降级提示 |
| P3 | explorer (Sonnet) 代码审阅 + 主会话复核 | 对照本 Spec 逐条核对、找 bug | 问题清单 → Opus 修复 |
| P4 | 主会话 | 模拟器跑起来截图核对主要流程 | 截图 |
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
