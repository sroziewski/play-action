#!/usr/bin/env python3
"""Drives the recorder's Chrome over the DevTools protocol.

  browse.py open URL   navigate; on YouTube also skip consent, wait out ads,
                       pick the original audio track, go fullscreen and
                       pause at 0:00 so the recording starts on frame one
  browse.py play       resume the paused YouTube video; elsewhere click the
                       page's .play-action play button, if it has one

With COOKIES set to a cookies.txt or JSON export, those cookies are loaded
before the page opens, so it opens logged in.
"""
import json
import os
import re
import sys
import time
import urllib.request

import websocket

DEVTOOLS = "http://127.0.0.1:9222"
YOUTUBE = re.compile(r"^https?://([a-z0-9-]+\.)?(youtube\.com/(watch|shorts/|live/)|youtu\.be/)")


def log(msg):
    print(f"browse: {msg}", flush=True)


class Page:
    def __init__(self):
        targets = json.load(urllib.request.urlopen(f"{DEVTOOLS}/json", timeout=5))
        page = next(t for t in targets if t["type"] == "page")
        # Chrome refuses DevTools websockets that send an Origin header.
        self.ws = websocket.create_connection(page["webSocketDebuggerUrl"], suppress_origin=True, timeout=30)
        self.seq = 0

    def call(self, method, **params):
        self.seq += 1
        self.ws.send(json.dumps({"id": self.seq, "method": method, "params": params}))
        while True:
            msg = json.loads(self.ws.recv())
            if msg.get("id") == self.seq:
                if "error" in msg:
                    raise RuntimeError(f"{method}: {msg['error']}")
                return msg.get("result", {})

    def js(self, expression):
        result = self.call("Runtime.evaluate", expression=expression,
                           awaitPromise=True, returnByValue=True)
        if "exceptionDetails" in result:
            raise RuntimeError(result["exceptionDetails"].get("text", "script error"))
        return result["result"].get("value")

    def wait_for(self, expression, timeout, what):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                if self.js(expression):
                    return True
            except RuntimeError:
                pass  # the page navigated mid-call ("Execution context was destroyed")
            time.sleep(0.5)
        log(f"gave up waiting for {what} after {timeout}s")
        return False

    def press(self, key, code, key_code):
        for kind in ("keyDown", "keyUp"):
            self.call("Input.dispatchKeyEvent", type=kind, key=key, code=code,
                      windowsVirtualKeyCode=key_code)


PLAYER = "document.querySelector('#movie_player')"

# YouTube flags the dub matching the viewer's language as the default track,
# so the original is identified through the captions renderer's
# defaultAudioTrackIndex instead; track objects have minified field names,
# hence the search for whichever property carries an `id`.
SELECT_ORIGINAL_AUDIO = f"""(() => {{
  const p = {PLAYER};
  const tracks = p.getAvailableAudioTracks?.() ?? [];
  if (tracks.length < 2) return 'single track';
  const r = p.getPlayerResponse()?.captions?.playerCaptionsTracklistRenderer;
  const originalId = r?.audioTracks?.[r?.defaultAudioTrackIndex]?.audioTrackId;
  const idOf = t => Object.values(t ?? {{}}).find(v => v?.id)?.id ?? null;
  const nameOf = t => String(Object.values(t ?? {{}}).find(v => v?.name)?.name ?? '');
  const target = tracks.find(t => originalId && idOf(t) === originalId)
              ?? tracks.find(t => /original/i.test(nameOf(t)));
  if (!target) return 'original not found among ' + tracks.length + ' tracks';
  if (idOf(p.getAudioTrack()) !== idOf(target)) p.setAudioTrack(target);
  return 'original: ' + (nameOf(target) || idOf(target));
}})()"""

ON_ORIGINAL_AUDIO = f"""(() => {{
  const p = {PLAYER};
  const r = p.getPlayerResponse()?.captions?.playerCaptionsTracklistRenderer;
  const originalId = r?.audioTracks?.[r?.defaultAudioTrackIndex]?.audioTrackId;
  const idOf = t => Object.values(t ?? {{}}).find(v => v?.id)?.id ?? null;
  const nameOf = t => String(Object.values(t ?? {{}}).find(v => v?.name)?.name ?? '');
  if ((p.getAvailableAudioTracks?.() ?? []).length < 2) return true;
  return originalId ? idOf(p.getAudioTrack()) === originalId
                    : /original/i.test(nameOf(p.getAudioTrack()));
}})()"""

CAPTIONS_OFF = """(() => {
  const b = document.querySelector('#movie_player .ytp-subtitles-button');
  if (b?.getAttribute('aria-pressed') === 'true') b.click();
  return b?.getAttribute('aria-pressed') !== 'true';
})()"""


def keep_original_audio(page, seconds):
    """YouTube re-selects the dub for the viewer's language for a while after
    load, so re-apply until the original has held for `seconds`."""
    held_since = None
    deadline = time.monotonic() + 20
    note = "audio track unchanged"
    while time.monotonic() < deadline:
        try:
            if page.js(ON_ORIGINAL_AUDIO):
                held_since = held_since or time.monotonic()
                if time.monotonic() - held_since >= seconds:
                    return note
            else:
                held_since = None
                note = page.js(SELECT_ORIGINAL_AUDIO)
        except RuntimeError:
            held_since = None
        time.sleep(0.3)
    return "original audio track did not stick"


# Known consent-manager buttons first; otherwise a button whose label reads
# like reject/accept, but only inside a floating box (fixed/sticky or a
# dialog) that talks about cookies. A newsletter form with privacy wording
# in the page itself must never be submitted.
DISMISS_BANNER = r"""((choice) => {
  const known = {
    reject: ['#onetrust-reject-all-handler', '#CybotCookiebotDialogBodyButtonDecline',
      '#didomi-notice-disagree-button', '#cc-main .cm__btn[data-role=necessary]', '.cky-btn-reject',
      '.cmplz-btn.cmplz-deny', '[data-testid=uc-deny-all-button]', '.fc-cta-do-not-consent',
      '.qc-cmp2-summary-buttons button[mode=secondary]', '#truste-consent-required',
      '.klaro .cn-decline', '#cookiescript_reject', '.iubenda-cs-reject-btn'],
    accept: ['#onetrust-accept-btn-handler', '#CybotCookiebotDialogBodyLevelButtonLevelOptinAllowAll',
      '#didomi-notice-agree-button', '#cc-main .cm__btn[data-role=all]', '.cky-btn-accept',
      '.cmplz-btn.cmplz-accept', '[data-testid=uc-accept-all-button]', '.fc-cta-consent',
      '.qc-cmp2-summary-buttons button[mode=primary]', '#truste-consent-button',
      '.klaro .cm-btn-accept-all', '#cookiescript_accept', '.iubenda-cs-accept-btn'],
  };
  const words = {
    reject: /^(odrzuć|odrzuc|nie zgadzam|tylko (niezbędne|wymagane|konieczne)|reject|decline|deny|refuse|disagree|(use )?(only )?(strictly )?necessary( cookies)?( only)?|ablehnen|alle ablehnen|nur (notwendige|erforderliche)|refuser|tout refuser|continuer sans accepter|rechazar|rifiuta|rifiutare)/i,
    accept: /^(zaakceptuj|akceptuj|akceptuję|zgadzam się|przejdź do serwisu|accept|agree|allow( all)?|got it|alle akzeptieren|akzeptieren|zustimmen|accepter|tout accepter|j'accepte|aceptar|accetta|accetto)/i,
  };
  const about = /cookie|ciastecz|consent|zgod|prywatno|privacy|datenschutz|rgpd|gdpr|rodo/i;
  const visible = el => el.getClientRects().length > 0 && getComputedStyle(el).visibility !== 'hidden';
  const roots = [document];
  for (let i = 0; i < roots.length; i++)
    for (const el of roots[i].querySelectorAll('*')) if (el.shadowRoot) roots.push(el.shadowRoot);

  for (const root of roots)
    for (const sel of known[choice]) {
      const el = root.querySelector(sel);
      if (el && visible(el)) { el.click(); return 'clicked ' + sel; }
    }
  for (const root of roots)
    for (const el of root.querySelectorAll('button, a, [role=button], input[type=button], input[type=submit]')) {
      const label = (el.innerText || el.value || el.getAttribute('aria-label') || '').trim();
      if (!label || label.length > 40 || !words[choice].test(label) || !visible(el)) continue;
      let box = null;
      for (let a = el; a && a !== document.body; a = a.parentElement || a.getRootNode().host) {
        const pos = getComputedStyle(a).position;
        if (pos === 'fixed' || pos === 'sticky' || a.getAttribute('role') === 'dialog'
            || a.getAttribute('aria-modal') === 'true' || a.tagName === 'DIALOG') { box = a; break; }
      }
      if (box && about.test(box.innerText || box.textContent || '')) { el.click(); return 'clicked "' + label + '"'; }
    }
  return null;
})"""


def dismiss_cookie_banner(page, choice):
    """Banners often appear a moment after load and some ask twice (a second
    "are you sure" step), so keep looking until nothing has shown up for a while."""
    page.wait_for("document.readyState === 'complete'", 30, "the page to load")
    clicks = []
    last_click = None
    deadline = time.monotonic() + 12
    # Before the first click, wait the whole window: consent scripts often
    # load seconds after the page. After a click, 3 quiet seconds are enough.
    while time.monotonic() < deadline and not (last_click and time.monotonic() - last_click > 3):
        try:
            result = page.js(f"{DISMISS_BANNER}({json.dumps(choice)})")
        except RuntimeError:
            result = None  # page navigated, e.g. reloaded after the choice
        if result:
            clicks.append(result)
            last_click = time.monotonic()
        time.sleep(0.5)
    log(f"cookie banner ({choice}): {'; '.join(clicks)}" if clicks else "no cookie banner found")


SAME_SITE = {"no_restriction": "None", "none": "None", "lax": "Lax", "strict": "Strict"}


def cdp_cookie(name, value, domain, path, secure, http_only, expires, host_only, same_site=None):
    """Maps an exported cookie to Network.setCookies' shape, or None if expired."""
    if expires and expires < time.time():
        return None
    c = {"name": name, "value": value, "path": path or "/", "secure": secure, "httpOnly": http_only}
    if host_only:
        # A `domain` would widen the cookie to subdomains (and breaks
        # __Host- cookies), so host-only cookies are pinned through a URL.
        c["url"] = f"{'https' if secure else 'http'}://{domain.lstrip('.')}{c['path']}"
    else:
        c["domain"] = domain if domain.startswith(".") else "." + domain
    if expires:
        c["expires"] = expires
    same_site = SAME_SITE.get(str(same_site).lower()) if same_site else None
    if same_site and (same_site != "None" or secure):  # SameSite=None needs Secure
        c["sameSite"] = same_site
    return c


def read_cookies(path):
    """Reads a cookies.txt (Netscape format) or a JSON export from a cookie
    extension such as "Get cookies.txt LOCALLY" or Cookie-Editor."""
    with open(path, encoding="utf-8-sig") as f:
        text = f.read()
    cookies = []
    if text.lstrip().startswith(("[", "{")):
        data = json.loads(text)
        for c in data.get("cookies", []) if isinstance(data, dict) else data:
            cookies.append(cdp_cookie(
                c["name"], c["value"], c["domain"], c.get("path"), bool(c.get("secure")),
                bool(c.get("httpOnly")), float(c.get("expirationDate") or c.get("expires") or 0),
                c.get("hostOnly", not c["domain"].startswith(".")), c.get("sameSite")))
    else:
        for line in text.splitlines():
            http_only = line.startswith("#HttpOnly_")
            if http_only:
                line = line[len("#HttpOnly_"):]
            fields = line.rstrip("\r").split("\t")
            if line.startswith("#") or len(fields) < 7:
                continue
            domain, subdomains, cpath, secure, expires, name = fields[:6]
            cookies.append(cdp_cookie(
                name, "\t".join(fields[6:]), domain, cpath, secure.upper() == "TRUE",
                http_only, float(expires or 0), subdomains.upper() != "TRUE"))
    return [c for c in cookies if c]


def load_cookies(page, path):
    cookies = read_cookies(path)
    if not cookies:
        log("no usable cookies in the file (expected a cookies.txt or JSON export; expired ones are skipped)")
        return
    page.call("Network.enable")
    loaded = 0
    for c in cookies:
        try:
            page.call("Network.setCookie", **c)
            loaded += 1
        except RuntimeError as e:
            # Values stay out of the log: the file is a login.
            log(f"skipped cookie {c['name']} for {c.get('domain') or c.get('url')}: {e}")
    sites = {(c.get("domain") or c["url"].split("/")[2]).lstrip(".") for c in cookies}
    log(f"loaded {loaded} cookies for {len(sites)} sites")


def open_url(url):
    page = Page()
    youtube = bool(YOUTUBE.match(url))
    cookie_file = os.environ.get("COOKIES")
    if cookie_file:
        # A bad file must not keep the page from opening at all.
        try:
            load_cookies(page, cookie_file)
        except (OSError, ValueError, KeyError, TypeError) as e:
            log(f"could not read cookies from {cookie_file}: {e!r}")
    if youtube:
        # Pre-accepting consent keeps the "Before you continue" dialog away;
        # it would otherwise sit on top of the paused player.
        page.call("Network.enable")
        page.call("Network.setCookie", name="SOCS", value="CAI", domain=".youtube.com",
                  path="/", secure=True)
    # Without cookies or YouTube, Chrome was started on the URL already; with
    # cookies it starts on about:blank (see entrypoint.sh), and for YouTube it
    # opened the URL before SOCS existed.
    if youtube or cookie_file:
        page.call("Page.navigate", url=url)
    if not youtube:
        banner = os.environ.get("COOKIE_BANNER", "reject")
        if banner in ("reject", "accept"):
            dismiss_cookie_banner(page, banner)
        return

    # The player object appears long before the page finishes loading; acting
    # earlier lets YouTube's late init undo fullscreen and the audio choice.
    ready = (f"document.readyState === 'complete' && !!document.querySelector('ytd-watch-flexy, ytd-shorts')"
             f" && !!{PLAYER}?.getPlayerResponse?.()?.videoDetails")
    if not page.wait_for(ready, 45, "the YouTube player"):
        if page.js("/confirm you.re not a bot/i.test(document.body.innerText)"):
            log("YouTube wants a sign-in to confirm you're not a bot; recording the page as is")
        return
    page.wait_for(f"!{PLAYER}.classList.contains('ad-showing')", 120, "ads to finish")

    # Whatever fails below, the video must still be rewound and paused, or the
    # recording would start somewhere in the middle of it.
    try:
        log(keep_original_audio(page, 2))
        if not page.js(CAPTIONS_OFF):
            log("could not turn captions off")

        if os.environ.get("YT_FULLSCREEN", "1") == "1":
            for _ in range(3):
                page.js(f"{PLAYER}.focus()")
                page.press("f", "KeyF", 70)
                if page.wait_for(f"{PLAYER}.classList.contains('ytp-fullscreen')", 3, "fullscreen"):
                    break
            else:
                log("could not switch the video to fullscreen")
    finally:
        page.js(f"{PLAYER}.pauseVideo(), {PLAYER}.seekTo(0, true)")
        # Hide the controls the pause and keypress brought up.
        page.js(f"{PLAYER}.dispatchEvent(new MouseEvent('mouseleave'))")
        # Chrome's "press Esc to exit full screen" banner shows for a few seconds.
        time.sleep(4)


# Players commonly ignore el.click() (isTrusted is false, or they listen for
# mousedown/pointerdown only), so this only locates the button and the click
# goes through Input.dispatchMouseEvent as real mouse input. `covered` names
# whatever would take the click instead, e.g. a leftover overlay.
SPOT = """((selectors) => {
  for (const sel of selectors) {
    const el = document.querySelector(sel);
    if (!el) continue;
    el.scrollIntoView({block: 'center'});
    const r = el.getBoundingClientRect();
    if (!r.width || !r.height) continue;
    const x = r.x + r.width / 2, y = r.y + r.height / 2;
    const top = document.elementFromPoint(x, y);
    const covered = top && !el.contains(top) && !top.contains(el)
      ? top.tagName.toLowerCase() + (top.id ? '#' + top.id : '') + (top.className ? '.' + String(top.className).trim().split(/\\s+/).join('.') : '')
      : null;
    return {sel, x, y, covered};
  }
  return null;
})"""

PLAY_BUTTONS = [".play-action .podp", ".play-action", ".glownybutton.play"]
FULLSCREEN_BUTTONS = [".shaka-fullscreen-button"]


def click_first(page, selectors, what, timeout):
    """Real mouse click on the first of `selectors` that shows up within `timeout`."""
    spot = None
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            spot = page.js(f"{SPOT}({json.dumps(selectors)})")
        except RuntimeError:
            spot = None
        if spot:
            break
        time.sleep(0.5)
    if not spot:
        log(f"no {what} on the page")
        return False
    if spot["covered"]:
        log(f"{what} {spot['sel']} is covered by {spot['covered']}; clicking anyway")
    # Players such as Shaka fade their controls in on mouse movement, and a
    # press on a still-hidden control can be swallowed.
    page.call("Input.dispatchMouseEvent", type="mouseMoved", x=spot["x"], y=spot["y"])
    time.sleep(0.3)
    for kind in ("mousePressed", "mouseReleased"):
        page.call("Input.dispatchMouseEvent", type=kind, x=spot["x"], y=spot["y"],
                  button="left", clickCount=1)
    log(f"clicked the {what} ({spot['sel']})")
    return True


def play():
    page = Page()
    if page.js(f"!!{PLAYER}?.playVideo"):
        page.js(f"{PLAYER}.playVideo()")
        note = keep_original_audio(page, 3)
        if "did not stick" in note:
            log(note)
        return
    if not click_first(page, PLAY_BUTTONS, "play button", 10):
        return
    if os.environ.get("YT_FULLSCREEN", "1") != "1":
        return
    # The player builds its controls only once playback starts.
    for _ in range(3):
        if not click_first(page, FULLSCREEN_BUTTONS, "fullscreen button", 10):
            return
        if page.wait_for("!!document.fullscreenElement", 3, "fullscreen"):
            break
    else:
        log("could not switch the video to fullscreen")
    # Park the pointer in a corner so the controls fade out again.
    page.call("Input.dispatchMouseEvent", type="mouseMoved", x=0, y=0)


def main():
    if sys.argv[1:2] == ["open"] and len(sys.argv) == 3:
        open_url(sys.argv[2])
    elif sys.argv[1:] == ["play"]:
        play()
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # never block the recording on page automation
        log(f"error: {e}")
