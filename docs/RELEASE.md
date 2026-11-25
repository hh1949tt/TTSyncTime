# TTSyncTime 发布文档

> Connect IQ **Widget**（`type="widget"`）：拿一次 GPS 定位，对比 GPS 时间与手表 RTC，
> 观察几秒取平均后给出「时间一致 / 存在偏差」的结论，历史误差存 Storage 供长期跟踪漂移。

| 项目 | 版本 | 发布日期 | 应用 id | 发布形态 | 状态 |
| --- | --- | --- | --- | --- | --- |
| TTSyncTime | **1.0.0** | 2026-11-26 | `9f3f2b9a-4d8c-4a4e-9b9d-8b9c5a2e7f31` | 侧载 `.prg`（GARMIN/APPS/） | **构建通过 · 模拟器验收通过 · 真机待确认** |

---

## 1. 版本与身份

| 项 | 值 |
| --- | --- |
| 版本 | 1.0.0（首个公开发布版本） |
| 类型 | `widget`（小工具环入口，不是应用列表） |
| 手表上的名字 | **TTSyncTime** |
| 入口类 | `TTSyncTimeApp`（`AppBase.getInitialView()` → `TTSyncTimeView`） |
| 支持机型 | `instinct2x` |
| 最低 API | 3.4.0 |
| 权限 | `Positioning` |
| 语言 | `eng` + `zhs` |
| 产物 | `bin/TTSyncTime.prg`（103,660 字节，2026-11-26 06:57 构建，SDK 9.2.0，零警告） |
| 许可 | PolyForm Noncommercial 1.0.0，**禁止商用** |

## 2. 1.0.0 交付内容

| 能力 | 说明 |
| --- | --- |
| 一次定位 | `LOCATION_ONE_SHOT`，fix 后 90s 超时保护（`GPS_TIMEOUT_SECONDS`） |
| 平均误差 | fix 后观察 5s（`OBSERVE_SECONDS`）取平均，±1s（`SYNC_TOLERANCE`）内判 `IN SYNC` |
| 三行时钟列对齐 | UTC / RTC / GPS，「标签右边界 + 时间左边界」双锚点，块整体居中 |
| 版面节奏 | 表头两行（状态 + 三态副信息）+ 数据四行（3 时钟 + 结果），行距 24px，行间空隙 ≥9px |
| 八角屏/圆窗适配 | 圆窗外缘最低 0.42h 决定首行位置；状态行宽度阈值 0.36w 避开圆环 |
| 历史跟踪 | `Application.Storage` 保存上次误差 + 累计次数（`HISTORY_MAX` 条） |
| 采光窗品牌字 | 圆窗内绘制 `TT`（Power Glass 半透明透出） |
| 交互 | ENTER 重测（未出结论不响应），BACK 退出 |

## 3. 已知问题与取舍

- `ENTER=RETEST` 全文案（85px）放不进表头槽位（圆环左缘限制 63px），缩短为 `RETEST` / `重测`
- `Number.round()` 在 Long 上不存在，误差格式化用「×10 加 0.5 截断 + `toNumber()`」实现
- `TEXT_JUSTIFY_CENTER | VCENTER` 组合在该 SDK 表现异常，垂直居中的 TT 只用 `TEXT_JUSTIFY_CENTER`
- 仅适配 `instinct2x`；换机型需重测圆窗圆心与八角斜角

## 4. 验收记录

- monkeyc（SDK 9.2.0）构建零警告
- 模拟器实测三个状态（搜星 / 观察 / 完成），1:1 截图逐行测量墨迹行带：
  `23-38 | 48-60 | 81-94 | 106-119 | 129-142 | 153-165`，空隙 9/20/11/9/10px，
  无重叠、无切断、无压圆环
- 真机：待确认
