import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

//! Entry point. The glance and the full view share one UsageStore so opening the
//! glance does not throw away what the strip already fetched.
class ClaudeApp extends Application.AppBase {

    //! Built lazily and separately per scope: the glance and the watch app are
    //! distinct runtimes with distinct memory budgets, never alive together.
    private var _store as UsageStore or Null;

    function initialize() {
        AppBase.initialize();
    }

    (:glance)
    function getGlanceView() as [WatchUi.GlanceView] or [WatchUi.GlanceView, WatchUi.GlanceViewDelegate] or Null {
        return [new UsageGlanceView(store())];
    }

    //! (:typecheck(false)) because ClaudeApp is pulled into the glance code space
    //! by getGlanceView above, and UsageView deliberately is not — so the strict
    //! checker sees an unresolvable symbol in that scope. Never called in glance
    //! context at runtime, so the reference is safe; annotating UsageView
    //! (:glance) would "fix" it by charging a full-screen view against 64 KB.
    (:typecheck(false))
    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        return [new UsageView(store())];
    }

    (:glance)
    private function store() as UsageStore {
        var s = _store;
        if (s == null) {
            s = new UsageStore();
            _store = s;
        }
        return s;
    }
}
