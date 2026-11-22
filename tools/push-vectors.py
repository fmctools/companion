# push-vectors.json: PUSH (stub 8, cmf-watch-sdk docs/widget-push.md) as the phone sends it: for a watch app's
# background jobs, and Weather's columns card (stub 9). The records come from the SDK's own install.widget_record and
# install.columns_record (needs the SDK's venv: pycryptodome; -B leaves that checkout as it is).
#   export CMF_SDK=~/.herdr/worktrees/cmf-watch-sdk/widget-templates
#   $CMF_SDK/.venv/bin/python -B tools/push-vectors.py > ios/WireKit/Tests/WireKitTests/push-vectors.json
import json, os, sys

sys.path.insert(0, os.path.join(os.path.expanduser(os.environ.get("CMF_SDK", "~/Developer/pet/cmf-watch-sdk")), "src"))
from wp2apps import install, package  # noqa: E402

widgets = [("USD", "92.41"), ("Погода в Москве сегодня", "−3° снег, ветер 5 м/с\nзавтра −7°"), ("", ""),
           ("A title of exactly 23 b", "a value that is longer than thirty-nine bytes for sure")]
GOLDEN = [("Now", 6, "-3\u00b0"), ("23:00", 2, "-4\u00b0"), ("00:00", 0, "-5\u00b0"), ("01:00", 7, "0\u00b0")]
columns = [
    ("golden, four columns", GOLDEN),
    ("one column", GOLDEN[:1]),
    ("two columns", GOLDEN[:2]),
    ("three, one without an icon", GOLDEN[:2] + [("00:00", None, "--")]),
    ("exactly 9 bytes stay", [("123456789", 15, "1234567\u00b0")]),
    ("\u00b0 doesn't fit in the 9th byte", [("ab", None, "12345678\u00b0")]),
    ("cut 2, 3 and 4 byte characters", [("\u041f" * 5, 1, "\u20ac" * 4), ("12345678\U0001f327", 2, "123456\U0001f327")]),
    ("cut between code points, not graphemes", [("1234567e\u0301", 3, "12345678\r\n")]),
    ("empty fields", [("", None, "")]),
]
bad_columns = [[], [("a", None, "b")] * 5, [("a", 16, "b")], [("a", -1, "b")]]


def named(cols):
    return [{"caption": c, "icon": i, "value": v} for c, i, v in cols]


for c in bad_columns:
    try:
        install.columns_record(c)
    except ValueError:
        continue
    raise SystemExit(f"columns_record took {c}")
card = install.columns_record(GOLDEN)

# Weather's card (docs/miniapp-rpc.md): the forecast's hourly entries from `start`, one per hour, as (temp, WMO code),
# and the current one, seen at `at` on the phone's clock. The expected columns are the contract's, the bytes the SDK's.
D = "\u00b0"
DAY = [(h, 3) for h in range(26)]
cards = [
    ("golden: past midnight", "2026-11-22T22:40", "2026-11-22T22:00", (-2.5, 73),
     [(-2.0, 3), (-3.5, 3), (-5.4, 0), (-0.4, 95), (4, 1)], GOLDEN),
    ("the last hour of the day", "2026-12-31T23:59", "2026-12-31T23:00", (1, 0),
     [(1, 0), (2, 1), (3, 45), (4, 51)],
     [("Now", 0, "1" + D), ("00:00", 1, "2" + D), ("01:00", 3, "3" + D), ("02:00", 4, "4" + D)]),
    ("zero-padded, on the hour itself", "2026-11-22T07:00", "2026-11-22T07:00", (7, 2), DAY,
     [("Now", 1, "7" + D), ("08:00", 2, "1" + D), ("09:00", 2, "2" + D), ("10:00", 2, "3" + D)]),
    ("a stale cache counts from the phone's clock", "2026-11-22T10:15", "2026-11-22T06:00", (12.3, 61), DAY,
     [("Now", 5, "12" + D), ("11:00", 2, "5" + D), ("12:00", 2, "6" + D), ("13:00", 2, "7" + D)]),
    ("a stale cache from yesterday", "2026-11-23T01:05", "2026-11-22T21:00", (0, 0), DAY,
     [("Now", 0, "0" + D), ("02:00", 2, "5" + D), ("03:00", 2, "6" + D), ("04:00", 2, "7" + D)]),
    ("three columns", "2026-11-22T22:10", "2026-11-22T22:00", (3, 80), [(3, 80), (2, 85), (1, 99)],
     [("Now", 5, "3" + D), ("23:00", 6, "2" + D), ("00:00", 7, "1" + D)]),
    ("two, the end of a stale cache", "2026-11-22T12:30", "2026-11-22T10:00", (3, 4), [(5, 0), (6, 0), (7, 0), (8, 0)],
     [("Now", 2, "3" + D), ("13:00", 0, "8" + D)]),
    ("only this hour is known", "2026-11-22T12:30", "2026-11-22T12:00", (3, 4), [(9, 0)], [("Now", 2, "3" + D)]),
    ("every hour has passed", "2026-11-23T12:30", "2026-11-22T10:00", (3, 4), [(5, 0), (6, 0)], [("Now", 2, "3" + D)]),
    ("no hours", "2026-11-22T12:30", "2026-11-22T12:00", (3, 4), [], [("Now", 2, "3" + D)]),
    ("now -0.4, hours -0.5 -1.5 2.5", "2026-11-22T12:30", "2026-11-22T12:00", (-0.4, 1),
     [(0, 0), (-0.5, 0), (-1.5, 0), (2.5, 0)],
     [("Now", 1, "0" + D), ("13:00", 0, "-1" + D), ("14:00", 0, "-2" + D), ("15:00", 0, "3" + D)]),
    ("now -0.5", "2026-11-22T12:30", "2026-11-22T12:00", (-0.5, 0), [], [("Now", 0, "-1" + D)]),
    ("now -0.04 is never -0", "2026-11-22T12:30", "2026-11-22T12:00", (-0.04, 0), [], [("Now", 0, "0" + D)]),
    ("now -0.25: -0.3 is 0", "2026-11-22T12:30", "2026-11-22T12:00", (-0.25, 0), [], [("Now", 0, "0" + D)]),
    ("now -0.46 is -0.5 on the wire", "2026-11-22T12:30", "2026-11-22T12:00", (-0.46, 0), [], [("Now", 0, "-1" + D)]),
    ("now 2.46 is 2.5 on the wire", "2026-11-22T12:30", "2026-11-22T12:00", (2.46, 0), [], [("Now", 0, "3" + D)]),
    ("an hour's temperature is an i8", "2026-11-22T12:30", "2026-11-22T12:00", (-40, 0), [(0, 0), (-200, 0), (200, 0)],
     [("Now", 0, "-40" + D), ("13:00", 0, "-128" + D), ("14:00", 0, "127" + D)]),
    ("no current weather: nothing to write", "2026-11-22T12:30", "2026-11-22T12:00", None, [(1, 0), (2, 0)], None),
]
# model::Icon of Weather, by WMO code: both ends of every range and their neighbours
icons = {0: [0], 1: [1, 2], 3: [45, 48], 4: [51, 53, 57], 5: [61, 67, 80, 82], 6: [71, 77, 85, 86], 7: [95, 96, 99],
         2: [3, 4, 44, 46, 47, 49, 50, 58, 60, 68, 70, 78, 79, 83, 84, 87, 94, 100, 255]}

# an app with widget icons (docs/app-icons.md): stub 9 gets it whole, an older one without the trailer
image = bytes(range(256)) + bytes(44)
fields = {"name": "weather", "version": 7, "relocs": [4, 8], "abi_minor": 1}
plain = package.pack(image, **fields)
packed = package.pack(image, **fields, widget_icons=[bytes([i]) * package.WIDGET_ICON_BYTES for i in (0x11, 0x22)])
assert package.strip_trailer(packed) == plain
damaged = [{"note": "a pixel", "flip": len(packed) - 1}, {"note": "the magic", "flip": len(plain)},
           {"note": "its CRC", "flip": len(plain) + 8}, {"note": "cut short", "keep": len(packed) - 100},
           {"note": "a cut head", "keep": len(plain) + 5}]
for d in damaged:
    bad = bytearray(packed[:d.get("keep", len(packed))])
    if "flip" in d:
        bad[d["flip"]] ^= 0xFF
    assert package.strip_trailer(bytes(bad)) == plain
    try:
        package.parse(bytes(bad))
    except ValueError:
        continue
    raise SystemExit(f"the packer took a damaged trailer: {d['note']}")

blob_records = [
    {"records": ["c8000800", "7b2274223a32317d"], "blob": "04c8000800087b2274223a32317d"},
    {"records": ["aa" * 100, "bb" * 30], "blob": "64" + "aa" * 100, "note": "the second record doesn't fit: whole records only"},
    {"records": ["cc" * 128], "blob": None, "note": "a record of 128 bytes doesn't fit with its length byte"},
    {"records": [], "blob": None},
]
out = {
    "command": install.PUSH,
    "widget": [{"title": t, "value": v, "hex": install.widget_record(t, v).hex()} for t, v in widgets],
    "payload": [{"slot": 3, "kind": install.PUSH_WIDGET, "data": install.widget_record("USD", "92.41").hex(),
                 "hex": (bytes([3, install.PUSH_WIDGET]) + install.widget_record("USD", "92.41")).hex()},
                {"slot": 15, "kind": install.PUSH_BLOB, "data": "0102", "hex": "0f010102"},
                {"slot": 15, "kind": install.PUSH_WIDGET, "data": card.hex(),
                 "hex": (bytes([15, install.PUSH_WIDGET]) + card).hex()}],
    "columns_stub": install.STUB_V2,
    "columns": [{"note": note, "columns": named(c), "hex": install.columns_record(c).hex()} for note, c in columns],
    "columns_bad": [named(c) for c in bad_columns],
    "replies": [{"hex": "00", "ok": True}, {"hex": "0a60ea0000", "later_ms": 60000}, {"hex": "07", "refused": 7},
                {"hex": "01", "refused": 1}, {"hex": "02", "refused": 2}, {"hex": "", "refused": 255}],
    "weather_icons": sorted([code, index] for index, codes in icons.items() for code in codes),
    "weather_cards": [{"note": note, "at": at, "start": start, "now": now, "hours": hours,
                       "hex": install.columns_record(want).hex() if want else None}
                      for note, at, start, now, hours, want in cards],
    "trailer": {"stub": package.STUB_TRAILER, "package": packed.hex(), "plain": plain.hex(), "damaged": damaged},
    "blob": blob_records,
    "http_widget": [
        {"records": ["c8000e00", "5553440a39322e3431206576656e"], "title": "USD", "value": "92.41 even"},
        {"records": ["c8000500", "48656c6c6f"], "title": "Hello", "value": ""},
        {"records": ["f4010200", "6f6b"], "none": True, "note": "a 500 doesn't go to the widget"},
        {"records": ["c8000200", "c328"], "none": True, "note": "not UTF-8"},
    ],
}
print(json.dumps(out, indent=1, ensure_ascii=False))
