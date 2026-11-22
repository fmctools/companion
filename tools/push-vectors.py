# push-vectors.json: PUSH (stub 8, cmf-watch-sdk docs/widget-push.md) as the phone sends it for a watch app's
# background jobs. The widget record comes from the SDK's own install.widget_record (needs the SDK's venv: pycryptodome).
#   CMF_SDK=~/.herdr/worktrees/cmf-watch-sdk/app-order $CMF_SDK/.venv/bin/python tools/push-vectors.py > ios/WireKit/Tests/WireKitTests/push-vectors.json
import json, os, sys

sys.path.insert(0, os.path.join(os.path.expanduser(os.environ.get("CMF_SDK", "~/Developer/pet/cmf-watch-sdk")), "src"))
from wp2apps import install  # noqa: E402

widgets = [("USD", "92.41"), ("Погода в Москве сегодня", "−3° снег, ветер 5 м/с\nзавтра −7°"), ("", ""),
           ("A title of exactly 23 b", "a value that is longer than thirty-nine bytes for sure"),
           # cut between code points, not graphemes: the accent and the LF go, what they follow stays
           ("1234567890123456789012e\u0301", "x" * 38 + "\r\n")]
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
                {"slot": 15, "kind": install.PUSH_BLOB, "data": "0102", "hex": "0f010102"}],
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
