#!/usr/bin/env python3
"""
WalkingPad Control — local app for the Xiaomi/KingSmith WalkingPad A1 / A1 Pro.

Talks to the pad over Bluetooth LE (legacy "WiLink" protocol) and serves a control
panel at http://localhost:8765

Game mode (Windows): the belt follows your in-game movement.
  Keyboard: hold W = walk, W + Shift = sprint, release = slow down / stop
  Gamepad (Xbox / XInput): left stick forward = proportional speed, stick click = sprint
  F8 toggles game mode from inside the game (turning it off stops the belt).

Requirements:  pip install bleak aiohttp
Close the KS Fit / Mi Home app first: the pad only accepts one Bluetooth client.
"""

import asyncio
import ctypes
import json
from ctypes import wintypes
import sys
import time
import webbrowser
from pathlib import Path

from aiohttp import web, WSMsgType
from bleak import BleakClient, BleakScanner

PORT = 8765
BUILD = "dev"   # replaced by the build script
SETTINGS_FILE = Path.home() / ".walkingpad_settings.json"
LOG_FILE = Path.home() / "walkingpad_log.txt"

# ---- WiLink protocol ------------------------------------------------------------
CHAR_NOTIFY = "0000fe01-0000-1000-8000-00805f9b34fb"   # pad -> us
CHAR_WRITE = "0000fe02-0000-1000-8000-00805f9b34fb"    # us -> pad
CHAR_SUPPLEMENT = "24e2521c-f63b-48ed-85be-c5330d00fdf7"  # buzzer on SOME models

MODE_AUTO, MODE_MANUAL, MODE_STANDBY = 0, 1, 2
MIN_CMD_GAP = 0.7          # the pad drops commands sent faster than this
MIN_SPEED, MAX_SPEED = 0.5, 6.0
START_COUNTDOWN = 4.5      # firmware 3-2-1 countdown before it accepts a speed


def with_crc(cmd):
    """Frames are F7 ... CRC FD, CRC = sum(bytes[1:-2]) % 256."""
    cmd = bytearray(cmd)
    cmd[-2] = sum(cmd[1:-2]) % 256
    return cmd


def b2i(b):
    return (b[0] << 16) | (b[1] << 8) | b[2]


def clamp_speed(s):
    return round(max(MIN_SPEED, min(MAX_SPEED, s)), 1)


CMD_ASK_STATS = [0xF7, 0xA2, 0, 0, 0, 0xFD]
def cmd_mode(m):   return [0xF7, 0xA2, 2, m, 0, 0xFD]
def cmd_speed(s):  return [0xF7, 0xA2, 1, s, 0, 0xFD]       # s = km/h * 10
def cmd_start():   return [0xF7, 0xA2, 4, 1, 0, 0xFD]

SOUND_ON = bytes.fromhex("72010308030081")
SOUND_OFF = bytes.fromhex("7201030801007f")


# ---- Windows input (no extra dependencies) ----------------------------------------
IS_WINDOWS = sys.platform == "win32"
VK = {"shift": 0x10, "ctrl": 0x11, "alt": 0x12, "up": 0x26, "space": 0x20, "f8": 0x77, "f9": 0x78, "f11": 0x7A, "f12": 0x7B, "numpad/": 0x6F}


def vk_for(key: str):
    key = key.strip().lower()
    if key in ("", "none"):
        return None
    if key in VK:
        return VK[key]
    if len(key) == 1 and key.isalnum():
        return ord(key.upper())
    return None


def foreground_title() -> str:
    if not IS_WINDOWS:
        return ""
    u = ctypes.windll.user32
    h = u.GetForegroundWindow()
    buf = ctypes.create_unicode_buffer(512)
    u.GetWindowTextW(h, buf, 512)
    return buf.value


def foreground_exe() -> str:
    """File name of the program owning the window in front, e.g. 'wow.exe'."""
    if not IS_WINDOWS:
        return ""
    try:
        u, k = ctypes.windll.user32, ctypes.windll.kernel32
        pid = wintypes.DWORD()
        u.GetWindowThreadProcessId(u.GetForegroundWindow(), ctypes.byref(pid))
        k.OpenProcess.restype = wintypes.HANDLE
        h = k.OpenProcess(0x1000, False, pid.value)          # PROCESS_QUERY_LIMITED_INFORMATION
        if not h:
            return ""
        try:
            buf = ctypes.create_unicode_buffer(520)
            size = wintypes.DWORD(520)
            if k.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(size)):
                return buf.value.replace("/", "\\").split("\\")[-1].lower()
        finally:
            k.CloseHandle(h)
    except Exception:
        pass
    return ""


def wow_in_front() -> bool:
    if "world of warcraft" in foreground_title().lower():
        return True
    exe = foreground_exe()
    return exe.startswith("wow") and exe.endswith(".exe")


def key_down(vk) -> bool:
    if not IS_WINDOWS or vk is None:
        return False
    return bool(ctypes.windll.user32.GetAsyncKeyState(vk) & 0x8000)


class _XGamepad(ctypes.Structure):
    _fields_ = [("wButtons", ctypes.c_ushort), ("bLeftTrigger", ctypes.c_ubyte),
                ("bRightTrigger", ctypes.c_ubyte), ("sThumbLX", ctypes.c_short),
                ("sThumbLY", ctypes.c_short), ("sThumbRX", ctypes.c_short),
                ("sThumbRY", ctypes.c_short)]


class _XState(ctypes.Structure):
    _fields_ = [("dwPacketNumber", ctypes.c_ulong), ("Gamepad", _XGamepad)]


class Gamepad:
    LEFT_THUMB = 0x0040

    def __init__(self):
        self.dll = None
        if IS_WINDOWS:
            for name in ("xinput1_4", "xinput1_3", "xinput9_1_0"):
                try:
                    self.dll = getattr(ctypes.windll, name)
                    break
                except OSError:
                    pass

    def read(self):
        """Returns (forward 0..1, stick_click) for the first connected pad, or None."""
        if not self.dll:
            return None
        st = _XState()
        for i in range(4):
            if self.dll.XInputGetState(i, ctypes.byref(st)) == 0:
                y = max(0, st.Gamepad.sThumbLY) / 32767
                return y, bool(st.Gamepad.wButtons & self.LEFT_THUMB)
        return None


# ---- Screen pixels (WoW bridge) -----------------------------------------------------
from ctypes import wintypes

if IS_WINDOWS:
    try:   # read real pixels on scaled (125%/150%) displays
        ctypes.windll.shcore.SetProcessDpiAwareness(2)
    except Exception:
        try:
            ctypes.windll.user32.SetProcessDPIAware()
        except Exception:
            pass
    _u32, _gdi = ctypes.windll.user32, ctypes.windll.gdi32
    _u32.GetDC.restype = wintypes.HDC
    _u32.GetDC.argtypes = [wintypes.HWND]
    _u32.ReleaseDC.argtypes = [wintypes.HWND, wintypes.HDC]
    _gdi.CreateCompatibleDC.restype = wintypes.HDC
    _gdi.CreateCompatibleDC.argtypes = [wintypes.HDC]
    _gdi.CreateCompatibleBitmap.restype = wintypes.HBITMAP
    _gdi.CreateCompatibleBitmap.argtypes = [wintypes.HDC, ctypes.c_int, ctypes.c_int]
    _gdi.SelectObject.restype = wintypes.HGDIOBJ
    _gdi.SelectObject.argtypes = [wintypes.HDC, wintypes.HGDIOBJ]
    _gdi.BitBlt.argtypes = [wintypes.HDC, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                            wintypes.HDC, ctypes.c_int, ctypes.c_int, wintypes.DWORD]
    _gdi.GetDIBits.argtypes = [wintypes.HDC, wintypes.HBITMAP, wintypes.UINT, wintypes.UINT,
                               ctypes.c_void_p, ctypes.c_void_p, wintypes.UINT]
    _gdi.DeleteObject.argtypes = [wintypes.HGDIOBJ]
    _gdi.DeleteDC.argtypes = [wintypes.HDC]
    _gdi.GetPixel.restype = wintypes.DWORD
    _gdi.GetPixel.argtypes = [wintypes.HDC, ctypes.c_int, ctypes.c_int]


class _BMIH(ctypes.Structure):
    _fields_ = [("biSize", wintypes.DWORD), ("biWidth", ctypes.c_long), ("biHeight", ctypes.c_long),
                ("biPlanes", wintypes.WORD), ("biBitCount", wintypes.WORD), ("biCompression", wintypes.DWORD),
                ("biSizeImage", wintypes.DWORD), ("biXPelsPerMeter", ctypes.c_long),
                ("biYPelsPerMeter", ctypes.c_long), ("biClrUsed", wintypes.DWORD), ("biClrImportant", wintypes.DWORD)]


MARK_BGR = bytes([0x56, 0x34, 0x12])   # addon marker colour #123456, as stored in BGRA screenshots
DATA_CHECK = 0xA5
REQ_CHECK = 0x5A


def find_marker(buf: bytes, w: int, h: int):
    """Find Windrunner's squares in a BGRA screenshot.
    Returns (marker_xy, data_xy, request_xy or None) or None."""
    def px(x, y):
        j = (y * w + x) * 4
        return buf[j + 2], buf[j + 1], buf[j]          # r, g, b
    i = buf.find(MARK_BGR)
    while i != -1:
        if i % 4 == 0:
            p = i // 4
            mx, my = p % w, p // w
            cy = my + 1 if my + 1 < h else my             # sample a row inside the squares
            for dx in (3, 2, 4, 1, 5, 6):                 # data square sits right of the marker
                if mx + dx < w:
                    r, g, b = px(mx + dx, cy)
                    if r == DATA_CHECK and b & 0x80:
                        req = None
                        for rx in (2 * dx, 2 * dx - 1, 2 * dx + 1):
                            if mx + rx < w:
                                r2, g2, b2 = px(mx + rx, cy)
                                if r2 == REQ_CHECK and b2 & 0x80:
                                    req = (mx + rx, cy)
                                    break
                        return (mx, cy), (mx + dx, cy), req
        i = buf.find(MARK_BGR, i + 1)
    return None


def decode_data(r, g, b):
    if r != DATA_CHECK or not b & 0x80:
        return None
    return {"speed": g / 10, "moving": bool(b & 1), "mounted": bool(b & 2), "known": bool(b & 4),
            "swimming": bool(b & 8), "taxi": bool(b & 16), "vehicle": bool(b & 32), "walking": bool(b & 64)}


def decode_request(r, g, b):
    """Windrunner's 3rd square: B bit0 = App mode, bit1 = belt should run; G = wanted km/h x10."""
    if r != REQ_CHECK or not b & 0x80:
        return {"app_mode": False, "target": 0.0, "run": False}
    return {"app_mode": bool(b & 1), "target": g / 10, "run": bool(b & 2)}


def monitor_rects():
    """[(left, top, right, bottom)] for every monitor, in virtual-screen pixels."""
    rects = []
    if not IS_WINDOWS:
        return rects
    proc_t = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HMONITOR, wintypes.HDC,
                                ctypes.POINTER(wintypes.RECT), wintypes.LPARAM)

    def cb(_h, _dc, r, _lp):
        rc = r.contents
        rects.append((rc.left, rc.top, rc.right, rc.bottom))
        return True

    _u32.EnumDisplayMonitors(None, None, proc_t(cb), 0)
    return rects


class WowBridge:
    """Reads the Windrunner addon's colour code from the screen."""

    def __init__(self):
        self.log = print
        self.last_diag = 0.0
        self.pos = None
        self.last_search = 0.0
        self.misses = 0
        self.last = None
        self.status = "looking for the WoW addon…"

    def _capture(self):
        x, y = _u32.GetSystemMetrics(76), _u32.GetSystemMetrics(77)
        w, h = _u32.GetSystemMetrics(78), _u32.GetSystemMetrics(79)
        hdc = _u32.GetDC(None)
        mdc = _gdi.CreateCompatibleDC(hdc)
        bmp = _gdi.CreateCompatibleBitmap(hdc, w, h)
        old = _gdi.SelectObject(mdc, bmp)
        try:
            _gdi.BitBlt(mdc, 0, 0, w, h, hdc, x, y, 0x00CC0020)
            bmi = _BMIH(ctypes.sizeof(_BMIH), w, -h, 1, 32, 0, 0, 0, 0, 0, 0)
            buf = ctypes.create_string_buffer(w * h * 4)
            _gdi.GetDIBits(mdc, bmp, 0, h, buf, ctypes.byref(bmi), 0)
            return x, y, w, h, buf.raw
        finally:
            _gdi.SelectObject(mdc, old)
            _gdi.DeleteObject(bmp)
            _gdi.DeleteDC(mdc)
            _u32.ReleaseDC(None, hdc)

    def diagnose(self, x=None, y=None, w=None, h=None, buf=None):
        """Log what the app sees at each monitor's top-left corner (colour values only)."""
        self.last_diag = time.time()
        try:
            if buf is None:
                x, y, w, h, buf = self._capture()
            found = find_marker(buf, w, h)
            mons = monitor_rects()
            self.log(f"Link check: {len(mons)} monitor(s), desktop {w}x{h} at ({x},{y}); "
                     f"window in front: '{foreground_title()[:50]}' ({foreground_exe() or '?'}); Windrunner squares "
                     + (f"FOUND at {found[0][0] + x},{found[0][1] + y}" if found else "NOT found"))
            for i, (l, t, r, b) in enumerate(mons, 1):
                cols = []
                for dx in range(0, 12, 1):
                    px, py = l + dx - x, t + 1 - y
                    if 0 <= px < w and 0 <= py < h:
                        j = (py * w + px) * 4
                        cols.append(f"{buf[j + 2]:02x}{buf[j + 1]:02x}{buf[j]:02x}")
                self.log(f"  monitor {i} {r - l}x{b - t} at ({l},{t}) top-left pixels: {' '.join(cols)}")
            if not found:
                self.log("  Expected to start with 123456 123456 123456 a5…… — if the colours are close but not "
                         "exact, turn off HDR / reset WoW gamma; if they're your desktop, WoW isn't fullscreen on that monitor.")
        except Exception as e:
            self.log(f"Link check failed: {e}")

    def _pixel(self, hdc, x, y):
        c = _gdi.GetPixel(hdc, x, y)
        return c & 0xFF, (c >> 8) & 0xFF, (c >> 16) & 0xFF      # r, g, b

    def read(self):
        if not IS_WINDOWS:
            self.status = "needs Windows"
            return None
        now = time.time()
        if self.pos is None:
            if now - self.last_search < 3:
                return None
            self.last_search = now
            x, y, w, h, buf = self._capture()
            found = find_marker(buf, w, h)
            if not found:
                self.status = "Windrunner not found on screen — is WoW open with the addon on?"
                if wow_in_front() and now - self.last_diag > 120:
                    self.diagnose(x, y, w, h, buf)      # WoW is in front but no squares: explain why
                return None
            (mx, my), (dx, dy), req = found
            self.pos = ((x + mx, y + my), (x + dx, y + dy),
                        (x + req[0], y + req[1]) if req else None)
            self.misses = 0
        (mx, my), (dx, dy), rq = self.pos
        hdc = _u32.GetDC(None)
        try:
            m = self._pixel(hdc, mx, my)
            d = decode_data(*self._pixel(hdc, dx, dy))
            if d is not None:
                d.update(decode_request(*self._pixel(hdc, *rq)) if rq else decode_request(0, 0, 0))
        finally:
            _u32.ReleaseDC(None, hdc)
        if m != (0x12, 0x34, 0x56) or d is None:
            self.misses += 1
            if self.misses >= 4:          # ~0.2 s of misses: WoW minimised / covered / closed
                self.pos, self.last = None, None
                self.status = "lost the addon (WoW minimised or covered?)"
            return self.last
        self.misses = 0
        self.last = d
        self.status = "ok"
        return d


# ---- Key sender (reverse mode) ------------------------------------------------------
class _KEYBDINPUT(ctypes.Structure):
    _fields_ = [("wVk", wintypes.WORD), ("wScan", wintypes.WORD), ("dwFlags", wintypes.DWORD),
                ("time", wintypes.DWORD), ("dwExtraInfo", ctypes.c_size_t)]


class _MOUSEINPUT(ctypes.Structure):
    _fields_ = [("dx", ctypes.c_long), ("dy", ctypes.c_long), ("mouseData", wintypes.DWORD),
                ("dwFlags", wintypes.DWORD), ("time", wintypes.DWORD), ("dwExtraInfo", ctypes.c_size_t)]


class _INPUTUNION(ctypes.Union):
    _fields_ = [("ki", _KEYBDINPUT), ("mi", _MOUSEINPUT)]


class _INPUT(ctypes.Structure):
    _fields_ = [("type", wintypes.DWORD), ("u", _INPUTUNION)]


class KeySender:
    """Holds keys down in the game like a real keyboard."""
    EXTENDED = {0x26, 0x28, 0x25, 0x27, 0x6F}

    def __init__(self):
        self.held = set()

    def _send(self, vk, up):
        if not IS_WINDOWS:
            return
        scan = ctypes.windll.user32.MapVirtualKeyW(vk, 0)
        # key code + hardware scan code together (like AutoHotkey): works for normal and raw-input games
        flags = 0x0002 if up else 0                            # KEYUP
        if vk in self.EXTENDED:
            flags |= 0x0001
        inp = _INPUT(type=1, u=_INPUTUNION(ki=_KEYBDINPUT(vk, scan, flags, 0, 0)))
        ctypes.windll.user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(_INPUT))

    def set(self, vk, down):
        if vk is None:
            return
        if down and vk not in self.held:
            self._send(vk, False)
            self.held.add(vk)
        elif not down and vk in self.held:
            self._send(vk, True)
            self.held.discard(vk)

    def tap(self, vk):
        """Quick press + release by virtual-key code (used for the F13/F14 link signal)."""
        if not IS_WINDOWS:
            return
        scan = ctypes.windll.user32.MapVirtualKeyW(vk, 0)
        for flags in (0, 0x0002):
            inp = _INPUT(type=1, u=_INPUTUNION(ki=_KEYBDINPUT(vk, scan, flags, 0, 0)))
            ctypes.windll.user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(_INPUT))

    def release_all(self):
        for vk in list(self.held):
            self.set(vk, False)


# ---- Simulated pad (--simulate) -----------------------------------------------------
SIM_COUNTDOWN = 3.0


class SimClient:
    """Behaves like the WalkingPad over Bluetooth: start countdown, manual speed, auto profile."""
    is_connected = True

    def __init__(self, pad):
        self.pad = pad
        self.mode = MODE_STANDBY
        self.belt = 0                  # 0 stopped, 9 starting, 1 running
        self.speed = 0.0
        self.manual_speed = 2.0
        self.started = 0.0
        self.running_since = 0.0
        self.dist = 0.0
        self.last = time.time()
        import os
        prof = os.environ.get("WALKINGPAD_SIM_AUTO", "0:1.0,6:2.5,12:4.6,18:1.0,24:0")
        self.profile = [(float(t), float(v)) for t, v in (p.split(":") for p in prof.split(","))]

    def _tick(self):
        now = time.time()
        if self.belt == 9 and now - self.started >= SIM_COUNTDOWN:
            self.belt, self.running_since = 1, now
        if self.belt == 1:
            if self.mode == MODE_AUTO:
                t = now - self.running_since
                sp = 0.0
                for at, v in self.profile:
                    if t >= at:
                        sp = v
                self.speed = sp
                if sp == 0 and t > 1:
                    self.belt = 0
            else:
                self.speed = self.manual_speed
        else:
            self.speed = 0.0
        self.dist += self.speed * (now - self.last) / 3.6 / 10      # in 10 m units
        self.last = now

    async def write_gatt_char(self, _char, data, response=False):
        d = bytes(data)
        self._tick()
        if d[:2] == b"\xf7\xa2":
            op, val = d[2], d[3]
            if op == 2:
                self.mode = val
                if val == MODE_STANDBY:
                    self.belt, self.speed = 0, 0.0
            elif op == 4:
                if self.belt == 0:
                    self.belt, self.started = 9, time.time()
            elif op == 1:
                if val == 0:
                    self.belt, self.speed = 0, 0.0
                else:
                    self.manual_speed = val / 10
            self._tick()
            t = int(time.time() - self.running_since) if self.belt == 1 else 0
            dist = int(self.dist)
            frame = [0xF8, 0xA2, self.belt, int(round(self.speed * 10)), self.mode,
                     *WalkingPad_int3(t), *WalkingPad_int3(dist), 0, 0, 0, 0, 0, 0, 0, 0xFD]
            self.pad.on_notify(None, bytearray(frame))
        elif d[:2] == b"\xf7\xa6":
            self.pad.on_notify(None, bytearray.fromhex("f8 a6 00 00 00 00 00 3c 14 00 03 17 00 00 00 00 00 00 10 fd"))

    def stop_from_remote(self):
        self.belt, self.speed = 0, 0.0

    async def disconnect(self):
        self.is_connected = False


def WalkingPad_int3(v):
    return [(v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF]


# ---- Pad ------------------------------------------------------------------------
class Pad:
    def __init__(self, address=None):
        self.address = address
        self.client = None
        self.queue = asyncio.Queue()
        self.listeners = set()
        self.has_supplement = False
        self.pending_speed = None   # latest speed wish; older wishes are dropped
        self.hold_until = 0.0       # don't send speed until countdown is over
        self.belt_on = False        # our belief of whether the belt is running
        self.target_speed = 0.0
        self.raw_log = False
        self.on_connected = None
        self.on_external_stop = None
        self.simulate = "--simulate" in sys.argv
        self.last_status_time = 0.0
        self.state = {
            "connection": "disconnected", "name": None, "belt": "unknown", "mode": None,
            "speed": 0.0, "time": 0, "distance": 0.0, "steps": 0,
            "build": BUILD, "prefs": None, "sound_control": False, "log": [], "game": {}, "gatt": [], "raw_log": False,
        }

    def log(self, msg):
        line = time.strftime("%H:%M:%S ") + msg
        print(line)
        if getattr(sys.stdout, "name", "") == str(LOG_FILE):
            return
        try:
            with open(LOG_FILE, "a", encoding="utf-8") as f:
                f.write(time.strftime("%Y-%m-%d ") + line + "\n")
        except Exception:
            pass
        self.state["log"] = (self.state["log"] + [line])[-40:]
        self.push()

    def push(self):
        data = json.dumps(self.state)
        for ws in list(self.listeners):
            asyncio.create_task(self._send(ws, data))

    async def _send(self, ws, data):
        try:
            await ws.send_str(data)
        except Exception:
            self.listeners.discard(ws)

    @property
    def connected(self):
        return self.state["connection"] == "connected"

    # -- bluetooth --
    async def find(self):
        self.state["connection"] = "scanning"
        self.log("Scanning for a WalkingPad…")
        for d in await BleakScanner.discover(timeout=8.0):
            name = (d.name or "").lower()
            if "walkingpad" in name or name.startswith("ks-"):
                self.log(f"Found {d.name} ({d.address})")
                self.state["name"] = d.name
                return d.address
        return None

    def on_raw(self, char_uuid):
        def h(_s, data):
            if self.raw_log:
                self.log(f"RX {char_uuid[4:8]}: {bytes(data).hex(' ')}")
        return h

    def on_notify(self, _sender, data):
        if len(data) >= 14 and data[0] == 0xF8 and data[1] == 0xA6:
            # settings reply: the pad reports all its settings after any settings change
            prefs = {"max_speed": data[7] / 10, "start_speed": data[8] / 10, "smart_start": bool(data[9]),
                     "sensitivity": data[10], "units_miles": bool(data[12]), "child_lock": bool(data[13])}
            if prefs != self.state.get("prefs"):
                names = {1: "high", 2: "medium", 3: "low"}
                self.log(f"Pad settings: auto-mode sensitivity {names.get(prefs['sensitivity'], prefs['sensitivity'])}, "
                         f"max {prefs['max_speed']:.1f} km/h, start {prefs['start_speed']:.1f} km/h, "
                         f"smart start {'on' if prefs['smart_start'] else 'off'}")
            self.state["prefs"] = prefs
            self.push()
        if self.raw_log and not (len(data) >= 2 and data[1] == 0xA2 and not self.state.get("raw_stats")):
            self.log(f"RX fe01: {bytes(data).hex(' ')}")
        if len(data) >= 17 and data[0] == 0xF8 and data[1] == 0xA2:
            speed = data[3] / 10
            self.last_status_time = time.time()
            self.state.update(
                belt={0: "stopped", 1: "running", 5: "standby", 9: "starting"}.get(data[2], f"state {data[2]}"),
                speed=speed,
                mode={0: "auto", 1: "manual", 2: "standby"}.get(data[4], str(data[4])),
                time=b2i(data[5:8]), distance=b2i(data[8:11]) / 100, steps=b2i(data[11:14]),
            )
            # Belt stopped from the remote / pad itself?
            if self.belt_on and speed == 0 and data[2] != 9 and time.time() > self.hold_until + 3:
                self.belt_on = False
                self.pending_speed = None
                if self.on_external_stop:
                    self.on_external_stop()
            self.push()

    async def connect_loop(self):
        if self.simulate:                       # --simulate: a pretend treadmill, for testing
            self.client = SimClient(self)
            self.state["connection"] = "connected"
            self.state["name"] = "Simulated pad"
            self.log("Connected to a SIMULATED pad (--simulate)")
            if self.on_connected:
                self.on_connected()
            await self.worker()
            return
        while True:
            try:
                addr = self.address or await self.find()
                if not addr:
                    self.log("No pad found. Is it on, and the phone app closed? Retrying…")
                    self.state["connection"] = "disconnected"
                    await asyncio.sleep(5)
                    continue
                self.state["connection"] = "connecting"
                self.push()
                async with BleakClient(addr, timeout=15.0) as client:
                    self.client = client
                    await client.start_notify(CHAR_NOTIFY, self.on_notify)
                    await self.dump_gatt(client)
                    chars = {c.uuid.lower() for s in client.services for c in s.characteristics}
                    self.has_supplement = CHAR_SUPPLEMENT in chars
                    self.state["sound_control"] = self.has_supplement
                    self.state["connection"] = "connected"
                    if self.on_connected:
                        self.on_connected()
                    self.log("Connected." + ("" if self.has_supplement else
                             " This pad doesn't expose the buzzer channel, so mute is unavailable."))
                    await self.worker()
            except Exception as e:
                self.log(f"Connection lost: {e}")
            self.client = None
            self.belt_on = False
            self.state["connection"] = "disconnected"
            self.push()
            await asyncio.sleep(3)

    async def dump_gatt(self, client):
        """Map every service/characteristic and listen on all notify channels (Lab)."""
        gatt = []
        for svc in client.services:
            for c in svc.characteristics:
                entry = {"service": svc.uuid, "uuid": c.uuid, "props": list(c.properties), "value": None}
                if "read" in c.properties:
                    try:
                        entry["value"] = bytes(await client.read_gatt_char(c)).hex(" ")
                    except Exception as e:
                        entry["value"] = f"read failed: {e}"
                if c.uuid.lower() != CHAR_NOTIFY and ("notify" in c.properties or "indicate" in c.properties):
                    try:
                        await client.start_notify(c, self.on_raw(c.uuid.lower()))
                    except Exception:
                        pass
                gatt.append(entry)
        self.state["gatt"] = gatt
        info = {}
        for e in gatt:
            key = {"00002a24": "model", "00002a26": "firmware"}.get(e["uuid"][:8])
            if key and e["value"] and "failed" not in e["value"]:
                info[key] = bytes.fromhex(e["value"]).rstrip(b"\0").decode(errors="replace")
        if info:
            self.log("Pad info: " + ", ".join(f"{k} {v}" for k, v in info.items()))
        print(json.dumps(gatt, indent=1))

    def send_raw(self, hex_str, char="fe02", fix_crc=True):
        char = (char or "fe02").strip().lower()
        if "2b12" in char or "1912" in char:
            self.log("Blocked: that's the firmware-update (OTA) channel — writing to it can brick the pad.")
            return
        try:
            data = bytearray.fromhex(hex_str.replace(",", " ").replace("0x", " ").strip())
        except ValueError:
            self.log("Not valid hex. Example: f7 a2 00 00 00 fd")
            return
        if not data:
            self.log("Type some hex bytes first.")
            return
        if char in ("fe02", CHAR_WRITE):
            if fix_crc and len(data) >= 4:
                data = with_crc(data)
            self.log(f"TX fe02: {data.hex(' ')}")
            self._enqueue(("raw", CHAR_WRITE), bytes(data))   # sent exactly as shown
        else:
            self.log(f"TX {char[4:8]}: {data.hex(' ')}")
            self._enqueue(("raw", char), bytes(data))

    async def worker(self):
        """One command at a time, ≥0.7 s apart. Queued commands (start/stop/mode) go
        first; then the latest speed wish; otherwise poll stats once a second."""
        last = 0.0
        while self.client and self.client.is_connected:
            now = time.time()
            item = None
            if not self.queue.empty():
                item = self.queue.get_nowait()
            elif self.pending_speed is not None and now >= self.hold_until:
                item = ("wilink", cmd_speed(round(self.pending_speed * 10)))
                self.pending_speed = None
            elif now - last > 1.0:
                item = ("wilink", CMD_ASK_STATS)
            if item is None:
                await asyncio.sleep(0.05)
                continue
            gap = MIN_CMD_GAP - (time.time() - last)
            if gap > 0:
                await asyncio.sleep(gap)
            kind, payload = item
            try:
                await self._write(kind, payload)
            except Exception as e:
                if not self.client.is_connected:
                    raise
                self.log(f"Command failed: {e}")
            last = time.time()

    async def _write(self, kind, payload):
            if kind == "wilink":
                await self.client.write_gatt_char(CHAR_WRITE, with_crc(payload), response=False)
            elif kind == "supplement":
                await self.client.write_gatt_char(CHAR_SUPPLEMENT, payload, response=True)
            elif isinstance(kind, tuple) and kind[0] == "raw":
                try:
                    await self.client.write_gatt_char(kind[1], payload, response=kind[1] != CHAR_WRITE)
                except Exception as e:
                    self.log(f"Write to {kind[1][4:8]} failed: {e}")

    # -- actions --
    def _enqueue(self, kind, payload):
        self.queue.put_nowait((kind, payload))

    def start(self, speed, quiet=False):
        if not self.connected:
            if not quiet:
                self.log("Not connected yet.")
            return
        speed = clamp_speed(speed)
        if self.belt_on:
            return self.set_speed(speed, quiet)
        self.log(f"Starting belt (countdown), then {speed:.1f} km/h")
        self._enqueue("wilink", cmd_mode(MODE_MANUAL))
        self._enqueue("wilink", cmd_start())
        self.hold_until = time.time() + 2 * MIN_CMD_GAP + START_COUNTDOWN
        self.pending_speed = speed
        self.target_speed = speed
        self.belt_on = True

    def start_auto(self):
        """Start the belt in Auto mode (the pad sets the speed from where you walk)."""
        if not self.connected:
            self.log("Not connected yet.")
            return
        if self.belt_on:
            return
        self.log("Starting belt in Auto mode (countdown) — walk towards the front to speed up")
        self._enqueue("wilink", cmd_mode(MODE_AUTO))
        self._enqueue("wilink", cmd_start())
        self.hold_until = time.time() + 2 * MIN_CMD_GAP + START_COUNTDOWN
        self.pending_speed = None
        self.target_speed = 0.0
        self.belt_on = True

    def stop(self, reason="Stopping belt"):
        # Emergency path: drop anything queued, stop immediately
        while not self.queue.empty():
            self.queue.get_nowait()
        self.pending_speed = None
        self.belt_on = False
        self.target_speed = 0.0
        if not self.connected:
            return
        self.log(reason)
        self._enqueue("wilink", cmd_speed(0))
        self._enqueue("wilink", cmd_mode(MODE_STANDBY))

    def set_speed(self, speed, quiet=False):
        speed = clamp_speed(speed)
        if not quiet:
            self.log(f"Speed → {speed:.1f} km/h")
        self.target_speed = speed
        self.pending_speed = speed

    PREF_KEYS = {"max_speed": 3, "start_speed": 4, "smart_start": 5, "sensitivity": 6, "child_lock": 9}

    def set_pref(self, name, value):
        """Change one of the pad's stored settings (frame F7 A6 key 00 v v v crc FD)."""
        if not self.connected:
            self.log("Not connected yet.")
            return
        key = self.PREF_KEYS[name]
        if name in ("max_speed", "start_speed"):
            v = int(round(max(MIN_SPEED, min(MAX_SPEED, float(value))) * 10))
        elif name == "sensitivity":
            v = max(1, min(3, int(value)))
        else:
            v = 1 if value else 0
        self._enqueue("wilink", [0xF7, 0xA6, key, 0, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF, 0, 0xFD])

    def read_prefs(self):
        """No read command is known; re-sending child lock (unchanged) makes the pad report all settings."""
        lock = bool((self.state.get("prefs") or {}).get("child_lock", False))
        self.set_pref("child_lock", lock)

    def set_mode(self, mode):
        m = {"auto": MODE_AUTO, "manual": MODE_MANUAL, "standby": MODE_STANDBY}[mode]
        self.log(f"Mode → {mode}")
        self._enqueue("wilink", cmd_mode(m))

    def set_sound(self, on):
        if not self.has_supplement:
            self.log("Mute isn't supported on this pad's firmware.")
            return
        self.log("Beep " + ("on" if on else "off") + " (experimental)")
        self._enqueue("supplement", SOUND_ON if on else SOUND_OFF)


# ---- Game mode ------------------------------------------------------------------
DEFAULTS = {
    # "follow" (belt follows the game) / "drive" (pad drives the game) / "none" (treadmill only)
    "direction": "follow",
    "enabled": True,           # derived from direction (kept for the UI)
    "reverse": False,          # derived from direction (kept for the UI)
    "source": "both",          # follow: keyboard / gamepad / both / wow
    "fwd_key": "W",
    "sprint_key": "shift",
    "walk_speed": 3.0,
    "sprint_speed": 5.0,
    "pad_min": 1.5,            # gamepad: speed at a light push
    "pad_max": 5.0,            # gamepad: speed at full stick
    "deadzone": 0.25,
    "idle": "slow",            # slow = crawl then stop later; stop = stop quickly
    "idle_speed": 0.5,
    "idle_timeout": 15,        # seconds at crawl before fully stopping (0 = never)
    "stop_delay": 1.5,         # 'stop' policy: ignore releases shorter than this
    # WoW without Windrunner App mode ("wow" source): belt speed per character state
    "wow_walk": 3.0,
    "wow_run": 5.0,
    "wow_mount": 3.5,
    "wow_walk_max": 4.6,       # game speeds (yd/s) up to this count as walking
    # Pad drives the game
    "rev_move": 0.5,           # belt km/h at which forward is held
    "rev_sprint": 4.0,         # belt km/h at which sprint is held too
    "rev_window": "",          # game window: only react / send keys when its title contains this
    "rev_walk_below": 3.5,     # WoW + Windrunner: belt below this → character walks, else runs (0 = always run)
    "walk_toggle_key": "numpad/",
}

LINK_LOST_STOP = 20            # s without Windrunner on screen before the belt stops


def belt_signal_keys(kmh):
    """Belt speed → 7 key taps for Windrunner: 6 bits of km/h x10 (MSB first) + even parity.
    F11 = 0, F12 = 1."""
    v = max(0, min(63, int(round(kmh * 10))))
    bits = [(v >> i) & 1 for i in range(5, -1, -1)]
    bits.append(sum(bits) % 2)
    return [VK["f12"] if b else VK["f11"] for b in bits]


def game_window_ok(s):
    """Is the game window in front? Returns (ok, title)."""
    title = foreground_title()
    tl = title.lower()
    if "walkingpad" in tl:
        return False, title
    target = s["rev_window"].strip().lower()
    if not target:
        return True, title
    if "world of warcraft" in target:
        return wow_in_front(), title
    return target in tl, title


def foreground_pid() -> int:
    if not IS_WINDOWS:
        return 0
    pid = wintypes.DWORD()
    ctypes.windll.user32.GetWindowThreadProcessId(ctypes.windll.user32.GetForegroundWindow(), ctypes.byref(pid))
    return pid.value


def self_elevated() -> bool:
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:
        return False


def process_elevated(pid):
    """True if that process runs as administrator, False if not, None if unknown."""
    if not IS_WINDOWS or not pid:
        return None
    k, a = ctypes.windll.kernel32, ctypes.windll.advapi32
    k.OpenProcess.restype = wintypes.HANDLE
    h = k.OpenProcess(0x1000, False, pid)
    if not h:
        return None
    try:
        tok = wintypes.HANDLE()
        if not a.OpenProcessToken(h, 0x0008, ctypes.byref(tok)):
            return True if k.GetLastError() == 5 else None      # access denied: it's elevated
        try:
            elev, size = wintypes.DWORD(), wintypes.DWORD()
            if a.GetTokenInformation(tok, 20, ctypes.byref(elev), 4, ctypes.byref(size)):
                return bool(elev.value)
            return None
        finally:
            k.CloseHandle(tok)
    finally:
        k.CloseHandle(h)


class GameMode:
    def __init__(self, pad: Pad):
        self.pad = pad
        self.gp = Gamepad()
        self.s = dict(DEFAULTS)
        try:
            self.s.update(json.loads(SETTINGS_FILE.read_text()))
        except Exception:
            pass
        self._derive()
        self.wow = WowBridge()
        self.wow.log = pad.log
        self.keys = KeySender()
        pad.on_connected = self.on_pad_connected
        pad.on_external_stop = self.on_external_stop
        # follow
        self.idle_since = None
        self.input_desc = "—"
        # Windrunner link
        self.link = False
        self.link_desc = ""
        self.link_lost_since = None
        self.last_moving = False
        self.suppressed = False        # you stopped the belt yourself: wait for a new move in WoW
        self.manual = False            # you started the belt from the app: the game doesn't override it
        # drive
        self.sprinting = False
        self.rev_desc = "—"
        self.admin_problem = False
        self.admin_logged = 0.0
        self.wr_seen_at = 0.0          # last time Windrunner's squares were on screen
        self.want_walk = False         # drive: gait we want from the belt speed
        self.toggles = []              # times we pressed walk/run (to detect it not working)
        self.toggle_pause_until = 0.0
        self.gait_desc = ""
        self.signal_logged = False
        self.publish()

    # -- settings --
    def _derive(self):
        if self.s.get("direction") not in ("follow", "drive", "none"):
            self.s["direction"] = "follow"
        self.s["enabled"] = self.s["direction"] == "follow"
        self.s["reverse"] = self.s["direction"] == "drive"

    def save(self):
        try:
            SETTINGS_FILE.write_text(json.dumps(self.s, indent=2))
        except Exception:
            pass

    def update(self, new):
        before = self.s["direction"]
        for k, v in dict(new).items():
            if k in DEFAULTS and k not in ("enabled", "reverse"):
                self.s[k] = type(DEFAULTS[k])(v)
        self._derive()
        self.save()
        after = self.s["direction"]
        if before != after:
            if after == "none":
                self.keys.release_all()
                self.sprinting = False
                self.manual = False
                self.link = False
                self.pad.log("Treadmill only: games no longer control the belt — use the app or the remote.")
            elif after == "drive":
                self.pad.stop("Switching to 'Pad drives the game' — stopping the belt")
                self.pad.log("Pad drives the game: the pad goes to Auto mode. Start the belt, then walk "
                             "towards the front to speed up.")
                if self.pad.connected:
                    self.pad.set_mode("auto")
            else:
                self.keys.release_all()
                self.sprinting = False
                if before == "drive":
                    self.pad.stop("Switching to 'Belt follows the game' — stopping the belt")
                else:
                    self.pad.log("Belt follows the game")
        self.publish()

    def publish(self):
        self.pad.state["game"] = {**self.s, "available": IS_WINDOWS,
                                  "gamepad": self.gp.read() is not None,
                                  "input": self.input_desc, "rev_input": self.rev_desc,
                                  "wow_status": self.wow.status,
                                  "link": self.link and self.s["direction"] == "follow",
                                  "link_desc": self.link_desc,
                                  "admin_problem": self.admin_problem}

    # -- pad events --
    def on_pad_connected(self):
        if self.s["direction"] == "drive":
            self.pad.set_mode("auto")

    def on_external_stop(self):
        """The belt stopped without the app asking (pad remote, safety)."""
        if self.link:
            self.suppressed = True
            self.pad.log("Belt stopped from the pad — it stays stopped until you start moving in WoW again")

    def user_start(self, speed):
        """Start button in the app: you're in charge until you Stop or move in the game."""
        self.suppressed = False
        if self.s["direction"] == "drive":
            self.pad.start_auto()
        else:
            self.manual = True
            self.pad.start(speed)

    def user_stop(self, reason="Stopping belt"):
        """Stop button in the app / tray: always stops; Windrunner waits for a new move."""
        if self.link:
            self.suppressed = True
        self.manual = False
        self.keys.release_all()
        self.sprinting = False
        self.pad.stop(reason)

    # -- Belt follows the game: keyboard / gamepad / WoW without Windrunner App mode --
    def desired_speed(self):
        s, src = self.s, self.s["source"]
        ok, title = game_window_ok(s)
        if not ok:
            return 0.0, f"waiting for the game window (in front: '{title[:40]}')"
        if src == "wow":
            return self.wow_speed()
        best, desc = 0.0, "idle"
        if src in ("keyboard", "both") and key_down(vk_for(s["fwd_key"])):
            if key_down(vk_for(s["sprint_key"])):
                best, desc = s["sprint_speed"], f"{s['fwd_key'].upper()} + {s['sprint_key']} (sprint)"
            else:
                best, desc = s["walk_speed"], f"{s['fwd_key'].upper()} (walk)"
        if src in ("gamepad", "both"):
            r = self.gp.read()
            if r:
                y, click = r
                if y > s["deadzone"]:
                    n = (y - s["deadzone"]) / (1 - s["deadzone"])
                    sp = s["pad_max"] if click else s["pad_min"] + n * (s["pad_max"] - s["pad_min"])
                    if sp > best:
                        best, desc = sp, f"stick {round(y * 100)}%" + (" + click (sprint)" if click else "")
        return round(best, 1), desc

    def wow_speed(self):
        s = self.s
        r = self.wow.last if self.wow.last else None
        if not r:
            return 0.0, "WoW: " + self.wow.status
        if not r["moving"]:
            return 0.0, "WoW: standing still"
        if r["mounted"] or r["taxi"] or r["vehicle"]:
            sp, label = s["wow_mount"], "mounted"
        elif not r["known"]:
            sp, label = s["wow_run"], "moving (speed hidden by WoW right now)"
        elif r["speed"] <= s["wow_walk_max"]:
            sp, label = s["wow_walk"], f"walking {r['speed']:.1f} yd/s"
        else:
            sp, label = s["wow_run"], f"running {r['speed']:.1f} yd/s"
        if sp <= 0:
            return 0.0, f"WoW: {label} → rest"
        return round(sp, 1), f"WoW: {label}"

    def follow_step(self):
        pad, now = self.pad, time.time()
        if not pad.connected:
            self.idle_since = None
            self.input_desc = "waiting for the treadmill to connect"
            return
        want, self.input_desc = self.desired_speed()
        if self.manual:
            if want > 0 or not pad.belt_on:
                self.manual = False            # you moved in the game (or the belt stopped): game takes over
            else:
                self.input_desc = "started from the app — the game takes over when you move"
                return
        if want > 0:
            self.idle_since = None
            if not pad.belt_on:
                pad.start(want, quiet=True)
            elif abs(want - pad.target_speed) >= 0.1:
                pad.set_speed(want, quiet=True)
        elif pad.belt_on:
            if self.idle_since is None:
                self.idle_since = now
            idle_for = now - self.idle_since
            if self.s["idle"] == "stop":
                if idle_for >= self.s["stop_delay"]:
                    pad.stop("Not moving in game — stopping")
            else:
                if pad.target_speed != clamp_speed(self.s["idle_speed"]):
                    pad.set_speed(self.s["idle_speed"], quiet=True)
                if self.s["idle_timeout"] > 0 and idle_for >= self.s["idle_timeout"]:
                    pad.stop(f"Idle {int(self.s['idle_timeout'])}s — stopping")

    # -- Belt follows the game: Windrunner App mode (Windrunner decides) --
    def link_step(self, r):
        pad, now = self.pad, time.time()
        if not self.link:
            self.link = True
            self.suppressed = False
            pad.log("Windrunner (App mode) detected — the belt now does what Windrunner asks.")
        if self.link_lost_since is not None:
            self.link_lost_since = None
        moving_started = r["moving"] and not self.last_moving
        self.last_moving = r["moving"]
        if not pad.connected:
            self.link_desc = "waiting for the treadmill to connect"
            return
        if self.suppressed and (moving_started or not r["run"]):
            self.suppressed = False          # a new move in WoW (or Windrunner stopped too): re-arm
        if self.manual:
            if moving_started or not pad.belt_on:
                self.manual = False
            else:
                self.link_desc = "started from the app — Windrunner takes over when you move"
                return
        target = clamp_speed(r["target"] or 1.0)
        if r["run"] and not self.suppressed:
            if not pad.belt_on:
                pad.log(f"Windrunner: belt on, {target:.1f} km/h")
                pad.start(target, quiet=True)
            elif abs(target - pad.target_speed) >= 0.1:
                pad.set_speed(target, quiet=True)
            what = "idle" if not r["moving"] else ("mounted" if r["mounted"] or r["taxi"] or r["vehicle"]
                                                   else "walking" if r["known"] and r["speed"] <= 4.6 else "running")
            self.link_desc = ("countdown… " if time.time() < pad.hold_until else "") + f"{what} → {target:.1f} km/h"
        else:
            if pad.belt_on:
                pad.stop("Windrunner: belt off")
            self.link_desc = ("stopped by you — start moving in WoW to restart" if self.suppressed
                              else "belt off — start moving in WoW (or press Start in Windrunner)")

    def link_lost(self):
        """Windrunner was in control but isn't visible (WoW minimised / covered / closed)."""
        pad, now = self.pad, time.time()
        if self.link_lost_since is None:
            self.link_lost_since = now
            if pad.belt_on:
                pad.log("Windrunner not visible (WoW minimised or covered?) — slowing down")
        lost_for = now - self.link_lost_since
        if pad.belt_on:
            if pad.target_speed != MIN_SPEED:
                pad.set_speed(MIN_SPEED, quiet=True)
            if lost_for >= LINK_LOST_STOP:
                pad.stop(f"Windrunner not visible for {LINK_LOST_STOP}s — stopping the belt")
        self.link_desc = f"WoW not visible ({int(lost_for)} s)"
        if lost_for > 120:
            self.link = False
            pad.log("Windrunner link ended")

    # -- Pad drives the game --
    def drive_step(self, windrunner_visible):
        s, pad = self.s, self.pad
        speed = pad.state["speed"]
        fresh = pad.connected and time.time() - pad.last_status_time < 3
        ok, title = game_window_ok(s)
        auto = pad.state.get("mode") == "auto"        # only Auto-mode walking drives the game
        fwd = fresh and ok and auto and speed >= s["rev_move"]
        if fwd and speed >= s["rev_sprint"]:
            self.sprinting = True
        elif not fwd or speed < s["rev_sprint"] - 0.3:      # small gap so it doesn't flicker
            self.sprinting = False
        # Windows blocks keys sent to a program running as administrator, unless we are too
        self.admin_problem = False
        if fwd and IS_WINDOWS and not self_elevated() and process_elevated(foreground_pid()):
            self.admin_problem = True
            if time.time() - self.admin_logged > 60:
                self.admin_logged = time.time()
                pad.log(f"'{title[:40]}' runs as administrator, so Windows blocks the keys this app sends. "
                        "Use 'Restart as administrator' in the Gaming panel.")
        self.keys.set(vk_for(s["fwd_key"]), fwd)
        self.keys.set(vk_for(s["sprint_key"]), fwd and self.sprinting)
        if not pad.connected:
            self.rev_desc = "waiting for the treadmill to connect"
        elif not fresh:
            self.rev_desc = "no data from the pad"
        elif not ok:
            self.rev_desc = f"waiting for the game window (in front: '{title[:40]}')"
        elif self.admin_problem:
            self.rev_desc = "the game runs as administrator — restart WalkingPad as administrator"
        elif fwd:
            self.rev_desc = f"belt {speed:.1f} km/h → holding {s['fwd_key'].upper()}" + (
                f" + {s['sprint_key']}" if self.sprinting and vk_for(s["sprint_key"]) else "")
        else:
            self.rev_desc = f"belt {speed:.1f} km/h → standing" + (
                "" if pad.state.get("mode") == "auto" else " (pad not in Auto mode)")
        if windrunner_visible and self.gait_desc:
            self.rev_desc += " · " + self.gait_desc

    def gait_step(self, r):
        """Pad drives WoW: make the character walk below a belt speed, run above it (numpad /)."""
        s, pad, now = self.s, self.pad, time.time()
        thr = s["rev_walk_below"]
        self.gait_desc = ""
        if thr <= 0 or not r or not self.keys.held:
            return
        speed = pad.state.get("speed", 0.0)
        if self.want_walk and speed >= thr + 0.2:      # small gap so it doesn't flip-flop
            self.want_walk = False
        elif not self.want_walk and speed < thr - 0.2:
            self.want_walk = True
        on_foot = not (r.get("mounted") or r.get("taxi") or r.get("vehicle") or r.get("swimming"))
        if not (r.get("moving") and r.get("known") and on_foot and "walking" in r):
            self.gait_desc = "walk/run: waiting (mounted, swimming, or speed hidden by WoW)"
            return
        want = "walk" if self.want_walk else "run"
        have = "walk" if r.get("walking") else "run"
        self.gait_desc = f"character {have}s" + ("" if want == have else f" → switching to {want}")
        if want == have or now < self.toggle_pause_until or now - (self.toggles[-1] if self.toggles else 0) < 1.5:
            return
        self.toggles = [t for t in self.toggles if now - t < 20] + [now]
        if len(self.toggles) > 4:                       # WoW isn't following: stop trying for a while
            self.toggle_pause_until = now + 30
            self.toggles = []
            pad.log("Walk/run switching paused: WoW didn't follow. Is numpad / still 'Toggle Run/Walk' "
                    "(Windrunner sets it) and is Windrunner up to date?")
            return
        self.keys.tap(vk_for(s["walk_toggle_key"]))

    async def belt_signal_loop(self):
        """Once a second, tell Windrunner the real belt speed (F11/F12 taps) while WoW is in front."""
        while True:
            await asyncio.sleep(1.0)
            pad = self.pad
            try:
                if not (pad.connected and time.time() - self.wr_seen_at < 5 and wow_in_front()):
                    continue
            except Exception:
                continue
            running = pad.state.get("belt") == "running"
            kmh = pad.state.get("speed", 0.0) if running else 0.0
            for vk in belt_signal_keys(kmh):
                self.keys.tap(vk)
                await asyncio.sleep(0.04)
            if not self.signal_logged:
                self.signal_logged = True
                pad.log("Sending the belt speed to Windrunner (F11/F12, once a second while WoW is in front)")

    async def loop(self):
        last_pub = 0
        asyncio.create_task(self.belt_signal_loop())
        last_err = 0.0
        while True:
            await asyncio.sleep(0.05)
            try:
                last_pub = self._tick(last_pub)
            except Exception as e:             # never let one bad reading freeze the game logic
                self.keys.release_all()
                if time.time() - last_err > 30:
                    last_err = time.time()
                    import traceback
                    self.pad.log(f"Game logic error (keys released): {e}")
                    print(traceback.format_exc())

    def _tick(self, last_pub):
        if True:
            r = self.wow.read() if IS_WINDOWS else None
            if r is None and getattr(self, "sim_wow", None):
                r = self.sim_wow()                    # tests: simulated Windrunner squares
            if r is not None:
                self.wr_seen_at = time.time()
            windrunner = r if r and r.get("app_mode") else None
            if self.s["direction"] == "none":
                self.link = False                      # treadmill only: no game input at all
                self.input_desc = "treadmill only — games don't control the belt"
            elif self.s["direction"] == "drive":
                self.link = False
                self.drive_step(windrunner is not None)
                self.gait_step(r)
            elif windrunner:
                self.link_step(windrunner)
            elif self.link and r is None:
                self.link_lost()
            else:
                if self.link:                          # addon visible again but in Manual mode
                    self.link = False
                    self.pad.log("Windrunner is in Manual mode — the app no longer drives the belt from WoW")
                    if self.pad.belt_on:
                        self.pad.stop("Stopping the belt")
                self.follow_step()
            now = time.time()
            if now - last_pub > 0.25:
                last_pub = now
                self.publish()
                self.pad.push()
        return last_pub


# ---- web server -----------------------------------------------------------------
pad = None
game = None
BASE = Path(getattr(sys, "_MEIPASS", Path(__file__).parent))   # bundled files when packaged
HTML = (BASE / "walkingpad_ui.html").read_text(encoding="utf-8")


def install_wow_addon():
    """Copy the bundled addon into every WoW install found (retail and classic flavours)."""
    import shutil
    src = BASE / "Windrunner"
    roots = []
    if IS_WINDOWS:
        import winreg
        for key in (r"SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft",
                    r"SOFTWARE\Blizzard Entertainment\World of Warcraft"):
            try:
                with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, key) as k:
                    roots.append(Path(winreg.QueryValueEx(k, "InstallPath")[0]).parent)
            except OSError:
                pass
        for drive in "CDEFG":
            for sub in (r"Program Files (x86)\World of Warcraft", r"Program Files\World of Warcraft",
                        r"World of Warcraft", r"Games\World of Warcraft"):
                roots.append(Path(f"{drive}:\\") / sub)
    done = []
    for root in dict.fromkeys(roots):
        if not root.is_dir():
            continue
        for flavour in root.glob("_*_"):
            addons = flavour / "Interface" / "AddOns"
            if (flavour / "Interface").is_dir() or (flavour / "WTF").is_dir():
                try:
                    addons.mkdir(parents=True, exist_ok=True)
                    shutil.copytree(src, addons / "Windrunner", dirs_exist_ok=True)
                    old = addons / "WalkingPadBridge"          # earlier name of this addon
                    if old.is_dir():
                        shutil.rmtree(old, ignore_errors=True)
                    done.append(str(addons / "Windrunner"))
                except Exception as e:
                    pad.log(f"Couldn't write to {addons}: {e}")
    if done:
        pad.log("Windrunner addon installed: " + "; ".join(done) + " — restart WoW or type /reload")
    else:
        pad.log("Couldn't find WoW. Copy the Windrunner folder into "
                "World of Warcraft\\_retail_\\Interface\\AddOns yourself.")


async def index(_req):
    return web.Response(text=HTML, content_type="text/html")


async def ws_handler(req):
    ws = web.WebSocketResponse(heartbeat=20)
    await ws.prepare(req)
    pad.listeners.add(ws)
    await ws.send_str(json.dumps(pad.state))
    async for msg in ws:
        if msg.type != WSMsgType.TEXT:
            continue
        try:
            m = json.loads(msg.data)
            a = m.get("action")
            if a == "start":
                game.user_start(float(m.get("speed", 2.0)))
            elif a == "stop":
                game.user_stop()
            elif a == "restart_admin":
                asyncio.create_task(restart_as_admin())
            elif a == "speed":
                pad.set_speed(float(m["speed"]))
            elif a == "mode":
                pad.set_mode(m["mode"])
            elif a == "sound":
                pad.set_sound(bool(m["on"]))
            elif a == "raw":
                pad.send_raw(m["hex"], m.get("char", "fe02"), bool(m.get("crc", True)))
            elif a == "raw_log":
                pad.raw_log = pad.state["raw_log"] = bool(m["on"])
                pad.state["raw_stats"] = bool(m.get("stats", False))
                pad.push()
            elif a == "pref":
                pad.set_pref(m["name"], m["value"])
            elif a == "read_prefs":
                pad.read_prefs()
            elif a == "wow_check":
                if IS_WINDOWS:
                    game.wow.diagnose()
                else:
                    pad.log("The WoW link needs Windows")
            elif a == "install_wow":
                install_wow_addon()
            elif a == "game":
                game.update(m.get("settings", {}))
                pad.push()
        except Exception as e:
            pad.log(f"Bad command: {e}")
    pad.listeners.discard(ws)
    return ws


LOOP = None
READY = None


async def main(open_browser=True):
    global pad, game, LOOP
    LOOP = asyncio.get_running_loop()
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    pad = Pad(args[0] if args else None)
    game = GameMode(pad)
    app = web.Application()
    app.router.add_get("/", index)
    app.router.add_get("/ws", ws_handler)
    runner = web.AppRunner(app)
    await runner.setup()
    await web.TCPSite(runner, "127.0.0.1", PORT).start()
    print(f"WalkingPad Control build {BUILD}  http://localhost:{PORT}")
    if open_browser:
        webbrowser.open(f"http://localhost:{PORT}")
    if READY:
        READY.set()
    asyncio.create_task(game.loop())
    await pad.connect_loop()


async def shutdown():
    """Closing the app: stop the treadmill, let go of game keys, free the Bluetooth connection."""
    if game:
        game.keys.release_all()
        game.s["enabled"] = game.s["reverse"] = False
    if pad and pad.connected:
        pad.stop("App closing — stopping the treadmill")
        for _ in range(40):                       # wait for the stop commands to go out
            if pad.queue.empty():
                break
            await asyncio.sleep(0.1)
        await asyncio.sleep(0.9)
        try:
            await asyncio.wait_for(pad.client.disconnect(), 3)
        except Exception:
            pass


async def restart_as_admin():
    """Re-launch this app elevated (needed when the game runs as administrator)."""
    import os
    if not IS_WINDOWS:
        return
    await shutdown()
    if getattr(sys, "frozen", False):
        exe, params = sys.executable, ""
    else:
        exe, params = sys.executable, f'"{Path(__file__).resolve()}"'
    r = ctypes.windll.shell32.ShellExecuteW(None, "runas", exe, params, None, 1)
    if r > 32:
        os._exit(0)
    pad.log("Restart as administrator was cancelled")


def tray_image():
    from PIL import Image, ImageDraw
    img = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((2, 2, 62, 62), radius=14, fill=(232, 89, 12, 255))
    # a little treadmill: belt + two footsteps
    d.rounded_rectangle((10, 40, 54, 50), radius=5, fill=(255, 255, 255, 255))
    d.ellipse((18, 14, 28, 30), fill=(255, 255, 255, 255))
    d.ellipse((34, 20, 44, 36), fill=(255, 255, 255, 255))
    return img


def can_use_app_window():
    """The app window needs .NET Framework 4.6.2+ and the Edge WebView2 runtime (standard on Windows 10/11)."""
    if not IS_WINDOWS:
        return False
    import winreg
    try:
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full") as k:
            if winreg.QueryValueEx(k, "Release")[0] < 394802:
                return False
    except OSError:
        return False
    guid = "{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"
    for hive, path in ((winreg.HKEY_LOCAL_MACHINE, rf"SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{guid}"),
                       (winreg.HKEY_LOCAL_MACHINE, rf"SOFTWARE\Microsoft\EdgeUpdate\Clients\{guid}"),
                       (winreg.HKEY_CURRENT_USER, rf"SOFTWARE\Microsoft\EdgeUpdate\Clients\{guid}")):
        try:
            with winreg.OpenKey(hive, path) as k:
                v = winreg.QueryValueEx(k, "pv")[0]
                if v and v != "0.0.0.0":
                    return True
        except OSError:
            pass
    return False


def port_in_use():
    import socket
    with socket.socket() as sock:
        sock.settimeout(0.3)
        return sock.connect_ex(("127.0.0.1", PORT)) == 0


def run_desktop():
    """Own window + tray icon. Closing the window quits everything; minimising hides it to the tray."""
    global READY
    import os
    import threading
    url = f"http://localhost:{PORT}"
    for _ in range(16):               # a restarting copy may still be closing
        if not port_in_use():
            break
        time.sleep(0.5)
    else:                             # already running: just show it
        webbrowser.open(url)
        return
    READY = threading.Event()

    def server_thread():
        try:
            asyncio.run(main(open_browser=False))
        except Exception:
            import traceback
            LOG_FILE.write_text(traceback.format_exc())
            READY.set()

    threading.Thread(target=server_thread, daemon=True).start()
    READY.wait(20)

    state = {"window": None, "icon": None, "quitting": False, "told": False}

    def quit_app():
        if state["quitting"]:
            return
        state["quitting"] = True
        try:
            asyncio.run_coroutine_threadsafe(shutdown(), LOOP).result(10)
        except Exception:
            pass
        try:
            if state["icon"]:
                state["icon"].stop()
        except Exception:
            pass
        os._exit(0)

    def show_window(*_):
        w = state["window"]
        if w:
            w.show()
            try:
                w.restore()
            except Exception:
                pass
        else:
            webbrowser.open(url)

    def stop_belt(*_):
        LOOP.call_soon_threadsafe(lambda: game.user_stop("Stopped from the tray"))

    def tray_quit(*_):
        if state["window"]:
            state["window"].destroy()     # webview.start() returns, then quit_app() runs
        else:
            quit_app()

    try:
        import pystray
        icon = pystray.Icon("WalkingPad", tray_image(), "WalkingPad Control", menu=pystray.Menu(
            pystray.MenuItem("Open WalkingPad", show_window, default=True),
            pystray.MenuItem("Stop treadmill", stop_belt),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem("Quit", tray_quit)))
        icon.run_detached()
        state["icon"] = icon
    except Exception as e:
        print("Tray icon unavailable:", e)

    try:
        if not can_use_app_window():
            raise RuntimeError("Edge WebView2 / .NET not available")
        import webview
        window = webview.create_window("WalkingPad Control", url, width=500, height=760,
                                       min_size=(380, 480), background_color="#141412")
        state["window"] = window

        def on_minimized():
            if not state["icon"]:
                return                    # no tray: keep normal minimise
            window.hide()
            if not state["told"]:
                state["told"] = True
                try:
                    state["icon"].notify("Still running in the tray. Right-click the icon to quit.",
                                         "WalkingPad Control")
                except Exception:
                    pass

        window.events.minimized += on_minimized
        webview.start()                   # blocks until the window is closed
    except Exception as e:
        print("App window unavailable, using the browser:", e)
        state["window"] = None
        webbrowser.open(url)
        if state["icon"]:
            while not state["quitting"]:  # tray "Quit" ends it
                time.sleep(0.5)
    quit_app()


if __name__ == "__main__":
    import atexit
    if sys.stdout is None:            # windowed .exe has no console: send prints to the log file
        try:
            sys.stdout = sys.stderr = open(LOG_FILE, "a", encoding="utf-8", buffering=1)
        except Exception:
            pass

    def _release():
        if game:
            game.keys.release_all()

    atexit.register(_release)
    try:
        if IS_WINDOWS and "--console" not in sys.argv:
            run_desktop()
        else:
            asyncio.run(main())
    except KeyboardInterrupt:
        pass
    finally:
        _release()
