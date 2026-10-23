#!/usr/bin/env python3
"""Drives the recorder's Chrome over the DevTools protocol.

  browse.py open URL   navigate; on YouTube also skip consent, wait out ads,
                       pick the original audio track, go fullscreen and
                       pause at 0:00 so the recording starts on frame one
  browse.py play       resume the paused YouTube video; elsewhere click the
                       page's .play-action play button, if it has one
  browse.py play-audio for audio-only recording: start the YouTube video, or
                       press Spotify's play button (the page's own on album
                       and playlist pages, else the bottom-bar toggle) unless
                       it is already playing, after moving Spotify playback
                       into this browser; never goes fullscreen

With AUDIO_ONLY=1, `open` already moves Spotify playback into this browser.

With COOKIES set to a cookies.txt or JSON export, those cookies are loaded
before the page opens, so it opens logged in.
"""
import json
import math
import os
import re
import subprocess
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
        # Done before the recording starts: the transfer takes several seconds,
        # which would otherwise open the file with silence.
        if os.environ.get("AUDIO_ONLY") == "1" and url.startswith("https://open.spotify.com/"):
            spotify_take_over(page)
            if not os.environ.get("DURATION") and SPOTIFY_LIST.match(url):
                measure_track_list(page)
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
    mouse_click(page, spot["x"], spot["y"])
    log(f"clicked the {what} ({spot['sel']})")
    return True


def mouse_click(page, x, y):
    # Players such as Shaka fade their controls in on mouse movement, and a
    # press on a still-hidden control can be swallowed.
    page.call("Input.dispatchMouseEvent", type="mouseMoved", x=x, y=y)
    time.sleep(0.3)
    for kind in ("mousePressed", "mouseReleased"):
        page.call("Input.dispatchMouseEvent", type=kind, x=x, y=y, button="left", clickCount=1)


def play_youtube(page):
    if not page.js(f"!!{PLAYER}?.playVideo"):
        return False
    page.js(f"{PLAYER}.playVideo()")
    note = keep_original_audio(page, 3)
    if "did not stick" in note:
        log(note)
    return True


def play():
    page = Page()
    if play_youtube(page):
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


SPOTIFY_TOGGLE = '[data-testid="control-button-playpause"]'
# Scoped: bare play-button testids also sit on every library and card item,
# and the first one in the DOM is the sidebar's "Liked Songs".
SPOTIFY_PAGE_PLAY = '[data-testid="action-bar-row"] [data-testid="play-button"]'
SPOTIFY_PAGE_PLAY_ALT = '[data-testid="action-bar"] [data-testid="play-button"]'
# On an album/playlist/track page the bottom-bar toggle would resume the
# account's last context instead of what the URL shows, so the page's own
# play button goes first there.
SPOTIFY_ITEM = re.compile(r"^https?://open\.spotify\.com/(intl-[a-z-]+/)?(album|playlist|track|artist|show|episode)/")
# Spotify labels its buttons with what a click would do, so "Pauza" means
# it is already playing and a click would stop it.
PLAYING_LABEL = r"^(pauza|zatrzymuje|pause|pausa|pausar|pausieren|mettre en pause|pauzeren|pozastavit)\b"

PICK_AUDIO_BUTTON = """((selectors) => {
  for (const sel of selectors) {
    const b = document.querySelector(sel);
    if (b && !b.disabled && b.getAttribute('aria-disabled') !== 'true' && b.getClientRects().length)
      return {sel, label: (b.getAttribute('aria-label') || '').trim()};
  }
  return null;
})"""

CENTER_OF = """(el => {
  if (!el) return null;
  el.scrollIntoView({block: 'center'});
  const r = el.getBoundingClientRect();
  return r.width && r.height ? {x: r.x + r.width / 2, y: r.y + r.height / 2} : null;
})"""
DEVICES_BUTTON = """[...document.querySelectorAll('[data-testid="now-playing-bar"] button')]
  .find(b => /connect to a device|połącz z urządzeniem|devices|urządzeni/i.test(b.getAttribute('aria-label') || ''))"""
# The picker lists the active device on top and the others under "Connect to
# this device"; this browser is only in that list while it isn't the one playing.
THIS_BROWSER_ROW = """[...document.querySelectorAll('[data-testid^="devices-list"] [data-testid="device-picker-row-sidepanel"]')]
  .find(r => /this web browser|ta przeglądarka/i.test(r.innerText))"""
ACTIVE_DEVICE = """document.querySelector('[data-testid="device-picker-row-sidepanel"]:not([data-testid^="devices-list"] *)')
  ?.innerText.replace(/\\s+/g, ' ').trim()"""


PICKER_OPEN = "!!document.querySelector('[data-testid=\"device-picker-row-sidepanel\"]')"


def spotify_take_over(page):
    """While the account plays on another device (a phone, the desktop app,
    another browser), this page is only a remote control and the recording
    stays silent; Spotify Connect moves the playback into this browser.
    Right after load the page's own player isn't registered yet and Spotify
    silently ignores the transfer (seen on a real account), so it is
    repeated until sound arrives."""
    if not page.wait_for(f"!!({DEVICES_BUTTON})", 20, "Spotify's device button"):
        return
    for attempt in range(1, 5):
        if not page.js(PICKER_OPEN):
            button = page.js(f"{CENTER_OF}({DEVICES_BUTTON})")
            mouse_click(page, button["x"], button["y"])
            if not page.wait_for(PICKER_OPEN, 5, "the device picker"):
                return
        row = page.js(f"{CENTER_OF}({THIS_BROWSER_ROW})")
        if not row:
            return  # this browser is already the active device
        active = page.js(ACTIVE_DEVICE)
        mouse_click(page, row["x"], row["y"])
        # Sound proves it; a paused player moves silently, so the picker
        # naming this browser as the active device counts too.
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if sound_reaches_recorder() or re.search(r"this web browser|ta przeglądarka", page.js(ACTIVE_DEVICE) or "", re.I):
                log(f'moved Spotify playback from "{active}" to this browser')
                return
            time.sleep(0.5)
        time.sleep(2)
    log(f'could not move Spotify playback from "{active}" to this browser')


def sound_reaches_recorder():
    """True once a stream plays into the recorder's speaker: the only proof
    that the page's audio is really being recorded, whatever its buttons say."""
    try:
        out = subprocess.run(["pactl", "list", "sink-inputs"], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return False
    return "Corked: no" in out


def wait_for_sound(timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if sound_reaches_recorder():
            return True
        time.sleep(0.5)
    return False


SPOTIFY_LIST = re.compile(r"^https?://open\.spotify\.com/(intl-[a-z-]+/)?(album|playlist)/")
TRACK_LIST = '[role="grid"][data-testid="track-list"], [role="grid"][data-testid="playlist-tracklist"]'
# entrypoint.sh reads it to limit the recording; its presence also tells
# play-audio to start from the first track, which the sum assumes.
AUTO_DURATION_FILE = "/tmp/auto-duration"

# Spotify renders only the rows near the viewport, so the rows' times are
# collected by row index while the list scrolls through.
# Rows of a multi-disc album's "Disc N" headings count in aria-rowcount too,
# so they are collected to be left out of the expected number of tracks.
# `pending` counts rendered tracks whose time hasn't loaded yet.
VISIBLE_TRACK_TIMES = f"""(() => {{
  const grid = document.querySelector({json.dumps(TRACK_LIST)});
  if (!grid) return null;
  const times = {{}}, other = [];
  let pending = 0;
  for (const cell of grid.querySelectorAll('[aria-rowindex]')) {{
    const index = cell.getAttribute('aria-rowindex');
    const row = cell.querySelector('[data-testid="tracklist-row"]');
    if (!row) {{ if (index !== '1') other.push(index); continue; }}
    const cells = row.querySelectorAll('[role="gridcell"]');
    const text = (cells[cells.length - 1]?.innerText || '').trim();
    if (/^\\d+(:\\d{{2}}){{1,2}}$/.test(text))
      times[index] = text.split(':').reduce((s, part) => s * 60 + Number(part), 0);
    else pending++;
  }}
  return {{rows: Number(grid.getAttribute('aria-rowcount')) - 1, times, other, pending}};
}})()"""
SCROLL_TRACK_LIST = f"""((to) => {{
  const view = document.querySelector({json.dumps(TRACK_LIST)})?.closest('[data-overlayscrollbars-viewport]');
  if (!view) return null;
  const before = view.scrollTop;
  view.scrollTop = to === 'top' ? 0 : before + view.clientHeight * 0.7;
  return view.scrollTop !== before;
}})"""
FIRST_TRACK_PLAY = f"""(() => {{
  const grid = document.querySelector({json.dumps(TRACK_LIST)});
  return grid?.querySelector('[data-testid="tracklist-row"] [aria-colindex="1"]') ?? null;
}})()"""
# The row's play button only shows on hover, in place of the track number;
# the mouse moves there before pressing, so aiming at the cell hits it.
PLAYBACK_SECONDS = """(t => t ? t.split(':').reduce((s, p) => s * 60 + Number(p), 0) : null)(
  document.querySelector('[data-testid="playback-position"]')?.innerText.trim())"""
SKIP_BACK = '[data-testid="control-button-skip-back"]'
# "24 songs, 54 min 12 sec" (Polish "54 min 12 s", "1 godz. 3 min 5 s");
# playlists only say "about 2 hr 45 min", which has no seconds and won't match.
EXACT_TOTAL = r"""(() => {
  const m = (document.querySelector('main')?.innerText || '')
    .match(/(?:(\d+)\s*(?:hr|h|godz\.?)\s*)?(\d+)\s*min\.?\s*(\d+)\s*(?:sec|s)\b/i);
  return m ? (Number(m[1] || 0) * 60 + Number(m[2])) * 60 + Number(m[3]) : null;
})()"""
REPEAT_BUTTON = '[data-testid="control-button-repeat"]'
# The shuffle button has no testid or aria-checked; its label says what a
# click does, "Enable Shuffle for <album>" while it is off.
SHUFFLE_BUTTON = """[...document.querySelectorAll('[data-testid="now-playing-bar"] button')]
  .find(b => /shuffle|losow/i.test(b.getAttribute('aria-label') || ''))"""
SHUFFLE_OFF_LABEL = re.compile(r"^(enable shuffle|włącz (odtwarzanie )?losow)", re.I)


def pause_spotify(page):
    toggle = page.js(f"{PICK_AUDIO_BUTTON}({json.dumps([SPOTIFY_TOGGLE])})")
    if toggle and re.match(PLAYING_LABEL, toggle["label"], re.I):
        click_first(page, [SPOTIFY_TOGGLE], "play/pause toggle (pausing until the recording starts)", 3)


def play_in_order(page):
    """Shuffle reorders and smart shuffle adds tracks, repeat loops them; the
    summed length only holds for the list played once, top to bottom. This
    changes the account's setting, as the same click in the app would."""
    # Both cycle through modes (shuffle, smart shuffle; repeat all, repeat
    # one), so it may take a few clicks to get back to off.
    for _ in range(3):
        if page.js(f"document.querySelector({json.dumps(REPEAT_BUTTON)})?.getAttribute('aria-checked')") != "true":
            break
        click_first(page, [REPEAT_BUTTON], "repeat button (turning repeat off)", 3)
        time.sleep(0.5)
    else:
        log("could not turn repeat off; the recording may not follow the track list")
    for _ in range(3):
        label = page.js(f"({SHUFFLE_BUTTON})?.getAttribute('aria-label')")
        if label is None or SHUFFLE_OFF_LABEL.match(label):
            break
        button = page.js(f"{CENTER_OF}({SHUFFLE_BUTTON})")
        mouse_click(page, button["x"], button["y"])
        log(f'clicked the shuffle button (was "{label}")')
        time.sleep(0.5)
    else:
        log("could not turn shuffle off; the recording may not follow the track list")


def read_track_times(page):
    """{rowindex: seconds} for every track, or None if not all could be read.
    Rows load their times in chunks after they render, so the list only
    scrolls on once the rendered ones have them, or after a few seconds."""
    if not page.wait_for(f"!!({VISIBLE_TRACK_TIMES})?.rows", 20, "the track list"):
        return None
    page.js(f"{SCROLL_TRACK_LIST}('top')")
    time.sleep(0.5)
    times, other = {}, set()
    rows = 0
    deadline = time.monotonic() + 90
    idle_since = time.monotonic()
    while time.monotonic() < deadline:
        try:
            found = page.js(VISIBLE_TRACK_TIMES)
        except RuntimeError:
            found = None  # the list re-rendered mid-read
        if found:
            rows = found["rows"]
            before = len(times)
            times.update(found["times"])
            other.update(found["other"])
            if len(times) > before:
                idle_since = time.monotonic()
            if rows and len(times) >= rows - len(other):
                break
            waiting = found["pending"] and time.monotonic() - idle_since < 3
            if not waiting and not page.js(f"{SCROLL_TRACK_LIST}('down')") \
                    and time.monotonic() - idle_since > 3:
                break  # at the bottom and nothing new for a while
        time.sleep(0.5)
    page.js(f"{SCROLL_TRACK_LIST}('top')")
    expected = rows - len(other)
    if len(times) != expected:
        log(f"read {len(times)} of {expected} track times")
        return None
    return times


def measure_track_list(page):
    """Sets the recording length to the album's or playlist's total plus a
    margin, and keeps Spotify paused until the recording starts."""
    pause_spotify(page)
    try:
        times = read_track_times(page)
    except RuntimeError as e:
        log(f"reading the track list failed: {e}")
        times = None
    if not times:
        log("no complete track list; recording until stopped")
        return
    play_in_order(page)
    # A transfer to this browser can resume playback a moment after the
    # first pause.
    pause_spotify(page)
    count = len(times)
    rows_total = sum(times.values())
    # Rows show times rounded down to the second (an album of 24 tracks summed
    # to 54:00 against its real 54:12). An album's header has the exact total;
    # it is trusted only within what the rounding allows, else each track
    # counts its worst case of a second more.
    header = page.js(EXACT_TOTAL)
    exact = header is not None and rows_total <= header <= rows_total + count
    total = header if exact else rows_total + count
    # Spotify plays a list almost gaplessly; the margin covers the start-up
    # and small buffering pauses without much of what autoplay adds after.
    seconds = math.ceil(total + 5 + 0.25 * count)
    with open(AUTO_DURATION_FILE, "w") as f:
        f.write(str(seconds))
    source = "the album's total" if exact else f"track times {rows_total // 60}:{rows_total % 60:02d} + 1 s each"
    log(f"track list: {count} tracks, {total // 60}:{total % 60:02d} ({source}); "
        f"recording {seconds // 60}:{seconds % 60:02d} from the first track")


def play_audio():
    page = Page()
    if play_youtube(page):
        return
    url = page.js("location.href") or ""
    if os.path.exists(AUTO_DURATION_FILE):
        first = page.js(f"{CENTER_OF}({FIRST_TRACK_PLAY})")
        if first:
            mouse_click(page, first["x"], first["y"])
            log("started the first track")
            if not wait_for_sound(5):
                # The row's button pauses a first track that was still playing.
                click_first(page, [SPOTIFY_TOGGLE], "play/pause toggle", 3)
            if wait_for_sound(8):
                log("sound is reaching the recorder")
                # A first track that was paused mid-way resumes there; "previous"
                # past the first seconds restarts it.
                position = page.js(PLAYBACK_SECONDS)
                if position and position > 3:
                    click_first(page, [SKIP_BACK], "previous button (back to 0:00)", 3)
            else:
                log("no sound is reaching the recorder; the recording will be silent")
            return
        log("first track's play button not found; the recording may not match the track list")
    if url.startswith("https://open.spotify.com/"):
        spotify_take_over(page)
    spotify = ([SPOTIFY_PAGE_PLAY, SPOTIFY_PAGE_PLAY_ALT, SPOTIFY_TOGGLE] if SPOTIFY_ITEM.match(url)
               else [SPOTIFY_TOGGLE, SPOTIFY_PAGE_PLAY, SPOTIFY_PAGE_PLAY_ALT])
    candidates = spotify + PLAY_BUTTONS
    button = None
    deadline = time.monotonic() + 20
    while not button and time.monotonic() < deadline:
        try:
            button = page.js(f"{PICK_AUDIO_BUTTON}({json.dumps(candidates)})")
        except RuntimeError:
            pass
        if not button:
            time.sleep(0.5)
    if not button:
        log("no play button on the page; recording whatever plays")
    elif re.match(PLAYING_LABEL, button["label"], re.I):
        log(f'already playing (button reads "{button["label"]}"); not clicking')
    else:
        click_first(page, [button["sel"]], "play button", 5)
    if wait_for_sound(10):
        log("sound is reaching the recorder")
    elif page.js("/chronionej|protected content/i.test(document.body.innerText)"):
        log("the page says playback of protected content is disabled (DRM); the recording will be silent")
    else:
        log("no sound is reaching the recorder; the recording will be silent "
            "(playing on another device, paused, or blocked)")


def main():
    if sys.argv[1:2] == ["open"] and len(sys.argv) == 3:
        open_url(sys.argv[2])
    elif sys.argv[1:] == ["play"]:
        play()
    elif sys.argv[1:] == ["play-audio"]:
        play_audio()
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # never block the recording on page automation
        log(f"error: {e}")
