"""The black / white link strip: resolutions, colour effects, misreads (needs Pillow)."""
import random
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "app"))
import walkingpad_app as app

try:
    from PIL import Image, ImageEnhance, ImageFilter
except ImportError:                      # pragma: no cover
    Image = None

FIELDS = ("moving", "mounted", "known", "swimming", "taxi", "vehicle", "walking",
          "app_mode", "session_active", "in_combat")


def random_state(rng):
    st = {k: rng.random() > 0.5 for k in FIELDS}
    st["speed"] = rng.choice([0, 2.5, 7.0, 14.0, 25.0])
    st["target"] = rng.choice([0, 1.0, 3.0, 5.0, 6.0])
    st["run"] = rng.random() > 0.4
    return st


def matches(d, st):
    if d is None:
        return False
    if any(d[k] != bool(st[k]) for k in FIELDS):
        return False
    speed = st["speed"] if st["known"] else 0
    return (abs(d["speed"] - speed) < 0.051 and abs(d["target"] - st["target"]) < 0.051
            and d["run"] == (bool(st["run"]) and st["target"] > 0))


def screen(rng, st, ph, x0=0, y0=0):
    """WoW's top-left as Windrunner draws it at physical screen height ph, over a busy scene."""
    cell = max(4, round(ph / 135))
    img = Image.new("RGB", (800, 100), (40, 90, 60))
    for _ in range(300):
        x, y = rng.randrange(800), rng.randrange(100)
        img.paste(tuple(rng.randrange(256) for _ in range(3)), (x, y, x + 9, y + 9))
    for i, c in enumerate(app.encode_strip(st)):
        cx, cy = x0 + (i % app.STRIP_COLS) * cell, y0 + (i // app.STRIP_COLS) * cell
        img.paste((255, 255, 255) if c else (0, 0, 0), (cx, cy, cx + cell, cy + cell))
    return img


def decode(img):
    return app.decode_image(img.convert("RGBA").tobytes("raw", "BGRA"), img.width, img.height)[0]


EFFECTS = {
    "plain": lambda im, rng: im,
    "HDR washout": lambda im, rng: im.point(lambda v: 45 + v * 0.62),
    "Night Light": lambda im, rng: Image.merge("RGB", (im.split()[0], im.split()[1].point(lambda v: v * 0.85),
                                                      im.split()[2].point(lambda v: v * 0.45))),
    "gamma 2.2": lambda im, rng: im.point(lambda v: 255 * (v / 255) ** 2.2),
    "gamma 0.45": lambda im, rng: im.point(lambda v: 255 * (v / 255) ** 0.45),
    "dimmed": lambda im, rng: ImageEnhance.Brightness(im).enhance(0.35),
    "low contrast": lambda im, rng: ImageEnhance.Contrast(im).enhance(0.3),
    "blur": lambda im, rng: im.filter(ImageFilter.GaussianBlur(1.2)),
    "noise": lambda im, rng: Image.eval(im, lambda v: max(0, min(255, v + rng.randint(-25, 25)))),
    "greyscale filter": lambda im, rng: im.convert("L").convert("RGB").point(lambda v: v * 0.8 + 20),
    "sharpened (TV)": lambda im, rng: im.filter(ImageFilter.SHARPEN).filter(ImageFilter.SHARPEN),
}


class StripCodecTests(unittest.TestCase):
    def test_round_trip(self):
        rng = random.Random(1)
        for _ in range(500):
            st = random_state(rng)
            self.assertTrue(matches(app.decode_bits(app.encode_strip(st)), st))

    def test_every_single_block_error_is_rejected(self):
        cells = app.encode_strip(random_state(random.Random(2)))
        for i in range(4, len(cells)):
            bad = list(cells)
            bad[i] ^= 1
            self.assertIsNone(app.decode_bits(bad), i)

    def test_run_needs_a_speed(self):
        st = dict.fromkeys(FIELDS, False, ) | {"app_mode": True, "session_active": True, "run": True,
                                                "speed": 0, "target": 0}
        self.assertFalse(app.decode_bits(app.encode_strip(st))["run"])


@unittest.skipIf(Image is None, "needs Pillow")
class StripImageTests(unittest.TestCase):
    def test_resolutions_and_colour_effects(self):
        rng = random.Random(7)
        for ph in (720, 1080, 1440, 1600, 2160, 4320):
            for name, fx in EFFECTS.items():
                for _ in range(3):
                    st = random_state(rng)
                    img = fx(screen(rng, st, ph, x0=rng.choice([0, 1, 2]), y0=rng.choice([0, 1])), rng)
                    with self.subTest(height=ph, effect=name):
                        self.assertTrue(matches(decode(img), st))

    def test_resampled_images(self):
        rng = random.Random(3)
        for scale in (0.8, 1.25, 1.333, 1.5):
            st = random_state(rng)
            img = screen(rng, st, 1080)
            img = img.resize((int(800 * scale), int(100 * scale)), Image.BILINEAR).crop((0, 0, 800, 100))
            with self.subTest(scale=scale):
                self.assertTrue(matches(decode(img), st))

    def test_noise_never_decodes(self):
        rng = random.Random(5)
        for _ in range(300):
            img = Image.new("RGB", (800, 100))
            for _ in range(400):
                x, y = rng.randrange(800), rng.randrange(100)
                img.paste(rng.choice([(0, 0, 0), (255, 255, 255)]),
                          (x, y, x + rng.randint(4, 20), y + rng.randint(4, 20)))
            self.assertIsNone(decode(img))


if __name__ == "__main__":
    unittest.main()
