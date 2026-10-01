# 入库量方 — Design Spec

方向：**工业物流 · 精确 · 可信**。仓库现场用（光线差、戴手套、单手操作），信息密度高但层级清楚；数字是主角。

## 1. Tokens（`GoodsScanner/Theme.swift`，唯一出处）

| Token | Light | Dark | 用途 |
|---|---|---|---|
| `brand` | #1F3A5F 深海军蓝 | #8FB3E0 | 标题强调、选中 tab、图标底 |
| `accent` | #FF7A1A 安全橙 | #FF8F3D | 主按钮、CTA（扫描/新建） |
| `scan` | #22C55E 激光绿 | #34D399 | LiDAR 线框、稳定状态、覆盖进度 |
| `warn` | #F59E0B | #FBBF24 | 不稳定、待确认 |
| `danger` | 系统 red | 系统 red | 删除 |
| `surface` | 系统 secondarySystemGroupedBackground | 同 | 卡片 |
| `canvas` | 系统 systemGroupedBackground | 同 | 页面底 |

- 圆角：卡片 16，按钮 14，小标签 8（`RoundedRectangle(cornerRadius:style: .continuous)`）。
- 间距：4 / 8 / 12 / 16 / 24。
- 字体：系统 SF Pro；**所有尺寸/体积/重量数字** 用 `.monospacedDigit()` + `.rounded` design（`Font.system(.title2, design: .rounded).weight(.semibold)`）；单位用 `.secondary` 小一号。
- 阴影：不用重阴影；卡片靠 surface/canvas 对比 + 0.5pt 分隔线。
- 深色模式必须可用（所有颜色走 token / 系统语义色）。
- 触控目标 ≥ 44pt；主操作按钮全宽 52pt 高。

## 2. 组件

- `StatCard`：图标(SF Symbol, brand 色圆底) + 大数字 + 单位 + 标签。用于入库首页今日统计、报表汇总。
- `DimsBadge`：`60 × 45 × 20 cm` 等宽数字胶囊，次级底色。
- `PrimaryButtonStyle`：accent 底白字全宽，按下缩放 0.97 + 轻触感。
- `EmptyState(image:title:message:action:)`：插图 + 标题 + 说明 + 可选按钮。
- 列表行：左侧 brand 色圆角方块 SF Symbol（`shippingbox.fill` / `person.fill`），主标题、副标题（客户 · 时间），右侧体积数字。

## 3. 页面

- **入库**：顶部今日概览（今日单数 / 件数 / 体积 m³ 三个 StatCard 横排），下面按日分组卡片列表；空态插图 `EmptyOrders`。右下或导航栏 accent「+ 新建入库」。
- **入库单详情**：头部卡片（单号大字、客户、时间、操作员）+ 汇总 StatCard 行 + 货物卡片（缩略图 56pt、品名、DimsBadge、件数、体积）+ 底部全宽「添加货物」。
- **货物编辑**：顶部大按钮「LiDAR 环绕扫描」(accent，带 `viewfinder` 图标；不可用时说明)；尺寸三格输入（等宽数字）；体积实时大字；照片横向滚动。
- **客户**：头像圆（客户名首字，brand 色）+ 名称 + 代码标签 + 电话；空态 `EmptyCustomers`。
- **报表**：筛选卡片 + 汇总 StatCard 2×2 网格 + 客户明细 + 导出按钮组（CSV/PDF/照片，图标 + 文字）；无数据空态 `EmptyReports`。
- **设置**：分组表单，顶部 App 图标 + 名称 + 版本小头图。
- **扫描页（v2 合并后再做）**：顶部状态胶囊（毛玻率 `.ultraThinMaterial`），底部尺寸大字卡 + 12 段覆盖环，引导插图 `ScanAim`（瞄准）/`ScanOrbit`（环绕）在开始前作为提示卡。

## 4. 资产（名字固定，代码按此引用）

| Asset | 内容 | 规格 |
|---|---|---|
| `AppIcon` | 深海军蓝渐变底 + 安全橙等轴纸箱 + 激光绿扫描线/尺寸标注线，极简扁平，无文字 | 1024×1024 PNG，**不透明**，单尺寸 |
| `EmptyOrders` | 空仓库货架/托盘 + 一个纸箱，柔和插画 | 透明 PNG，约 4:3 |
| `EmptyCustomers` | 名片/联系人卡片 + 纸箱 | 透明 PNG，约 4:3 |
| `EmptyReports` | 图表报表纸 + 纸箱 | 透明 PNG，约 4:3 |
| `ScanAim` | 手机俯视对准纸箱顶部，十字准星 | 透明 PNG，约 4:3 |
| `ScanOrbit` | 手机绕纸箱一圈的弧形箭头轨迹，纸箱表面绿色扫描网格 | 透明 PNG，约 4:3 |

插画统一风格：扁平 + 轻微等轴、品牌三色（海军蓝/安全橙/激光绿）+ 浅灰，无文字、无人物面孔，线条干净，留白多，深浅色背景都能看。
