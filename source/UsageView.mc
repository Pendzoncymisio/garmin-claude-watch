import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

//! The full view: every limit, shown when the glance is opened.
//!
//! Not (:glance)-annotated, so none of this counts against the 64 KB glance
//! budget — it may use the full watch-app allowance.
class UsageView extends WatchUi.View {

    private var _store as UsageStore;

    function initialize(store as UsageStore) {
        View.initialize();
        _store = store;
    }

    function onShow() as Void {
        _store.refresh(null);
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_TRANSPARENT, Graphics.COLOR_BLACK);
        dc.clear();

        var cx = dc.getWidth() / 2;
        var cy = dc.getHeight() / 2;

        if (_store.error != null) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            drawCentered(dc, cx, cy, Graphics.FONT_MEDIUM, _store.error as String);
            return;
        }

        // The 5h row is the widest thing drawn — "5h 100% 4h58m" reaches nearly
        // bezel to bezel at FONT_MEDIUM and sits one row above centre, where a
        // round display is already narrowing. Verified against that worst case,
        // but there is no margin left: anything added to this row needs
        // re-checking at 100% with a >1h reset, or it will clip silently.
        var rowH = dc.getFontHeight(Graphics.FONT_MEDIUM);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        drawCentered(dc, cx, cy - rowH * 2, Graphics.FONT_SMALL, "Claude usage");

        drawRow(dc, cx, cy - rowH, "5h", _store.fivePct, resetSuffix());
        drawRow(dc, cx, cy, "7d", _store.sevenPct, "");
        drawRow(dc, cx, cy + rowH, "ctx", _store.ctxPct, "");

        if (_store.stale) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            drawCentered(dc, cx, cy + rowH * 2, Graphics.FONT_XTINY, "no live session");
        }
    }

    private function drawRow(
        dc as Graphics.Dc, cx as Number, y as Number,
        label as String, pct as Number or Null, suffix as String
    ) as Void {
        var text = label + "  " + (pct == null ? "--" : pct.toString() + "%") + suffix;
        dc.setColor(colorFor(pct), Graphics.COLOR_TRANSPARENT);
        drawCentered(dc, cx, y, Graphics.FONT_MEDIUM, text);
    }

    //! "5h 44%  4h49m" — the reset time is what decides whether to keep working
    //! or wait, so it earns its place next to the percentage.
    private function resetSuffix() as String {
        var m = _store.resetMin;
        if (m == null) {
            return "";
        }
        var mins = m as Number;
        if (mins < 60) {
            return "  " + mins.toString() + "m";
        }
        return "  " + (mins / 60).toString() + "h" + (mins % 60).toString() + "m";
    }

    private function colorFor(pct as Number or Null) as Graphics.ColorType {
        if (pct == null) {
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

    private function drawCentered(
        dc as Graphics.Dc, cx as Number, y as Number,
        font as Graphics.FontType, text as String
    ) as Void {
        dc.drawText(cx, y, font, text,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }
}
