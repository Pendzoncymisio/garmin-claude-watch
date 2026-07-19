import Toybox.Lang;
import Toybox.WatchUi;

//! Tap or select re-fetches. Deliberately does not try to make Claude Code
//! produce fresher figures — nothing can, from outside a live session — so this
//! only picks up a status-line render that has happened since the view opened.
class UsageDelegate extends WatchUi.BehaviorDelegate {

    private var _view as UsageView;

    function initialize(view as UsageView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    function onSelect() as Boolean {
        _view.refresh();
        return true;
    }

    function onTap(evt as WatchUi.ClickEvent) as Boolean {
        _view.refresh();
        return true;
    }
}
