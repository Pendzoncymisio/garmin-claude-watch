import Toybox.Application;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.WatchUi;

//! Fetches usage from the bridge and caches it.
//!
//! Shared by the glance and the full view, so it carries (:glance) and every
//! symbol it touches must too — un-annotated code is excluded from glance scope,
//! which is what keeps that view inside 64 KB.
//!
//! Values are cached in Storage because the glance is stopped and restarted
//! rather than kept resident: without the cache the strip would show "--" every
//! time it is opened, until the request lands.
(:glance)
class UsageStore {

    private const KEY_FIVE = "five";
    private const KEY_SEVEN = "seven";
    private const KEY_RESET = "reset";
    private const KEY_STALE = "stale";
    private const KEY_ERR = "err";

    //! Percentages, or null when never fetched.
    public var fivePct as Number or Null;
    public var sevenPct as Number or Null;
    //! Minutes until the 5h window resets.
    public var resetMin as Number or Null;
    //! Server judged the capture too old to present as current.
    public var stale as Boolean = false;
    //! The captured 5h window has since rolled over, so the percentage refers to
    //! a window that no longer exists.
    public var expired as Boolean = false;
    //! Seconds since capture, for the "updated" line.
    public var ageS as Number = 0;
    //! Showing invented figures. Must be surfaced in the UI — a plausible fake
    //! that reads as real is worse than an obvious error.
    public var demo as Boolean = false;
    //! Short human-readable failure, or null when the last fetch was fine.
    public var error as String or Null;

    private var _pending as Boolean = false;
    private var _onDone as Method(success as Boolean) as Void or Null;

    function initialize() {
        fivePct = Storage.getValue(KEY_FIVE) as Number or Null;
        sevenPct = Storage.getValue(KEY_SEVEN) as Number or Null;
        resetMin = Storage.getValue(KEY_RESET) as Number or Null;
        var s = Storage.getValue(KEY_STALE);
        stale = (s instanceof Boolean) ? s : false;
        error = Storage.getValue(KEY_ERR) as String or Null;
    }

    //! Fire a fetch. onDone may be null; it exists so the background service can
    //! decide whether to raise a notification once the data has landed.
    function refresh(onDone as Method(success as Boolean) as Void or Null) as Void {
        if (_pending) {
            return;
        }

        // Demo mode ships enabled so a fresh install shows a working-looking
        // screen rather than an error. A real watch cannot reach the dev bridge
        // at all — device HTTPS rules are enforced in firmware and cannot be
        // relaxed as they can in the simulator, so a privately-signed
        // certificate is rejected outright. Turn this off in the app settings
        // once the bridge is reachable over a publicly-trusted certificate.
        var demoValue = Properties.getValue("DemoMode");
        demo = !(demoValue instanceof Boolean) || (demoValue as Boolean);
        if (demo) {
            fivePct = 55;
            sevenPct = 12;
            resetMin = 236;
            stale = false;
            expired = false;
            ageS = 0;
            error = null;
            WatchUi.requestUpdate();
            if (onDone != null) {
                onDone.invoke(true);
            }
            return;
        }

        var url = Properties.getValue("ServerUrl");
        if (!(url instanceof String) || (url as String).length() == 0) {
            setError("no url");
            return;
        }
        _onDone = onDone;
        _pending = true;

        // Two literal option dictionaries rather than one built by mutation:
        // under --typecheck 3 the literal's value type is inferred from its
        // contents, so adding :headers afterwards fights the checker for no gain.
        var endpoint = (url as String) + "/usage";
        var headers = authHeaders();
        if (headers == null) {
            Communications.makeWebRequest(
                endpoint,
                {},
                {
                    :method => Communications.HTTP_REQUEST_METHOD_GET,
                    :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
                },
                method(:onUsage)
            );
        } else {
            Communications.makeWebRequest(
                endpoint,
                {},
                {
                    :method => Communications.HTTP_REQUEST_METHOD_GET,
                    :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON,
                    :headers => headers
                },
                method(:onUsage)
            );
        }
    }

    //! Cloudflare Access service token, or null when the bridge is unprotected.
    //!
    //! Both halves go in ONE Authorization header as JSON, rather than the usual
    //! pair of CF-Access-Client-Id / CF-Access-Client-Secret headers. Access
    //! reads this form when the application sets read_service_tokens_from_header,
    //! and asking makeWebRequest for a single well-known header rather than two
    //! custom ones is the safer bet — custom headers are the least reliable part
    //! of Connect IQ networking.
    //!
    //! Empty settings mean no header at all, which is what a LAN bridge with no
    //! Access in front of it needs. Credentials live only in the app settings on
    //! the device; there are no defaults in the source, and there must not be.
    private function authHeaders() as Dictionary or Null {
        var id = Properties.getValue("AccessClientId");
        var secret = Properties.getValue("AccessClientSecret");
        if (!(id instanceof String) || !(secret instanceof String)) {
            return null;
        }
        if ((id as String).length() == 0 || (secret as String).length() == 0) {
            return null;
        }
        return {
            "Authorization" =>
                "{\"cf-access-client-id\":\"" + (id as String) +
                "\",\"cf-access-client-secret\":\"" + (secret as String) + "\"}"
        };
    }

    function onUsage(code as Number, data as Dictionary or String or Null) as Void {
        _pending = false;

        if (code != 200) {
            // 404 means the bridge is up but the status line has never run, so
            // there is genuinely nothing to show yet — worth distinguishing from
            // a transport failure the user might fix by checking the server.
            var msg = "err " + code.toString();
            if (code == 404) {
                msg = "no data";
            } else if (code == 401) {
                // Reached the bridge, but Access did not vouch for us, or the
                // bridge rejected the assertion. A credential problem, not a
                // connectivity one — say so, because the fix is different.
                msg = "bad token";
            } else if (code == 403) {
                // Access itself refused before the bridge was ever reached:
                // no token sent, or one that is not on this application.
                msg = "no access";
            } else if (code == 503) {
                msg = "srv busy";
            } else if (code == Communications.SECURE_CONNECTION_REQUIRED) {
                msg = "need https";
            } else if (code == Communications.BLE_CONNECTION_UNAVAILABLE) {
                msg = "no phone";
            }
            setError(msg);
            notifyDone(false);
            return;
        }
        if (!(data instanceof Dictionary)) {
            setError("bad resp");
            notifyDone(false);
            return;
        }

        fivePct = numberAt(data, "five_pct");
        sevenPct = numberAt(data, "seven_pct");
        resetMin = numberAt(data, "five_resets_in_min");
        var st = data["stale"];
        stale = (st instanceof Boolean) ? st : false;
        var ex = data["window_expired"];
        expired = (ex instanceof Boolean) ? ex : false;
        var a = numberAt(data, "age_s");
        ageS = (a == null) ? 0 : a as Number;
        error = null;

        Storage.setValue(KEY_FIVE, fivePct);
        Storage.setValue(KEY_SEVEN, sevenPct);
        Storage.setValue(KEY_RESET, resetMin);
        Storage.setValue(KEY_STALE, stale);
        Storage.setValue(KEY_ERR, null);

        WatchUi.requestUpdate();
        notifyDone(true);
    }

    //! JSON numbers arrive as Number or Float depending on the value; the server
    //! rounds percentages but a Float would still fail an instanceof Number test.
    //! Takes the dictionary and key rather than the value: indexing an untyped
    //! JSON Dictionary yields Any, which strict typecheck refuses to pass as a
    //! parameter. Doing the lookup in here keeps that Any local, where it can be
    //! narrowed by instanceof.
    private function numberAt(d as Dictionary, key as String) as Number or Null {
        var v = d[key];
        if (v instanceof Number) {
            return v;
        }
        if (v instanceof Float || v instanceof Double) {
            return (v as Float).toNumber();
        }
        return null;
    }

    private function setError(msg as String) as Void {
        error = msg;
        Storage.setValue(KEY_ERR, msg);
        WatchUi.requestUpdate();
    }

    private function notifyDone(success as Boolean) as Void {
        var cb = _onDone;
        _onDone = null;
        if (cb != null) {
            cb.invoke(success);
        }
    }

    //! "44%" or "--" — the glance never has room for more than this.
    //!
    //! A rolled-over window reports "--" rather than the stored percentage: once
    //! the 5h window resets the captured figure describes a window that no
    //! longer exists, and showing it would overstate usage — the one direction
    //! that matters, since the point is deciding whether to start working.
    function fiveText() as String {
        if (error != null) {
            return error as String;
        }
        if (expired || fivePct == null) {
            return "--";
        }
        return (fivePct as Number).toString() + "%";
    }

    //! "now" / "12m" / "3h". Deliberately coarse: the exact age never matters,
    //! only whether these numbers can still be trusted.
    function ageText() as String {
        if (error != null) {
            return "--";
        }
        if (ageS < 90) {
            return "now";
        }
        if (ageS < 3600) {
            return (ageS / 60).toString() + "m";
        }
        return (ageS / 3600).toString() + "h";
    }
}
