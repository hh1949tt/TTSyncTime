import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

class TTSyncTimeApp extends Application.AppBase {

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state as Dictionary?) as Void {
    }

    function onStop(state as Dictionary?) as Void {
    }

    function getInitialView() as [Views] or [Views, InputDelegates] {
        var view = new TTSyncTimeView();
        return [ view, new TTSyncTimeDelegate(view) ];
    }
}

function getApp() as TTSyncTimeApp {
    return Application.getApp() as TTSyncTimeApp;
}
