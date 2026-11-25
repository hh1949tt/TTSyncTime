using Toybox.Lang;
using Toybox.WatchUi;

// 按键代理：ENTER 重测一轮，BACK 交回系统（退出 widget）。
class TTSyncTimeDelegate extends WatchUi.InputDelegate {

    var mView;

    function initialize(view) {
        InputDelegate.initialize();
        mView = view;
    }

    function onKey(event as WatchUi.KeyEvent) {
        if (event.getType() == WatchUi.KEY_ENTER && mView != null) {
            mView.retest();
            return true;
        }

        // 其余按键（含 BACK）交给系统默认处理
        return false;
    }
}
