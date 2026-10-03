# Localization glossary

Source language: English. Each translator writes `l10n/<lang>.json` (`{ "<English key>": "<translation>" }`) for every
key in `l10n/keys.json` that doesn't have `"translate": false`, plus `l10n/infoplist/<lang>.json`.
New strings in code: `xcodebuild build` (any destination), then `python3 tools/l10n/extract_keys.py` to refresh keys.json.
Then run `python3 tools/l10n/build_catalog.py && python3 tools/l10n/check.py --langs <lang>`.

## Rules
- Keep every format specifier (`%@`, `%lld`, `%.1f`…) with the same count and type. Reorder with positional
  specifiers (`%2$@ … %1$lld`) if the grammar needs it.
- Plural keys (`"plural": true`): give a dict of CLDR categories, each a **whole sentence** with the number in it:
  `{"one": "%lld order", "other": "%lld orders"}`. Required: en/es/fr/de/pt-BR `one`+`other`; ru `one`+`few`+`many`+`other`;
  zh-Hans/zh-Hant/ja/ko/vi a plain string is fine (`other` only). `pluralArg` says which argument drives the
  plural when it isn't the first number.
- Respect length hints in the comments (tab titles ≤ 12 chars, buttons ≤ 16).
- `%@ (%@)` is "name (code)": use your language's parentheses. `LiDAR`, `CSV`, `PDF`, `ZIP` stay as is.
- Units: `cm`, `kg`, `m³` are SI symbols and stay unlocalized in every language (also inside sentences and headers,
  e.g. ru "Вес (kg)", not "кг"); UI components hard-code them next to numbers, so translations must match.
- Count + unit ("3 orders", "3 pcs"): always a plural key with the number in it, never a bare unit word.
- Tone: short, neutral, professional warehouse/logistics wording. Imperative for instructions ("Aim at the item").

## Terms

| English | zh-Hans | Meaning |
|---|---|---|
| Cargo Measure | 入库量方 | App name (home screen, Settings › About) |
| Inbound (tab) | 入库 | Receiving goods into the warehouse |
| inbound order | 入库单 | One receiving document; has an order number (单号) |
| Order No. | 单号 | Inbound order number, e.g. RK20261001-001 |
| item | 货物 / 品名 | One line of goods in an order (品名 = item name in tables) |
| pcs / Pieces / Quantity / Qty | 件 / 件数 | Piece count |
| customer | 客户 | Owner of the goods; has a code (客户代码) and name |
| operator | 操作员 | Warehouse staff who received the goods |
| received (at) | 入库时间 | Date/time goods were received |
| note | 备注 | Free-text remark |
| report | 报表 | Summary over a date range; exported as CSV / PDF / photos ZIP |
| export | 导出 | |
| scan | 扫描 | Measuring an item with the phone |
| measure / measurement | 测量 / 量方 | 量方 = measuring cargo volume (the app's purpose) |
| volume / total volume / unit volume | 体积 / 总体积 / 单件体积 | Always m³ |
| weight | 重量 | kg |
| dimensions / size | 尺寸 | L × W × H in cm |
| L / W / H, Length / Width / Height | 长 / 宽 / 高 | |
| Diameter | 直径 | Cylinders: Ø × H |
| Box / Cylinder / Irregular | 箱体 / 圆柱 / 异形 | Item shape |
| max outer dimensions | 按最大外形 | Measurement policy: bounding size |
| LiDAR / Camera / Manual | LiDAR / 相机 / 手动 | Measuring method |
| walk-around scan | 环绕扫描 | Walking around the item while scanning |
| direction(s) | 方向 | Segments of the coverage ring |
| locked | 已锁定 | The scanner has fixed on the item |
| top / side (of a box) | 箱顶 / 侧面 | |
| floor / pallet / support surface | 地面 / 托盘 / 支撑面 | |
| crosshair | 准星 | |
| spread | 离散度 | Variation between repeated measurements |
| calibration / offset per side | 校准 / 每边偏置 | |
| debug mode / debug data | 调试模式 / 调试数据 | Developer-only screens; plain wording is fine |
| Disclaimer / tutorial | 免责声明 / 教程 | |
