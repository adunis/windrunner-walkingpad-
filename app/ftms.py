"""Bluetooth Fitness Machine Service (FTMS) treadmill client.

This is a small independent implementation of the standard FTMS control point,
used by treadmills such as the Domyos RUN500. It does not start a belt on connect.
"""
import asyncio
import struct
import time

FTMS_SERVICE = "00001826-0000-1000-8000-00805f9b34fb"
FEATURE = "00002acc-0000-1000-8000-00805f9b34fb"
TREADMILL_DATA = "00002acd-0000-1000-8000-00805f9b34fb"
SPEED_RANGE = "00002ad4-0000-1000-8000-00805f9b34fb"
CONTROL_POINT = "00002ad9-0000-1000-8000-00805f9b34fb"
MACHINE_STATUS = "00002ada-0000-1000-8000-00805f9b34fb"

# FTMS Fitness Machine Control Point opcodes
_REQUEST_CONTROL = 0x00
_SET_TARGET_SPEED = 0x02
_START_OR_RESUME = 0x07
_STOP_OR_PAUSE = 0x08
_RESPONSE = 0x80


class FtmsError(RuntimeError):
    pass


class FtmsTreadmill:
    """FTMS GATT adapter using a connected BleakClient."""

    def __init__(self, client, on_data, log=print):
        self.client = client
        self.on_data = on_data
        self.log = log
        self.minimum_kmh = 0.0
        self.maximum_kmh = 0.0
        self.increment_kmh = 0.0
        self.target_speed_supported = False
        self._response = None
        self._command_lock = asyncio.Lock()
        self._last_data = 0.0

    async def initialize(self):
        chars = {c.uuid.lower(): c for svc in self.client.services for c in svc.characteristics}
        missing = [u for u in (FEATURE, TREADMILL_DATA, SPEED_RANGE, CONTROL_POINT) if u not in chars]
        if missing:
            raise FtmsError("FTMS service is missing required characteristics: " + ", ".join(missing))

        feature = bytes(await self.client.read_gatt_char(chars[FEATURE]))
        if len(feature) < 8:
            raise FtmsError("FTMS Feature characteristic is too short")
        # The second 32-bit field advertises target-setting support.
        target_features = int.from_bytes(feature[4:8], "little")
        self.target_speed_supported = bool(target_features & 0x00000001)
        if not self.target_speed_supported:
            raise FtmsError("Treadmill reports no FTMS target-speed control")

        speed_range = bytes(await self.client.read_gatt_char(chars[SPEED_RANGE]))
        if len(speed_range) < 6:
            raise FtmsError("FTMS Supported Speed Range is invalid")
        lo, hi, inc = struct.unpack_from("<HHH", speed_range)
        self.minimum_kmh, self.maximum_kmh, self.increment_kmh = lo / 100, hi / 100, inc / 100
        if self.maximum_kmh <= 0 or self.minimum_kmh < 0 or self.maximum_kmh < self.minimum_kmh:
            raise FtmsError("Treadmill reported an invalid FTMS speed range")

        await self.client.start_notify(chars[TREADMILL_DATA], self._on_treadmill_data)
        await self.client.start_notify(chars[CONTROL_POINT], self._on_control_response)
        self._control_uuid = chars[CONTROL_POINT].uuid
        await self._command(bytes([_REQUEST_CONTROL]))
        self.log(f"FTMS ready: target speed {self.minimum_kmh:.2f}–{self.maximum_kmh:.2f} km/h")
        return self

    def _on_control_response(self, _sender, data):
        data = bytes(data)
        if len(data) >= 3 and data[0] == _RESPONSE and self._response and not self._response.done():
            self._response.set_result((data[1], data[2]))

    async def _command(self, payload):
        async with self._command_lock:
            loop = asyncio.get_running_loop()
            future = loop.create_future()
            self._response = future
            try:
                await self.client.write_gatt_char(self._control_uuid, payload, response=True)
                try:
                    opcode, result = await asyncio.wait_for(future, timeout=5.0)
                except asyncio.TimeoutError as exc:
                    raise FtmsError(f"No FTMS response for opcode 0x{payload[0]:02x}") from exc
                if opcode != payload[0]:
                    raise FtmsError("FTMS response opcode did not match request")
                if result != 0x01:
                    labels = {0x02: "not supported", 0x03: "invalid parameter", 0x04: "operation failed",
                              0x05: "control not permitted"}
                    raise FtmsError("FTMS command rejected: " + labels.get(result, f"result 0x{result:02x}"))
            finally:
                self._response = None

    async def request_control(self):
        await self._command(bytes([_REQUEST_CONTROL]))

    async def set_speed(self, kmh):
        if not self.target_speed_supported:
            raise FtmsError("Target speed is not supported")
        kmh = min(self.maximum_kmh, max(self.minimum_kmh, float(kmh)))
        # FTMS Target Speed is unsigned 16-bit in units of 0.01 km/h.
        await self._command(bytes([_SET_TARGET_SPEED]) + struct.pack("<H", int(round(kmh * 100))))

    async def start(self, kmh):
        # Explicit user/game Start action only; connecting never starts the treadmill.
        await self.set_speed(kmh)
        await self._command(bytes([_START_OR_RESUME]))

    async def stop(self):
        await self._command(bytes([_STOP_OR_PAUSE, 0x01]))

    async def set_mode(self, mode):
        # FTMS provides no Auto/Manual walk mode equivalent.
        return None

    def _on_treadmill_data(self, _sender, data):
        b = bytes(data)
        if len(b) < 4:
            return
        flags = int.from_bytes(b[:2], "little")
        i = 2
        speed = None
        if not (flags & 0x0001):     # bit 0: More Data; if clear, instantaneous speed is present
            speed = int.from_bytes(b[i:i + 2], "little") / 100
            i += 2
        if flags & 0x0002:           # Average Speed
            i += 2
        distance = None
        if flags & 0x0004:           # Total Distance, uint24 metres
            if len(b) < i + 3:
                return
            distance = int.from_bytes(b[i:i + 3], "little")
            i += 3
        # Skip optional fields preceding elapsed time in the FTMS data layout.
        if flags & 0x0008: i += 2   # Inclination
        if flags & 0x0010: i += 2   # Elevation Gain
        if flags & 0x0020: i += 1   # Instantaneous Pace
        if flags & 0x0040: i += 1   # Average Pace
        if flags & 0x0080: i += 5   # Expended Energy
        if flags & 0x0100: i += 1   # Heart Rate
        if flags & 0x0200: i += 1   # MET
        elapsed = None
        if flags & 0x0400 and len(b) >= i + 2:
            elapsed = int.from_bytes(b[i:i + 2], "little")
        if speed is not None:
            self._last_data = time.time()
            self.on_data({"speed": speed, "distance_m": distance, "elapsed_s": elapsed})
