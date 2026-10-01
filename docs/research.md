# 调研：iPhone LiDAR 货物尺寸/体积扫描

调研日期：2026-10-01

## 1. GitHub 开源项目

| 项目 | 状态 | 方法 | 结论 |
|---|---|---|---|
| [hugginsc10/PackMeasure](https://github.com/hugginsc10/PackMeasure)（MIT, Swift） | early alpha，0 star，作者自述真机校准未完成；已知箱 24×20×20in 测成 24×24×20in | 多角度（3 个视角）LiDAR 采集 → 分割 → 矩形尺寸；角度不一致时阻止保存；带本地库存 | **只作参考**（多角度一致性校验、数据模型），不 fork |
| [SmartSendApp/SSKitCore](https://github.com/SmartSendApp/SSKitCore) | 6 star，无 license，禁止未经许可上架 | 封装好的 ARKit 量体积 VC | 不可用 |
| [tyang-gauntlet/LiDARKit](https://github.com/tyang-gauntlet/LiDARKit) | — | sceneDepth 点云采集，无测量 | 参考采集代码 |
| [TokyoYoshida/ExampleOfiOSLiDAR](https://github.com/TokyoYoshida/ExampleOfiOSLiDAR)、[Waley-Z/ios-depth-point-cloud](https://github.com/Waley-Z/ios-depth-point-cloud) | — | 深度→点云示例（基于 WWDC20-10611） | 参考 |
| [CurvSurf/FindSurface-GUIDemo-iOS](https://github.com/CurvSurf/FindSurface-GUIDemo-iOS) | — | 点云拟合平面/圆柱等几何体 | 引擎为独立商业库，不用 |
| [apple/ARKitScenes](https://github.com/apple/ARKitScenes) | — | 带有向 3D 包围盒的数据集 | 可做离线测试数据 |

**结论：GitHub 上没有成熟可 fork 的"LiDAR 量方 + 仓库入库"项目**，中文关键词（LiDAR 测量 体积 / 激光雷达 量方）也只有通用扫描/导出 mesh 的仓库。决定**自研测量算法 + 自建简易 WMS**。

## 2. 商业产品（精度预期）

- vMeasure：宣称规则件 ±5mm，最小 5×5×5cm（厂商宣传值）。
- RePacker：最小边约 6cm。
- 现实预期：干净纸箱每边 1–2cm 误差；小件相对误差更大；边缘普遍**偏大**（深度在轮廓处"渗出"，深度图仅 256×192）。
- 失败场景：玻璃、镜面、亮金属、黑色/缠绕膜表面、贴墙或紧挨其他箱子、太薄的物品。

## 3. Apple API 选型

| 需求 | 选型 | 原因 |
|---|---|---|
| 深度 | `ARWorldTrackingConfiguration` + `.sceneDepth`（或 `.smoothedSceneDepth`）+ `confidenceMap` 只取 high | 256×192 Float32 米制深度，配合内参反投影到世界坐标 |
| 支撑面（地面/桌面） | 世界坐标 y 轴=重力向上 → 点云 y 值直方图找水平面 | 比 mesh 分类轻量，比 raycast 不会误命中箱顶 |
| ObjectCapture | ❌ | 不暴露尺寸，重建需数分钟 |
| RoomPlan | ❌ | 面向家具，不识别散件纸箱 |
| 拍照 | `ARFrame.capturedImage` → CIImage(.right) → JPEG | 1920×1440 足够作入库凭证，不打断 AR 流 |
| 设备检测 | `ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)` | 无 LiDAR / 模拟器 → 手动录入 |
| Info.plist | `NSCameraUsageDescription`；**不加** `UIRequiredDeviceCapabilities arkit` | 非 LiDAR 机也能装、用手动录入 |
| 导出 | CSV（UTF-8 BOM，Excel 打开中文不乱码）+ PDF 报表（UIGraphicsPDFRenderer，含缩略图）+ 照片 ZIP（`NSFileCoordinator .forUploading`） | 零第三方依赖；真 xlsx 需 libxlsxwriter，暂不需要 |

反投影公式（相机坐标 x 右 / y 上 / z 后，图像 y 向下，需翻转 y、z）：

```swift
let sx = Float(depthW)/Float(res.width), sy = Float(depthH)/Float(res.height)
let fx = K[0][0]*sx, fy = K[1][1]*sy, cx = K[2][0]*sx, cy = K[2][1]*sy
let pCam = SIMD4<Float>((u-cx)*d/fx, -(v-cy)*d/fy, -d, 1)
let pWorld = frame.camera.transform * pCam
```

## 4. 采用的测量算法（基线改进版）

1. 每帧：深度图 → 高置信度点 → 世界坐标点云（降采样）。
2. 中心十字准星命中点 = 箱顶种子点。
3. 支撑平面：种子点水平半径 R 内、比种子低 ≥3cm 的点做 y 直方图（1cm 桶），取点数最多的桶 → planeY。
4. 箱体分割：y ∈ (planeY+1.5cm, seedY+5cm] 的点投影到 XZ 网格（1cm），从种子格做连通域 flood-fill。
5. 高 = 箱体点 y 的 98 分位 − planeY；长宽 = 箱体格子凸包 + 旋转卡壳最小面积外接矩形。
6. 多帧：实时显示，"锁定"时取最近 N 帧结果逐维中位数，并给出稳定度（离散度）作为置信度。
7. 校准旋钮：设置里每边扣减偏置（默认 0，真机用已知尺寸箱子校准）。
