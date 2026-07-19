import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

//! The full view: both limits, plus how old the figures are.
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

    //! Re-fetch on tap. This cannot produce *newer* figures — Claude Code only
    //! emits them to the status line of a live session, and there is no way to
    //! force that from outside — but it does pick up a render that happened
    //! since the view opened, which is the common case when a session is
    //! running on the machine.
    function refresh() as Void {
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
        // bezel to bezel at FONT_MEDIUM and sits above centre, where a round
        // display is already narrowing. Verified against that worst case, with
        // no margin left: anything added to this row needs re-checking at 100%
        // with a >1h reset, or it will clip silently.
        var rowH = dc.getFontHeight(Graphics.FONT_MEDIUM);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        drawCentered(dc, cx, cy - rowH * 3 / 2, Graphics.FONT_SMALL, "Claude usage");

        drawRow(dc, cx, cy - rowH / 2, "5h", _store.fivePct, resetSuffix());
        drawRow(dc, cx, cy + rowH / 2, "7d", _store.sevenPct, "");

        drawFooter(dc, cx, cy + rowH * 3 / 2);
    }

    //! One line saying how old the numbers are, and why if there is a reason.
    //!
    //! This earns its space: the figures cannot be refreshed on demand, so
    //! "when was this true" is the difference between a number the user can act
    //! on and one that is merely plausible.
    private function drawFooter(dc as Graphics.Dc, cx as Number, y as Number) as Void {
        var text = "upd " + _store.ageText();
        var color = Graphics.COLOR_DK_GRAY;

        if (_store.demo) {
            // Invented figures. Say so plainly — this is the only thing on
            // screen that distinguishes them from real ones.
            text = "demo data";
            color = Graphics.COLOR_YELLOW;
        } else if (_store.expired) {
            // Strictly more important than staleness: the window rolled over, so
            // the stored percentage is not merely old, it is wrong.
            text = "window reset";
            color = Graphics.COLOR_YELLOW;
        } else if (_store.stale) {
            text += " - no live session";
            color = Graphics.COLOR_LT_GRAY;
        }

        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        drawCentered(dc, cx, y, Graphics.FONT_XTINY, text);
    }

    private function drawRow(
        dc as Graphics.Dc, cx as Number, y as Number,
        label as String, pct as Number or Null, suffix as String
    ) as Void {
        var shown = (_store.expired && label.equals("5h")) ? null : pct;
        var text = label + "  " + (shown == null ? "--" : shown.toString() + "%") + suffix;
        dc.setColor(colorFor(shown), Graphics.COLOR_TRANSPARENT);
        drawCentered(dc, cx, y, Graphics.FONT_MEDIUM, text);
    }

    //! "5h 44%  4h43m" — the reset countdown is what decides whether to keep
    //! working or wait, so it earns its place next to the percentage.
    private function resetSuffix() as String {
        var m = _store.resetMin;
        if (m == null || _store.expired) {
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
