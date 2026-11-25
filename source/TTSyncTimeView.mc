using Toybox.Application;
using Toybox.Attention;
using Toybox.Graphics;
using Toybox.Lang;
using Toybox.Math;
using Toybox.Position;
using Toybox.System;
using Toybox.Time;
using Toybox.Time.Gregorian;
using Toybox.Timer;
using Toybox.WatchUi;

// TTSyncTime 主视图
//
// 用途：Instinct 2X 的系统时间由 GPS 自动校准，但表内 RTC 与 GPS 的
// 偏差平时看不到。本 widget 拿一次 GPS 定位，对比 GPS 时间与 RTC，
// 观察几秒取平均后给出「时间一致 / 存在偏差」的结论，并把历史
// 误差存入 Storage，方便长期跟踪漂移。
//
// 交互：ENTER 重新测一轮；BACK 退出。
class TTSyncTimeView extends WatchUi.View {

    // ---- 可调参数 ----
    static const OBSERVE_SECONDS = 5;        // fix 后观察秒数
    static const GPS_TIMEOUT_SECONDS = 90;   // 搜星超时（秒），到点停 GPS 省电
    static const SYNC_TOLERANCE = 1.0;       // 平均误差 ≤ ±1s 判定一致
    static const HISTORY_MAX = 10;           // Storage 里保留的历史条数
    static const DEBUG_FAKE_FIX = false;      // 调试开关：跳过真实 GPS，直接喂假 fix

    // ---- 版面纵向节奏（屏高比例，按 176×176 实测校准）----
    // 纵向只有「表头两行 + 数据四行」：字块墨迹高约 14px，
    // 行距 24px 留出 10px 空隙，MIP 屏上才不会糊成一片。
    // 首行受右上采光窗圆环限制（外缘最低到 0.42h），只能从 0.42h 起。
    static const Y_STATUS = 0.105;   // 状态（TINY）      18.5 px
    static const Y_SUB    = 0.2398;  // 计时/精度/重测（XTINY） 42.2 px
    static const Y_ROW1   = 0.4318;  // 76.0 px
    static const Y_ROW2   = 0.5682;  // 100.0 px
    static const Y_ROW3   = 0.7045;  // 124.0 px
    static const Y_RESULT = 0.8409;  // 148.0 px（误差大字 / 进度 / 历史）

    // ---- 运行状态 ----
    var timer = null;
    var gpsStarted = false;
    var finished = false;
    var searchSeconds = 0;      // 搜星已用时
    var secondsAfterFix = 0;    // fix 后已观察秒数

    // ---- 时间数据 ----
    var utcMoment = null;
    var rtcMoment = null;
    var gpsMoment = null;
    var gpsBaseMoment = null;        // GPS fix 的绝对时间（UTC epoch 秒）
    var gpsBaseSystemMoment = null;  // 收到 fix 时的系统时间，用于走秒

    // ---- 定位信息 ----
    var gpsLocation = null;     // 保留位置，用于按真实时区显示当地时间
    var gpsAccuracy = null;     // 水平精度（米）

    // ---- 误差统计 ----
    var errorSeconds = null;    // 当前误差（秒）：正 = RTC 落后 GPS
    var errorSum = 0.0;
    var errorCount = 0;
    var errorAvg = null;        // 观察期平均误差，判定用它而非单次采样

    var gpsVibrated = false;

    // 状态行文案（str() 取资源，onShow 时初始化）
    var syncStatus = null;

    // ---- 历史记录（Storage 持久化）----
    var lastError = null;       // 上一次结论（秒）
    var runCount = 0;           // 累计测试次数

    function initialize() {
        View.initialize();
    }

    function str(resId) {
        return WatchUi.loadResource(resId).toString();
    }

    // 进 widget / 重测共用的初始化
    function resetRun() as Void {
        finished = false;
        searchSeconds = 0;
        secondsAfterFix = 0;
        syncStatus = str(Rez.Strings.StatusWaitGps);

        gpsMoment = null;
        gpsBaseMoment = null;
        gpsBaseSystemMoment = null;
        gpsLocation = null;
        gpsAccuracy = null;

        errorSeconds = null;
        errorSum = 0.0;
        errorCount = 0;
        errorAvg = null;

        gpsVibrated = false;
    }

    function onShow() as Void {
        resetRun();

        loadHistory();

        if (timer != null) {
            timer.stop();
        }
        timer = new Timer.Timer();
        timer.start(method(:onTimer), 1000, true);

        WatchUi.requestUpdate();

        startGps();
    }

    function onHide() as Void {
        stopGps();

        if (timer != null) {
            timer.stop();
            timer = null;
        }
    }

    // ENTER 触发：结束后重测一轮
    function retest() as Void {
        if (!finished) {
            // 还没出结论时不响应，避免中途打断统计
            return;
        }

        resetRun();
        WatchUi.requestUpdate();
        startGps();
    }

    function startGps() as Void {
        if (gpsStarted) {
            return;
        }

        gpsStarted = true;

        // 调试：不真的开 GPS，由 onTimer 在第 2 秒喂一个假 fix（见 onTimer）
        if (DEBUG_FAKE_FIX) {
            return;
        }

        try {
            // 一次有效定位就够用了
            Position.enableLocationEvents(
                Position.LOCATION_ONE_SHOT,
                method(:onPosition)
            );
        } catch (e) {
            gpsStarted = false;
            syncStatus = str(Rez.Strings.StatusGpsError);
            finished = true;   // 停掉搜星计时，允许 ENTER 重测
            System.println("TTSyncTime GPS ERROR: " + e);
            WatchUi.requestUpdate();
        }
    }

    function stopGps() as Void {
        if (!gpsStarted) {
            return;
        }

        try {
            Position.enableLocationEvents(
                Position.LOCATION_DISABLE,
                null
            );
        } catch (e) {
            System.println("TTSyncTime GPS STOP ERROR: " + e);
        }

        gpsStarted = false;
    }

    // GPS 定位回调（ONE_SHOT 的 info 不会为 null）
    function onPosition(info as Position.Info) as Void {
        var acc = null;
        if (info has :accuracy) {
            acc = info.accuracy;
        }

        applyFix(info.when, info.position, acc);
    }

    // 拿到一次定位后的统一处理（真实回调与调试图标都走这里）
    function applyFix(whenMoment, location, accuracy) as Void {
        if (accuracy != null) {
            gpsAccuracy = accuracy;
        }

        if (location != null) {
            gpsLocation = location;
        }

        if (whenMoment != null) {
            gpsBaseMoment = whenMoment;
        } else {
            try {
                gpsBaseMoment = Time.getCurrentTime({
                    :currentTimeType => Time.CURRENT_TIME_GPS
                });
            } catch (e) {
                gpsBaseMoment = null;
                System.println("TTSyncTime GPS TIME ERROR: " + e);
            }
        }

        // 记录收到 fix 时的系统时间，GPS 时间从这里开始走秒
        gpsBaseSystemMoment = Time.now();
        updateGpsMoment();
        readUtc();

        // RTC 留给下一次 1 秒 Timer 读取，避免同一毫秒内的读数抖动
        calculateError();

        if (errorSeconds != null) {
            syncStatus = str(Rez.Strings.StatusChecking);
        } else {
            syncStatus = str(Rez.Strings.StatusRtcInvalid);
        }

        // 首次有效 fix 震动提醒
        if (!gpsVibrated && gpsBaseMoment != null) {
            gpsVibrated = true;
            vibrateOnce();
        }

        WatchUi.requestUpdate();
    }

    function vibrateOnce() as Void {
        if (Attention has :vibrate) {
            try {
                Attention.vibrate([ new Attention.VibeProfile(100, 300) ]);
            } catch (e) {
                System.println("TTSyncTime VIBE ERROR: " + e);
            }
        }
    }

    // GPS 时间从 fix 时刻继续走秒
    function updateGpsMoment() as Void {
        if (gpsBaseMoment == null || gpsBaseSystemMoment == null) {
            gpsMoment = null;
            return;
        }

        try {
            var elapsed = Time.now().value() - gpsBaseSystemMoment.value();
            gpsMoment = new Time.Moment(gpsBaseMoment.value() + elapsed);
        } catch (e) {
            gpsMoment = gpsBaseMoment;
        }
    }

    function onTimer() as Void {
        readUtc();
        readRtc();

        // 调试：第 2 秒注入一次“刚定位”的状态，用来在模拟器里看结论界面
        if (DEBUG_FAKE_FIX && gpsBaseMoment == null && !finished && searchSeconds >= 1) {
            gpsAccuracy = 3;
            applyFix(Time.now(), null, null);
        }

        if (gpsBaseMoment != null) {
            updateGpsMoment();
            calculateError();

            if (!finished) {
                secondsAfterFix++;

                // 误差采样（观察期内取平均，抗单次读数抖动）
                if (errorSeconds != null) {
                    errorSum += errorSeconds;
                    errorCount++;
                }

                if (secondsAfterFix >= OBSERVE_SECONDS) {
                    finishRun();
                }
            }
        } else if (!finished && gpsStarted) {
            // 搜星计时与超时保护
            searchSeconds++;
            if (searchSeconds >= GPS_TIMEOUT_SECONDS) {
                stopGps();
                finished = true;
                syncStatus = str(Rez.Strings.StatusGpsTimeout);
            }
        }

        WatchUi.requestUpdate();
    }

    // 观察期结束：按平均误差下结论并写入历史
    function finishRun() as Void {
        stopGps();

        if (errorCount > 0) {
            errorAvg = errorSum * 1.0 / errorCount;
        }

        if (errorAvg != null) {
            if (absNumber(errorAvg) <= SYNC_TOLERANCE) {
                syncStatus = str(Rez.Strings.StatusSyncOk);
            } else {
                syncStatus = str(Rez.Strings.StatusNoSync);
            }
            saveHistory(errorAvg);
        } else {
            syncStatus = str(Rez.Strings.StatusRtcInvalid);
        }

        finished = true;
    }

    function readUtc() as Void {
        try {
            utcMoment = Time.now();
        } catch (e) {
            utcMoment = null;
        }
    }

    function readRtc() as Void {
        try {
            rtcMoment = Time.getCurrentTime({
                :currentTimeType => Time.CURRENT_TIME_RTC
            });
        } catch (e) {
            // RTC 在手表拿到可信时间源之前可能无效
            rtcMoment = null;
        }
    }

    function calculateError() as Void {
        if (gpsMoment == null || rtcMoment == null) {
            errorSeconds = null;
            return;
        }

        // 两个 value() 都是 UTC epoch 秒；正 = RTC 落后 GPS
        errorSeconds = gpsMoment.value() - rtcMoment.value();
    }

    // ---- 历史记录（Storage）----

    function loadHistory() as Void {
        try {
            var v = Application.Storage.getValue("lastError");
            lastError = (v instanceof Number or v instanceof Float) ? v : null;

            var c = Application.Storage.getValue("runCount");
            runCount = (c instanceof Number) ? c : 0;
        } catch (e) {
            lastError = null;
            runCount = 0;
        }
    }

    function saveHistory(avg) as Void {
        try {
            // 保留 1 位小数（同样避开 round()：×10 加 0.5 再截断，负数单独处理符号）
            var sign = 1;
            var mag = avg;
            if (mag < 0) {
                mag = -mag;
                sign = -1;
            }
            var tenths = (mag * 10 + 0.5).toNumber();
            var rounded = (tenths / 10.0) * sign;

            Application.Storage.setValue("lastError", rounded);
            runCount = runCount + 1;
            Application.Storage.setValue("runCount", runCount);

            var history = Application.Storage.getValue("history");
            if (!(history instanceof Array)) {
                history = [];
            }
            history.add(rounded);
            if (history.size() > HISTORY_MAX) {
                history = history.slice(history.size() - HISTORY_MAX, history.size());
            }
            Application.Storage.setValue("history", history);
        } catch (e) {
            System.println("TTSyncTime STORE ERROR: " + e);
        }
    }

    // ---- 格式化 ----

    function absNumber(value) {
        if (value < 0) {
            return -value;
        }
        return value;
    }

    function pad2(value) {
        if (value < 10) {
            return "0" + value.toString();
        }
        return value.toString();
    }

    function formatClock(moment) {
        if (moment == null) {
            return str(Rez.Strings.TimeUnknown);
        }

        try {
            var info = Gregorian.utcInfo(moment, Time.FORMAT_SHORT);
            return pad2(info.hour) + ":" + pad2(info.min) + ":" + pad2(info.sec);
        } catch (e) {
            return str(Rez.Strings.TimeUnknown);
        }
    }

    // 当地时间显示：fix 之后用 GPS 位置推断真实时区，之前用手表设置的时区
    function formatLocalMoment(moment) {
        if (moment == null) {
            return str(Rez.Strings.TimeUnknown);
        }

        try {
            if (gpsLocation != null) {
                var local = Gregorian.localMoment(gpsLocation, moment);
                if (local != null) {
                    var localInfo = Gregorian.info(local, Time.FORMAT_SHORT);
                    return pad2(localInfo.hour) + ":" +
                           pad2(localInfo.min) + ":" + pad2(localInfo.sec);
                }
            }

            return formatClock(moment);
        } catch (e) {
            System.println("TTSyncTime local time ERROR: " + e);
            return formatClock(moment);
        }
    }

    // 误差文本：+2s / -3s / 0s / +2.3s（带小数时用于平均值）
    // 注意：Number / Long 上都没有 round()，这里用「×10 加 0.5 再截断」的整数做法，
    // 只用 toNumber()（Long/Float 都有实现），避免运行时 Symbol Not Found。
    function formatErrorSeconds(value) {
        if (value == null) {
            return "";
        }

        var num = value.toNumber();
        var sign = "";
        if (num > 0) {
            sign = "+";
        } else if (num < 0) {
            num = -num;
        }

        var tenths = (num * 10 + 0.5).toNumber();
        if (tenths <= 0) {
            return "0s";
        }

        var whole = tenths / 10;
        var frac = tenths % 10;

        var text = whole.toString();
        if (frac != 0) {
            text = text + "." + frac.toString();
        }

        return sign + text + "s";
    }

    // 精度文本：只取整数米（Float.toString() 会打成一长串小数）
    function formatAccuracy(value) {
        if (value == null) {
            return "";
        }

        try {
            var s = value.toString();
            var dot = s.find(".");
            if (dot != null && dot > 0) {
                return s.substring(0, dot);
            }
            return s;
        } catch (e) {
            return "";
        }
    }

    // ---- 绘制 ----
    //
    // Instinct 2X Solar 的屏幕右上角有一个圆形采光窗（Power Glass），
    // 约占 (0.55w~0.85w, 0.10h~0.40h)；八角形屏面还会斜切四个角。
    // 因此：结论放左上角（那里空着且采光窗挡不到），三行时钟放在采光窗以下
    // 居中，底部只保留两行。位置全部按屏幕比例算，不写死像素。

    function onUpdate(dc as Graphics.Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        // 品牌字 TT：画在右上角采光窗内（Power Glass 是半透明的，
        // 透出稍暗但可读，正是原版的辨识点）。
        // 圆窗圆环外缘延伸出屏幕，拟合圆心在设备坐标约 (143.5, 31.5)/176，
        // TT 用 MEDIUM 字号约 16px 高，顶部放 0.095h 使字块垂直居中于圆心。
        dc.drawText(w * 0.825, h * 0.095, Graphics.FONT_MEDIUM, "TT",
            Graphics.TEXT_JUSTIFY_CENTER);

        // ---- 先算数据块的列锚点，表头与三行时钟都对齐到同一条左边界 ----
        var utcLabel = str(Rez.Strings.LabelUtc);
        var rtcLabel = str(Rez.Strings.LabelRtc);
        var gpsLabel = str(Rez.Strings.LabelGps);
        var utcValue = formatClock(utcMoment);
        var rtcValue = formatLocalMoment(rtcMoment);
        var gpsValue = formatLocalMoment(gpsMoment);

        // 列对齐：三行共用「标签右边界 + 时间左边界」两个锚点，
        // 整块按最宽的一行（通常是 RTC 的 8 位数字）水平居中。
        // 这样 GPS 是 --:--:-- 还是真实时间，时间列都严格对齐。
        var lw = textWidth(dc, utcLabel, Graphics.FONT_SMALL);
        lw = maxNum(lw, textWidth(dc, rtcLabel, Graphics.FONT_SMALL));
        lw = maxNum(lw, textWidth(dc, gpsLabel, Graphics.FONT_SMALL));
        var vw = textWidth(dc, utcValue, Graphics.FONT_SMALL);
        vw = maxNum(vw, textWidth(dc, rtcValue, Graphics.FONT_SMALL));
        vw = maxNum(vw, textWidth(dc, gpsValue, Graphics.FONT_SMALL));

        var gap = w * 0.035;
        var blockLeft = cx - (lw + gap + vw) / 2;
        var labelRight = blockLeft + lw;
        var valueLeft = labelRight + gap;

        // ---- 表头：状态行 + 一行副信息 ----
        // 副信息槽位三态复用：搜星中显示已用时、拿到 fix 后显示定位精度、
        // 出结论后显示重测提示；这样纵向永远只有「表头两行 + 数据四行」。
        var statusText = syncStatus;
        if (gpsBaseMoment == null && !finished) {
            statusText = str(Rez.Strings.StatusSearching);
        }

        var subText = "";
        if (finished) {
            subText = str(Rez.Strings.StatusRetest);
        } else if (gpsBaseMoment == null) {
            subText = searchSeconds + "s";
        } else if (gpsAccuracy != null) {
            subText = str(Rez.Strings.HintAcc) + " " + formatAccuracy(gpsAccuracy) +
                str(Rez.Strings.UnitMeter);
        }

        // 表头两行的横向安全区间：左边是八角屏的左斜边，右边是采光窗圆环左缘。
        // 中文文案（搜索卫星 / 时间一致）比英文宽一截，若像时钟那样左对齐到
        // blockLeft，末字会被圆环压住；所以表头改为在这条区间里**居中**，
        // 并且两行共用同一档字号 —— TINY 放不下就一起降到 XTINY。
        var bandLeft = w * 0.055;
        var bandRight = ringLeftAt(h * Y_STATUS + h * 0.11, w, h) - w * 0.02;
        var bandWidth = bandRight - bandLeft;
        var bandCx = (bandLeft + bandRight) / 2;

        var hdrFont = Graphics.FONT_TINY;
        var fitWidth = bandWidth - w * 0.03;
        if (textWidth(dc, statusText, hdrFont) > fitWidth or
            textWidth(dc, subText, hdrFont) > fitWidth) {
            hdrFont = Graphics.FONT_XTINY;
        }

        dc.drawText(bandCx, h * Y_STATUS, hdrFont, statusText,
            Graphics.TEXT_JUSTIFY_CENTER);

        if (subText != "") {
            dc.drawText(bandCx, h * Y_SUB, hdrFont, subText,
                Graphics.TEXT_JUSTIFY_CENTER);
        }

        // 三行时钟（整体在采光窗以下：圆窗外缘最低到 0.42h，首行留约 2px 间距）
        drawClockRow(dc, labelRight, valueLeft, h * Y_ROW1, utcLabel, utcValue);
        drawClockRow(dc, labelRight, valueLeft, h * Y_ROW2, rtcLabel, rtcValue);
        drawClockRow(dc, labelRight, valueLeft, h * Y_ROW3, gpsLabel, gpsValue);

        // 底部结果行：搜星中显示上一次结论，观察中显示进度，出结论后放大显示误差
        // （误差是核心数字，单独占一行且放大，不塞回时钟行破坏列对齐）
        if (finished && errorSeconds != null) {
            dc.drawText(cx, h * Y_RESULT, Graphics.FONT_MEDIUM,
                formatErrorSeconds(errorSeconds), Graphics.TEXT_JUSTIFY_CENTER);
        } else if (!finished && gpsBaseMoment != null) {
            dc.drawText(cx, h * Y_RESULT, Graphics.FONT_SMALL,
                secondsAfterFix + "/" + OBSERVE_SECONDS, Graphics.TEXT_JUSTIFY_CENTER);
        } else if (!finished && lastError != null) {
            var hist = str(Rez.Strings.HintLast) + " " + formatErrorSeconds(lastError);
            if (runCount > 0) {
                hist = hist + " · " + runCount + str(Rez.Strings.HintTimes);
            }
            dc.drawText(cx, h * Y_RESULT, Graphics.FONT_XTINY, hist,
                Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    // 采光窗圆环在高度 y 处的左缘 x（圆心/外半径按 176×176 实测比例换算）。
    // 圆窗在设备坐标里是圆心 (143.5, 31.5)、外半径 42.5 —— 圆环外缘会伸出屏幕，
    // 所以不能用屏幕 bbox 求圆心，这里是之前用「左极点 + 下极点」几何法拟合的值。
    function ringLeftAt(y, w, h) {
        var ccx = w * 0.8153;   // 143.5 / 176
        var ccy = h * 0.1790;   // 31.5 / 176
        var rr = w * 0.2415;    // 42.5 / 176
        var dy = y - ccy;

        if (dy < 0) {
            dy = -dy;
        }

        if (dy >= rr) {
            return w;
        }

        try {
            return ccx - Math.sqrt(rr * rr - dy * dy);
        } catch (e) {
            // 理论上不会走到这里；兜底给一个保守值，宁可窄一点也不压圆环
            return w * 0.57;
        }
    }

    // 一行时钟：标签右对齐到同一列、时间左对齐到同一列
    function drawClockRow(dc as Graphics.Dc, labelRight, valueLeft, y, label, value) as Void {
        dc.drawText(labelRight, y, Graphics.FONT_SMALL, label,
            Graphics.TEXT_JUSTIFY_RIGHT);

        dc.drawText(valueLeft, y, Graphics.FONT_SMALL, value,
            Graphics.TEXT_JUSTIFY_LEFT);
    }

    // 文本像素宽度：getTextDimensions 返回 [宽, 高]；取不到就按平均值估算
    function textWidth(dc as Graphics.Dc, text, font) {
        try {
            var dims = dc.getTextDimensions(text, font);
            if (dims != null && dims[0] != null) {
                return dims[0];
            }
        } catch (e) {
            System.println("TTSyncTime textWidth: " + e);
        }

        return text.length() * 7;
    }

    function maxNum(a, b) {
        if (a > b) {
            return a;
        }

        return b;
    }
}
