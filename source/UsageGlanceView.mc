import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

//! The glance: Claude's 5h window as a title, a bar, and the figures.
//!
//! Geometry was measured on the device, not assumed. The strip reports 349x130,
//! but that is a *rectangle* on a *round* display and the mask cuts it into a
//! trapezoid — it sits above the screen centre, so the usable left edge moves in
//! as you go up: roughly x=45 at the top, x=30 mid, x=8 near the bottom. That is
//! why the title cannot sit as far left as the bar however much one would like
//! it to; it is set as low as the layout allows to minimise the difference.
//! Text that overruns is clipped silently — not wrapped, not shrunk.
(:glance)
class UsageGlanceView extends WatchUi.GlanceView {

    //! Claude's orange. The whole point of a glance is being recognised without
    //! being read, and the colour does more of that work than any label.
    private const CLAUDE_ORANGE = 0xD97757;

    //! Left inset for the lower rows, where the mask is generous.
    private const PAD = 8;
    //! Left inset for the title row, forced by the mask rather than chosen.
    private const PAD_TITLE = 38;
    //! Right inset for the bar. Larger than PAD because the mask nips the
    //! corner at full width — visible only at 100%, which is exactly when the
    //! glance most needs to look deliberate.
    private const BAR_R = 16;

    //! The used portion is the thing being read, so it is the heavier of the
    //! two. Connect IQ has no progress-bar drawable — WatchUi.ProgressBar is a
    //! full-screen modal and the only Drawables are Bitmap/Text/TextArea/
    //! Selectable — and Garmin's own glance bars are firmware-rendered, so this
    //! is hand-drawn and can only approximate the house style.
    private const USED_H = 14;
    //! The remainder is context, not data: thinner, grey, centred against the
    //! used portion.
    private const REST_H = 6;
    //! Separation between used and remainder.
    private const BAR_GAP = 2;

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

        var w = dc.getWidth();
        var h = dc.getHeight();
        var color = barColor();

        // One font throughout. FONT_GLANCE is the system's own glance face, so
        // mixing sizes here is what made the earlier version look assembled
        // rather than designed.
        var font = Graphics.FONT_GLANCE;

        dc.setColor(CLAUDE_ORANGE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            PAD_TITLE, h * 3 / 10,
            font,
            "Claude",
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER
        );

        drawBar(dc, PAD, h / 2 + 2, w - PAD - BAR_R, color);

        // Figure left, countdown right — the two things actually being compared
        // when deciding whether there is room to start something.
        var baseline = h * 4 / 5;

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            PAD, baseline,
            font,
            _store.fiveText(),
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER
        );

        var reset = resetText();
        if (reset != null) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                w - BAR_R, baseline,
                font,
                reset as String,
                Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER
            );
        }
    }

    //! Used portion thick and coloured, then a gap, then the remainder thin and
    //! grey — so the bar reads as "this much spent" rather than as a container
    //! that happens to be partly filled.
    private function drawBar(
        dc as Graphics.Dc, x as Number, y as Number, w as Number,
        color as Graphics.ColorType
    ) as Void {
        var pct = _store.fivePct;
        var known = (pct != null && !_store.expired && _store.error == null);

        var restY = y + (USED_H - REST_H) / 2;
        if (!known) {
            // Nothing known: draw the remainder alone, full width, so the glance
            // keeps its shape instead of collapsing to text.
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(x, restY, w, REST_H);
            return;
        }

        var clamped = pct as Number;
        if (clamped < 0) { clamped = 0; }
        if (clamped > 100) { clamped = 100; }

        var used = w * clamped / 100;
        // A couple of percent would round to a sliver too thin to register as a
        // bar at all, so anything non-zero draws a visible stub.
        if (clamped > 0 && used < USED_H) {
            used = USED_H;
        }

        if (used > 0) {
            dc.setColor(color, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(x, y, used, USED_H);
        }

        var restX = x + used + BAR_GAP;
        var restW = x + w - restX;
        if (restW > 0) {
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(restX, restY, restW, REST_H);
        }
    }

    //! "4h22m" / "48m", or null when there is nothing meaningful to say.
    private function resetText() as String or Null {
        var m = _store.resetMin;
        if (m == null || _store.expired || _store.error != null) {
            return null;
        }
        var mins = m as Number;
        if (mins < 60) {
            return mins.toString() + "m";
        }
        return (mins / 60).toString() + "h" + (mins % 60).toString() + "m";
    }

    //! Claude orange normally, red once the window is nearly gone. No amber
    //! tier: the base colour is already orange, so a third step would read as
    //! noise rather than as a warning.
    private function barColor() as Graphics.ColorType {
        var pct = _store.fivePct;
        if (_store.error != null || _store.expired || pct == null) {
            return Graphics.COLOR_DK_GRAY;
        }
        if (pct >= 90) {
            return Graphics.COLOR_RED;
        }
        return CLAUDE_ORANGE;
    }
}
