import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

//! The glance: the 5h window as a figure and a bar.
//!
//! The strip is 349x130 on this device (measured, not assumed) and FONT_GLANCE
//! is 42px tall, which fits roughly 13 characters across. Text that overruns is
//! clipped silently — not wrapped, not shrunk — so the label stays short and the
//! bar carries the at-a-glance meaning. Everything else lives in UsageView, one
//! press away.
(:glance)
class UsageGlanceView extends WatchUi.GlanceView {

    //! Left inset. The system draws its own chrome hard against the left edge,
    //! so nothing useful can start at x=0.
    private const PAD = 4;

    //! Deliberately thin. Connect IQ has no progress-bar drawable — WatchUi's
    //! ProgressBar is a full-screen modal, and the only Drawables are Bitmap,
    //! Text, TextArea and Selectable — so this is hand-drawn, and Garmin's own
    //! glance bars are firmware-rendered and cannot be matched exactly. Thin and
    //! square reads closer to the native style than a thick rounded pill.
    private const BAR_H = 10;

    //! Gap between the figure and the bar.
    private const GAP = 8;

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
        var color = colorFor(_store.fivePct);

        // Centre the whole block vertically rather than hanging it from the top:
        // this glance sits first in the carousel, where the strip is centred on
        // the display and top-aligned content reads as floating.
        var textH = dc.getFontHeight(Graphics.FONT_GLANCE);
        var blockH = textH + GAP + BAR_H;
        var textY = (h - blockH) / 2 + textH / 2;
        var barY = (h - blockH) / 2 + textH + GAP;

        var label = "5h " + _store.fiveText();
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            PAD, textY,
            Graphics.FONT_GLANCE,
            label,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER
        );

        // Reset countdown, placed just after the figure by measuring it.
        // Right-aligning to the rect edge clips: the strip is a 349px rectangle
        // but the round display masks it, and this row sits above centre where
        // the visible width is narrower than the rectangle claims.
        var reset = resetText();
        if (reset != null) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                PAD + dc.getTextWidthInPixels(label, Graphics.FONT_GLANCE) + GAP * 2,
                textY,
                Graphics.FONT_XTINY,
                reset as String,
                Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER
            );
        }

        drawBar(dc, PAD, barY, w - PAD * 2, color);
    }

    //! Track plus fill. An empty track is still drawn when the figure is unknown
    //! so the glance keeps a consistent shape rather than collapsing to text.
    private function drawBar(
        dc as Graphics.Dc, x as Number, y as Number, w as Number,
        color as Graphics.ColorType
    ) as Void {
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(x, y, w, BAR_H);

        var pct = _store.fivePct;
        if (pct == null || _store.expired || _store.error != null) {
            return;
        }

        var clamped = pct as Number;
        if (clamped < 0) { clamped = 0; }
        if (clamped > 100) { clamped = 100; }

        // A few percent would round to a sliver too thin to read as a bar, so
        // anything non-zero draws at least a small visible stub.
        var fill = w * clamped / 100;
        if (clamped > 0 && fill < BAR_H) {
            fill = BAR_H;
        }
        if (fill <= 0) {
            return;
        }

        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(x, y, fill, BAR_H);
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

    //! Colour is the whole point of a glance — it should be readable without
    //! being read. Thresholds are deliberately pessimistic: amber well before
    //! the limit actually bites.
    private function colorFor(pct as Number or Null) as Graphics.ColorType {
        if (_store.error != null || _store.expired || pct == null) {
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
