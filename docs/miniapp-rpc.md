# Miniapp services: RPC (draft)

A miniapp on the watch asks the phone for data the watch cannot reach: the phone's calendar, location, weather,
notifications, a web request. The phone answers from a fixed set of services written natively in both apps. No code
from the site runs on the phone. The first time an app calls a service, the phone asks the user; the answer is kept
per app.

Status: draft, being implemented. Byte layouts are fixed by `ios/WireKit/Tests/WireKitTests/rpc-vectors.json`, which
both apps test against (as `vectors.json`). A change to a vector is a change for both apps and the watch apps.

## Constraints this design follows

From cmf-watch-sdk (`docs/app-guide.md` §4, `docs/abi-1.4.md`):

- App messages are 1–128 bytes each way; the watch app has an inbox and an outbox of 4 messages each.
- Host → app goes to the running app only (`MSG`, slot `0xFF`); `NO_APP` otherwise. So the watch pulls: a closed
  miniapp gets nothing pushed.
- App → host arrives as `EVENT`, plain `seq ‖ slot ‖ data` (loader of 2026-11-13+). `slot` tells the phone which app
  asked.
- `text` draws at most 64 bytes; glyphs cover ASCII and Cyrillic only.
- The app has local wall-clock time (`time()`), so times go over the wire as local day + minute, no epoch or zones.
- **Anyone in BLE range can read K and with it every app message.** The SDK says not to send personal data. See
  "Personal data".
- iOS: the companion runs in the background only while woken by BLE (`bluetooth-central`), about 10 s per wake.
  Every method answers within 8 s. Whether a notify on the link Nothing X holds wakes the app at all is checked by the
  DEBUG Wake probe (`ios/App/WakeProbe.swift`) and not yet verified on hardware.

## Who is asking

The phone keeps the `slot` of each `EVENT` and maps it to the package name in that slot's `WP2A` header (`INFO`,
as `readLoader` reads it; cached, read again for a slot it has not seen or after an install). Grants are keyed by the
package name.

ponytail: a package that takes another's name gets its grants. Fine while the owner installs every package; a
signature in the package header when the store installs apps for others.

## Permissions

Capabilities:

| Cap | Methods | OS permission |
|---|---|---|
| (none) | `caps`, `storage.*`, `phone.battery`, `job.*` (a job needs the cap of its request) | — |
| `calendar` | `calendar.events` | EventKit full access (iOS 17+ `requestFullAccessToEvents`); `READ_CALENDAR` |
| `reminders` | `reminders`, `reminders.complete` | iOS: EventKit full access to reminders (`requestFullAccessToReminders`). Android: none, the methods answer `UNAVAILABLE` |
| `location` | `location` | When In Use, reduced accuracy is enough; `ACCESS_COARSE_LOCATION` |
| `weather` | `weather` | the same as `location` (the phone needs it; the watch gets no position) |
| `http:<host>` | `http.get` and `http.request` to that host | — |
| `notifications` | `notifications` | Android: notification listener access. iOS: none possible, the method answers `UNAVAILABLE` |
| `media` | `media.now_playing`, `media.control` | Android: notification listener access (the same switch as `notifications`). iOS: none possible, the methods answer `UNAVAILABLE` |
| `notify` | `notify` | iOS: notification authorization (a turned-off one drops it silently); Android: `POST_NOTIFICATIONS` |

Flow:

1. A method whose cap this package has no answer for yet: reply `ASK`. The phone keeps a pending request
   (package, cap) and posts a local notification "‹package› wants ‹cap›" ("‹package› wants to read and change data
   on ‹host›" for `http.request`), at most once a day per pair.
2. The companion's Permissions screen (opened from that notification or from Settings) lists pending requests and
   every package's grants. Allow asks for the OS permission the cap needs, if it is not given yet; Deny is kept too.
3. Later calls: granted and OS permission on → the method runs; denied, or the OS permission is off → `DENIED`, and no
   new notification.
4. Each grant can be revoked on the same screen. Per package there is also one switch, "Show text on the watch"
   (off by default): calendar titles and notification text. See "Personal data".

A manifest on fmc.tools that declares caps ahead (a consent screen at install) can come later, when the site has a
collection for apps; it would only pre-fill these grants.

## Messages

All integers little-endian. Every RPC message opens with `R1`, so a miniapp keeps its own messages (any other prefix)
on the same channel. Only `R1Q` is a request; any other `R1x` is dropped. An `R1Q` the phone cannot read (no method
byte, unknown method, bad args) gets `BAD_REQUEST` if it has an id byte, else it is dropped.

Request (watch → phone):

```
"R1" ‖ 'Q' ‖ id:u8 ‖ method:u8 ‖ args
```

Reply (phone → watch):

```
"R1" ‖ 'A' ‖ id:u8 ‖ status:u8 ‖ index:u8 ‖ total:u8 ‖ record
```

- `id` is the app's counter; the phone echoes it. The app ignores replies whose `id` is not its latest.
- A result of `total` records goes as `total` messages, `index` 0…total−1, one record each (≤ 121 bytes), sent with
  `KSession.send` (it retries `FULL`/`PAUSED`), so the app drains `recv` in its loop.
- Empty result or any error: one message, `index` 0, `total` 0, no record.
- The phone handles one request at a time, in order of arrival, and keeps no state per request, except the parts of
  a multi-part request (`http.request`, `storage.put`, `job.set`) not joined yet: one per package, whatever its method.

### Multi-part requests

A request whose args don't fit one message comes as one or more `R1Q` with the same `id` and method, args
`index:u8 ‖ total:u8 ‖ chunk` (`chunk` ≤ 121 bytes, `total` 1–9, `index` 0…total−1 in order). The phone joins the
chunks per package and answers only after the last part; parts before it get no reply. `BAD_REQUEST`, and the
joined bytes so far are dropped, for: a part out of order (the first one not `index` 0, a gap, a repeat, a `total`
that changes), a part with a new `id` or another multi-part method before the last part of the open one (the new
part is refused; the app sends its request again from `index` 0), `total` 0 or over 9. Single-message methods in
between don't touch the open request. The joined payload is at most 9 × 121 = 1089 bytes.
- No answer at all (phone asleep, out of range, companion not running): the app shows its cached copy (`store`,
  4 KiB) and asks again after 3 s, then less often.

| `status` | |
|---|---|
| 0 `OK` | |
| 1 `BAD_REQUEST` | unknown method, bad args |
| 2 `DENIED` | the user denied the cap, or its OS permission is off |
| 3 `UNAVAILABLE` | the phone cannot answer now: no location fix, network down or timeout, iOS notifications |
| 4 `ASK` | the user has not answered yet; the phone asked. Show "Allow on your phone" |
| 5 `TOO_LARGE` | `http.get` / `http.request` body over 2048 bytes; `storage.put` over the package's quota |

Text fields are UTF-8, cut by the phone to at most the stated size, at a character boundary (`utf8_cut` vectors:
64 Cyrillic-only bytes stay 64).
Characters the watch has no glyph for stay as they are (they draw as `?`).

## Methods

| Id | Method | Cap |
|---|---|---|
| `0x01` | `caps` | — |
| `0x10` | `calendar.events` | `calendar` |
| `0x11` | `reminders` | `reminders` |
| `0x12` | `reminders.complete` | `reminders` |
| `0x20` | `location` | `location` |
| `0x30` | `weather` | `weather` |
| `0x40` | `http.get` | `http:<host>` |
| `0x41` | `http.request` | `http:<host>` |
| `0x50` | `notifications` | `notifications` |
| `0x51` | `notify` | `notify` |
| `0x60` | `storage.get` | — |
| `0x61` | `storage.put` | — |
| `0x62` | `storage.delete` | — |
| `0x70` | `phone.battery` | — |
| `0x80` | `media.now_playing` | `media` |
| `0x81` | `media.control` | `media` |
| `0x90` | `job.set` | the cap of its request |
| `0x91` | `job.delete` | — |

### `0x01 caps`

Args: none. One record: the method ids this package may call now (granted and OS permission on), one byte each,
without `0x01` itself; `0x40` and `0x41` when any host is granted; the methods without a cap of their own (`0x60`–`0x62`, `0x70`, `0x90`, `0x91`) always,
after the others.
A miniapp calls it at start to tell "allow on your phone" from an empty result.

### `0x10 calendar.events`

Args: `from_day:i8 ‖ days:u8 ‖ limit:u8`. `from_day` 0 = today (phone's local date), `days` 1–7, `limit` 1–20;
out-of-range values are clamped. Events from the calendars visible in the system calendar app, sorted by start,
all-day events first within a day.

Record (`calendar`, `calendar_dates` vectors):

```
day:i8 ‖ start:u16 ‖ duration:u16 ‖ flags:u8 ‖ color:u16 ‖ title
```

| Field | |
|---|---|
| `day` | days from today, phone's local date |
| `start` | minute of the day, local; 0 for all-day |
| `duration` | real minutes from start to end (60 for 01:30–03:30 on a spring-forward day); all-day: 1440 × days |
| `flags` | bit 0 all-day, bit 1 tentative, bit 2 text hidden |
| `color` | calendar colour, RGB565 |
| `title` | ≤ 64 bytes; empty with bit 2 |

### `0x11 reminders`, `0x12 reminders.complete`

iOS only. Android has no system reminders API another app can read (each app keeps its own), so both answer
`UNAVAILABLE` there and `caps` never lists them.

`reminders`: args `limit:u8`, 1–20 (clamped). The incomplete reminders of every list, due ones first by day, in a
day the ones without a time first, then by minute; then the ones without a due date by list name, then title
(`reminders.order` vectors). Records (`reminders.records` vectors):

```
id:u32 ‖ day:i8 ‖ minute:u16 ‖ flags:u8 ‖ color:u16 ‖ title
```

| Field | |
|---|---|
| `id` | FNV-1a 32 of EventKit's `calendarItemIdentifier` (UTF-8): short, stable while the reminder lives (`reminders.ids`) |
| `day` | due date in days from today, negative when overdue; 0 without one |
| `minute` | due time, minute of the day, local; 0 without one |
| `flags` | bit 0 has a due date, bit 1 has a due time, bit 2 text hidden |
| `color` | the list's colour, RGB565 |
| `title` | ≤ 64 bytes; empty with bit 2 ("Show text on the watch", as calendar titles) |

`reminders.complete`: args `id:u32`. Marks that reminder complete; `OK`, no records. No incomplete reminder with
that id (done meanwhile, deleted): `BAD_REQUEST`.

### `0x20 location`

Args: none. One record (`location` vectors):

```
lat:i16 ‖ lon:i16 ‖ age:u16 ‖ place
```

`lat`, `lon` in 0.1° (about 10 km), rounded. `age` minutes since the fix, `0xFFFF` for older. `place` the locality
("Москва"), ≤ 32 bytes, may be empty. The phone uses its last known location and refreshes it while the companion
is in the foreground or when asked and allowed; no fix at all: `UNAVAILABLE`.

### `0x30 weather`

Args: `days:u8 [‖ hours:u8]`. `days` 0–7: daily records for days 0…days−1. `hours` 0–24, absent is 0: the hourly
record with that many hours from now. `hours` over 24 or a third byte: `BAD_REQUEST` (`weather_args` vectors).
Records, in this order (`weather` vectors):

```
current: 0:u8 ‖ temp:i16 ‖ code:u8 ‖ wind:u8 ‖ humidity:u8 ‖ age:u8
hourly:  2:u8 ‖ hour:u8 ‖ n × (temp:i8 ‖ code:u8 ‖ precip:u8)
daily:   1:u8 ‖ day:i8 ‖ min:i8 ‖ max:i8 ‖ code:u8 ‖ precip:u8
```

`temp` in 0.1 °C, `min`/`max` in °C, `wind` m/s, `humidity` and `precip` (probability) in %, `age` minutes since the
data was fetched (capped at 255), `day` 0 = today. `code` is a WMO weather code as Open-Meteo gives it (0 clear;
1–3 clouds; 45, 48 fog; 51–57 drizzle; 61–67 rain; 71–77 snow; 80–82 showers; 85, 86 snow showers; 95–99
thunderstorm). Source: WeatherKit on iOS (conditions mapped to these codes), Open-Meteo on Android. The phone caches
for 30 min and fetches with a 6 s timeout; nothing cached and no network: `UNAVAILABLE`.

The hourly record: one record for all hours, only when `hours` > 0 and the source has hours. `hour` is the local
hour (0–23) of the first entry: the hour that contains now, or a later one when the forecast only starts after it (then
no entry is now's). The entries are consecutive hours, `n` =
min(`hours`, what the source has), read from the record's length. An entry's `temp` is in °C; its `precip` has the
probability in bits 0–6 and bit 7 set when that hour is night. There are no sunrise or sunset times: they would
give the position away, and the watch gets none from `weather`.

On Android hours and days are on the phone's clock also when the forecast's place has another timezone: Open-Meteo is
asked in the phone's zone, so a day's range covers the phone's day, and the place's zone isn't sent to the watch.
On iOS WeatherKit's days start at midnight at the place; a day's `day` is the phone's date of its noon, which holds
while the place is within 12 hours of the phone's zone.

A companion from before `hours` (2026-11-20): Android answers `BAD_REQUEST` to two bytes of args, iOS reads `days`
and answers without the hourly record. An app asks again with `days` alone, or shows no hours.

### `0x40 http.get`

Args: the URL, UTF-8, `https://` only, ≤ 123 bytes. Cap `http:<host>` for the URL's host. GET with
`User-Agent: FMC-Companion`, the headers and cookies of (package, host) (see "Headers and cookies" under
`http.request`), 6 s timeout, redirects only within the same host. Records (`http` vectors):

```
first: code:u16 ‖ length:u16
then:  the body in chunks of 121 bytes
```

Any HTTP code is `OK` with that code; a body over 2048 bytes is `TOO_LARGE`; no answer in time or no network:
`UNAVAILABLE`. The app's own server should answer compactly: the watch has 4 KiB of storage.

### `0x41 http.request`

Any method, with a body, for an app that changes data on its server. A multi-part request (see "Multi-part
requests"); the joined payload (`http_request` vectors):

```
method:u8 ‖ url_len:u8 ‖ url ‖ body
```

`method` 0 GET, 1 POST, 2 PUT, 3 PATCH, 4 DELETE. `url` UTF-8, `https://` only. `body` is the rest, up to
9 × 121 − 2 − url_len bytes; GET takes none. Anything else (method 5+, `url_len` past the end, not https, GET with
a body) is `BAD_REQUEST`. Cap: the same `http:<host>` as `http.get`; the ask says the app wants to read and change
data on that host.

The reply is `http.get`'s: `code:u16 ‖ length:u16`, then the body in 121-byte chunks; a body over 2048 bytes is
`TOO_LARGE`; no answer in 6 s or no network: `UNAVAILABLE`. Redirects only within the same host; 301–303 turn into a
GET without the body, as browsers do.

#### Headers and cookies

Kept on the phone per (package, host) and put on `http.get` and `http.request` to that host. They never go to the
watch, and the phone never logs them.

- **Headers.** The user types name/value pairs (`Authorization: Bearer …`) on the app's page, under its
  `http:<host>` row, "Headers". iOS keeps them in the Keychain, Android in SecureStore (AES-GCM under a Keystore
  key). `User-Agent: FMC-Companion` unless the user sets their own. `Content-Type: application/json` when the body
  starts with `{` or `[` and the user set no `Content-Type`.
- **Cookies.** A jar per (package, host): what the host sets comes back on the next request. In memory, so a login
  by cookie lasts while the companion runs. On iOS, cookies set on a redirect's own response are not kept.
- Reset permissions and Delete from the Watch clear both.

### `0x60 storage.get`, `0x61 storage.put`, `0x62 storage.delete`

A key/value store per package on the phone, so an app isn't limited to the watch's 4 KiB. No cap: an app reads and
writes only its own keys. A key is 1–16 bytes of `A–Z a–z 0–9 . _ -`; any other key is `BAD_REQUEST` (`storage.keys`
vectors).

- `storage.get`: args the key. The value as `length:u16`, then the value in chunks of 121 bytes (`storage.get`
  vectors); a key with no value: `OK` with no records.
- `storage.put`: a multi-part request; joined payload `key_len:u8 ‖ key ‖ value`, so a value of up to
  1088 − key_len bytes (`storage.put` vectors). `OK`, no records. Replaces the old value.
- `storage.delete`: args the key. `OK`, no records, also for a key with no value.

Quota: 64 KiB per package, keys and values counted together; a put that would go over it is `TOO_LARGE` and keeps
the old value. Kept in the app's own files, out of backups (iOS Application Support excluded from backup, Android
`noBackupFilesDir`), one file per key. Delete from the Watch clears the package's store; Reset permissions doesn't.

### `0x51 notify`

The app posts a notification on the phone. Args (`notify` vectors):

```
flags:u8 ‖ title_len:u8 ‖ title ‖ body
```

`flags` bit 0 with sound, bit 1 "find my phone". `title` ≤ 64 bytes, `body` the rest of the message (so title and
body ≤ 121 bytes together), both UTF-8; anything else is `BAD_REQUEST`. An empty title shows the app's name. `OK`, no
records. At most one per 10 s per package; another one sooner is `UNAVAILABLE` (the app tries later).

"Find my phone" is as loud as each phone lets an app be:

- Android: a channel of its own on the alarm stream, high importance, repeating its sound until the user opens the
  shade (`FLAG_INSISTENT`). Do Not Disturb still silences it unless the user lets the channel through.
- iOS: a notification with the default sound, nothing more. Critical alerts need an entitlement Apple grants to
  medical and safety apps, and a backgrounded app can't play its own audio.

Tapping one opens the app's page in the companion.

### `0x80 media.now_playing`, `0x81 media.control`

Android only: the active media session, through `MediaSessionManager.getActiveSessions` with the companion's
notification listener. iOS answers `UNAVAILABLE` to both and `caps` never lists them: an app can't read or drive
another app's player there (MPNowPlayingInfoCenter is the app's own; MPMusicPlayerController only the Music app's
queue).

`media.now_playing`: args none. The session that plays, else the first active one; none: `OK` with no records. One
record (`media` vectors):

```
flags:u8 ‖ position:u16 ‖ duration:u16 ‖ app_len:u8 ‖ app ‖ title_len:u8 ‖ title ‖ artist
```

`flags` bit 0 playing. `position` and `duration` in seconds, `0xFFFF` unknown (a live stream). `app` the player's
label ≤ 24 bytes, `title` ≤ 48, `artist` ≤ 32. Track names are not behind "Show text on the watch".

`media.control`: args `action:u8`: 0 play, 1 pause, 2 play/pause, 3 next, 4 previous; other values `BAD_REQUEST`.
`OK`, no records; no session: `UNAVAILABLE`.

### `0x90 job.set`, `0x91 job.delete`

Background refresh for a widget or page: the app registers a job, and the phone runs its request every N minutes
while the app isn't running, then writes the result to the watch for it with the stub's `PUSH` (cmf-watch-sdk
`docs/widget-push.md`, stub 8 and later): into the app's widget card, or into the blob the app gets as its first
message when it starts. On a stub before 8 the phone runs the job and drops the result (DevLog says so).

`job.set`: a multi-part request; joined payload (`jobs` vectors):

```
job:u8 ‖ minutes:u16 ‖ kind:u8 ‖ target:u8 ‖ spec
```

| Field | |
|---|---|
| `job` | 0–3: up to four jobs per package; a job with the same number replaces the old one |
| `minutes` | how often; under 15 counts as 15, over 1440 as 1440 |
| `kind` | 0 a web request: `spec` is `http.request`'s joined payload (`method ‖ url_len ‖ url ‖ body`); 1 the weather: `spec` is `weather`'s args (`days`, or `days ‖ hours`); 2 the calendar: `spec` is `calendar.events`' args |
| `target` | 0 the widget card (web requests only), 1 the start blob |

What goes to the watch (`push-vectors.json`, made by `tools/push-vectors.py` with the SDK's own `widget_record`):

- blob: the job's records, each as `len:u8 ‖ record`, whole records while they fit the blob's 128 bytes (a web
  job: `code ‖ length` first, then as much of the body as fits); none fits: nothing is pushed. The app reads it
  with `recv` at start, `slot` its own.
- widget: a web job whose answer is 2xx, its body UTF-8: the first line is the card's title (≤ 23 bytes), the rest
  its value (≤ 39 bytes, a second `\n` starts the value's second line). Anything else: nothing is pushed.

One widget and one blob per app: several jobs with the same target replace each other's result. The stub takes one
write per slot and target per 60 s; a `Later` makes the job due again after the wait it names. Same bytes as stored
cost nothing.

Anything else is `BAD_REQUEST`. The job needs the cap its request would (`http:<host>`, `weather`, `calendar`): no
answer yet is `ASK`, denied is `DENIED`, as for the request itself. `OK`, no records. A job's records are exactly
what its request answers (an http job: `code ‖ length`, then the body), with the user's headers and cookies for that
host and "Show text on the watch" as set. A job whose cap is off later doesn't run.

`job.delete`: args `job:u8`. `OK`, no records, also for a number with no job.

The app's page lists its jobs ("Every 30 min: GET api.example.com/rate") with a switch each. Reset permissions and
Delete from the Watch delete them.

`PUSH` itself, from the phone (`Push.swift` / `wire/Push.kt`): `slot ‖ kind ‖ data`, reply `00` ok, `0A ‖ wait:u32`
later, `07` no app in that slot, `01` bad request or a stub before 8, `02` NAND write failed. `kind` 0 takes a v1
record of exactly 64 bytes and, from stub 10, a v2 record of up to 128 (short ones too); an older stub answers `01` to
v2, so the phone reads the stub's version first.

When they run: on Android in the foreground service's loop (`RpcService`, at least once a minute); on iOS in
`RPCListener`'s loop, while the app is in the foreground or woken by BLE (about 10 s). iOS has no BGAppRefreshTask
for them: it wakes the app without the watch's link, and delivering needs that link. A job is due `minutes` after
its last run (success or not); a new or replaced job runs on the next check.

#### Weather's card

The one card the phone writes by itself, with no job: the store's Weather (package `weather`) shows now and the next
three hours (`WeatherCard.swift` / `wire/WeatherCard.kt`; `weather_cards`, `weather_icons` and `columns` in
`push-vectors.json`, their bytes from the SDK's `install.columns_record`). The watch app writes the same card: the
same forecast at the same hour gives the same bytes on both, and the last write wins.

Only when all hold: stub 10 or later, `weather` in one of slots 0–15, that package has the `weather` grant and its OS
permission is on. Else nothing is written, never a v1 text card in its place: it would replace the app's own.

```
FF ‖ 01 ‖ n:u8 ‖ n × (caption[10] ‖ icon:u8 ‖ value[10])        n 1–4; 24, 45, 66 or 87 bytes
```

Both text fields are UTF-8, at most 9 bytes cut at a code point, NUL-padded. The columns are built from the records
`weather` answers (`0x30`):

| Column | Caption | Value and icon from |
|---|---|---|
| first | `Now` | the current record: `temp` (0.1°) rounded to a whole degree, halves away from zero, never `-0`; its `code` |
| up to three more | `HH:00`, 24 h, zero-padded, wraps at midnight | the hourly entries after the one of the hour that contains now: `temp`, `code` |

The value is the integer and `°` (`C2 B0`), no unit; the stub draws its own glyph for it. Hours count on the phone's
clock: a stale forecast drops the hours that passed, and fewer known hours give fewer columns. No current record:
nothing is written.

`icon` is an index into Weather's package icons (the `WP2W` trailer, ten of them): 0–7 in the order of Weather's
`model::Icon`, then the two night drawings. It is a contract with that package, so it only grows at the end.

Night is bit 7 of an hourly entry's `precip` and nothing else: no other "is daylight" source on either side, or their
bytes would differ. An hourly column takes its own entry's bit. `Now` takes that of the entry that contains now, as
Weather's Now page does; with no such entry (no hours, all passed, the forecast starts later) it is day. Only the
codes of 0 and 1 change at night, to 8 and 9; the other six conditions have one drawing.

| Index | Icon | WMO codes |
|---|---|---|
| 0 | clear | 0 |
| 1 | partly | 1, 2 |
| 2 | cloud | anything not listed here |
| 3 | fog | 45, 48 |
| 4 | drizzle | 51–57 |
| 5 | rain | 61–67, 80–82 |
| 6 | snow | 71–77, 85, 86 |
| 7 | storm | 95–99 |
| 8 | clear at night (moon) | 0, night |
| 9 | partly at night (moon and cloud) | 1, 2, night |

When: once the link is up, then when the hour changes. The same bytes aren't sent twice in a session (a new session
sends once; the stub doesn't write what it already has). After a write the next waits 60 s, after a `Later` the time it
names; with no forecast or a refused push it is tried again in 5 min.

### `0x70 phone.battery`

Args: none. No cap. One record (`battery` vectors):

```
level:u8 ‖ flags:u8
```

`level` 0–100 %, `flags` bit 0 plugged in (charging or full). The phone doesn't know its level (the iOS simulator):
`UNAVAILABLE`.

### `0x50 notifications`

Android only; iOS answers `UNAVAILABLE`. Args: `limit:u8`, 1–10. Records, newest first (`notifications` vectors):

```
age:u16 ‖ flags:u8 ‖ app_len:u8 ‖ app ‖ text
```

The notifications shown now, without ongoing ones (music, navigation) and the companion's own. `age` minutes since
posted, `flags` bit 2 text hidden, `app` the app's label ≤ 24 bytes, `text` "title: text" ≤ 64 bytes, empty with
bit 2.

## Personal data

Calendar titles, notification text and location are what the SDK says never to send: K is readable by any BLE
client, so anyone in range can read them off the air.

- Titles and notification text: off by default (bit 2, empty text); the per-package "Show text on the watch" switch
  turns them on, with a line saying others nearby could read them.
- Location: only 0.1° and the locality, and only after the user allowed `location` for that package, with the same
  line on the permission screen.
- Never sent: event locations, attendees, notes; notification senders' details beyond the text; precise coordinates.

A real fix needs a key the watch and phone share that does not leave over the air; out of scope here.
