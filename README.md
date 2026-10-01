# 入库量方 GoodsScanner

iPhone LiDAR 量方 + 简易入库管理（客户 / 入库单 / 货物照片 / 报表导出）。离线单机，零第三方依赖。

- 调研：[docs/research.md](docs/research.md)
- 规格与计划：[docs/SPEC.md](docs/SPEC.md)

## 构建

```bash
brew install xcodegen          # 如未安装
xcodegen generate
open GoodsScanner.xcodeproj
```

真机安装前，在 `project.yml` 顶部填 `DEVELOPMENT_TEAM` 和唯一的 `PRODUCT_BUNDLE_IDENTIFIER`，再 `xcodegen generate`。
LiDAR 扫描需 iPhone 12 Pro 及以后的 Pro / Pro Max（或带 LiDAR 的 iPad Pro）；其他设备自动降级为手动录入。

## 测试

```bash
(cd Packages/BoxMeasureKit && swift test)        # 测量算法，macOS 上直接跑
xcodebuild test -project GoodsScanner.xcodeproj -scheme GoodsScanner \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/DD -quiet
```

模拟器演示数据：Debug 构建启动参数加 `-seedDemo`（仅空库时生效）。

## 扫描使用

1. 箱子放在地面/托盘/桌面上，**四周留出可见的支撑面**，不要贴墙或紧挨其他箱子。
2. 手机距箱顶约 0.5–1.5 m，斜上方俯视，十字准星对准箱顶。
3. 绿色线框贴合箱体、读数稳定（"稳定，可锁定"）后点「锁定」，自动回填尺寸并附照片，可手动修正。
4. 黑色、反光、缠绕膜表面精度会下降，必要时手动录入。

## 真机校准（首次使用必做）

1. 准备 2–3 个已知尺寸的纸箱（卷尺量准），各扫 3 次，记录读数。
2. 计算每边平均偏差（读数 − 实际），通常为正（边缘渗出偏大）。
3. 在「设置 → 校准偏置」填入该值（cm），之后扫描结果每边自动扣减。
4. 目标：每边误差 ≤ 2 cm。若支撑面误判（高度差一个托盘厚度），反馈给开发调整 `Params`。

## 导出

报表页按日期区间 / 客户筛选，导出：
- **CSV**（UTF-8 BOM，Excel 直接打开中文不乱码，一行一件货物）
- **PDF**（A4，含汇总和照片缩略图）
- **照片 ZIP**（按入库单分文件夹）
