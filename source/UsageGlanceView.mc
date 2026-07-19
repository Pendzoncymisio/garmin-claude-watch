import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

//! The glance: the 5h limit and nothing else.
//!
//! Text that overruns the strip is silently clipped — not wrapped, not shrunk —
//! so this stays deliberately short. Everything else lives in UsageView, one
//! press away.
(:glance)
class UsageGlanceView extends WatchUi.GlanceView {

    private var _store as UsageStore;

    function initialize(store as UsageStore) {
        GlanceView.initialize();
        _store = store;
    }

    //! Fire the request here, not in onUpdate: onUpdate runs on every redraw.
    function onShow() as Void {
        _store.refresh(null);
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_TRANSPARENT, Graphics.COLOR_BLACK);
        dc.clear();

        var y = dc.getHeight() / 2;
        var text = "5h " + _store.fiveText();
        if (_store.stale) {
            // The figure is real but describes a session that stopped updating,
            // so mark it rather than let an old number read as current.
            text += "?";
        }

        dc.setColor(colorFor(_store.fivePct), Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            4, y,
            Graphics.FONT_GLANCE,
            text,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }

    //! Colour is the whole point of a glance — it should be readable without
    //! being read. Thresholds are deliberately pessimistic: amber well before
    //! the limit actually bites.
    private function colorFor(pct as Number or Null) as Graphics.ColorType {
        if (_store.error != null || pct == null) {
            return Graphics.COLOR_LT_GRAY;
        }
        if (pct >= 90) {
            return Graphics.COLOR_RED;
        }
        if (pct >= 70) {
            return Graphics.COLOR_ORANGE;
        }
        return Graphics.COLOR_WHITE;
    }
}
