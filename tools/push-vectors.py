# push-vectors.json: PUSH (stub 8, cmf-watch-sdk docs/widget-push.md) as the phone sends it: for a watch app's
# background jobs, and Weather's columns card (stub 9). The records come from the SDK's own install.widget_record and
# install.columns_record (needs the SDK's venv: pycryptodome; -B leaves that checkout as it is).
#   export CMF_SDK=~/.herdr/worktrees/cmf-watch-sdk/widget-templates
#   $CMF_SDK/.venv/bin/python -B tools/push-vectors.py > ios/WireKit/Tests/WireKitTests/push-vectors.json
import json, os, sys

sys.path.insert(0, os.path.join(os.path.expanduser(os.environ.get("CMF_SDK", "~/Developer/pet/cmf-watch-sdk")), "src"))
from wp2apps import install  # noqa: E402

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
    "blob": blob_records,
    "http_widget": [
        {"records": ["c8000e00", "5553440a39322e3431206576656e"], "title": "USD", "value": "92.41 even"},
        {"records": ["c8000500", "48656c6c6f"], "title": "Hello", "value": ""},
        {"records": ["f4010200", "6f6b"], "none": True, "note": "a 500 doesn't go to the widget"},
        {"records": ["c8000200", "c328"], "none": True, "note": "not UTF-8"},
    ],
}
print(json.dumps(out, indent=1, ensure_ascii=False))
