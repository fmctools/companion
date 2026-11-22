# Watch apps on the phone

The Apps tab on iOS and Android lists the apps on the watch, plus the ones that asked for something but are gone from
the watch now. Each app's page has a switch for every service it asked for. An app whose store package has a higher
header version than the one on the watch goes under "Updates", with a link to its page on fmc.tools. The companion
reads the first 64 bytes of each store package for that: the listing's `version` text doesn't match the header for SDK
examples like Workout. The services themselves and their byte
layouts are in [miniapp-rpc.md](miniapp-rpc.md). This file covers how the phone side works and why it looks the way it
does.

## Where the code is

Android, under `android/app/src/main/java/tools/fmc/companion/`:

| File | What it does |
|---|---|
| `wire/Rpc.kt` | The RPC itself: parses a watch app's request, encodes the reply and the error codes. Pure Kotlin except `answer`, which checks the grant and runs the service |
| `RpcService.kt` | Foreground service that keeps the link and answers requests one at a time, in order |
| `Services.kt` | The services: calendar, location, weather, notifications, http |
| `Grants.kt` | What the user allowed per app, and the "app wants X" notification |
| `Apps.kt` | The Apps tab, an app's page, store names and icons |
| `wire/WeatherCard.kt` | Weather's widget card from the weather records, and when a session sends it |
| `wire/Session.kt`, `wire/Frame.kt` | Session, encryption and frames under the RPC |
| `BleLink.kt` | GATT client on the link Nothing X already holds. Not tested on a real watch yet (FMC-9) |

iOS has the same split: `ios/WireKit` for the wire format, `ios/App/RPCListener.swift`, `PhoneServices.swift`,
`Permissions.swift` and `Apps.swift`.

To build your own companion, take the transport (`Session`, `Frame`, `BleLink`) as it is. Then write your own `Rpc`
and services, and check them against `ios/WireKit/Tests/WireKitTests/rpc-vectors.json`. New methods go into
miniapp-rpc.md first.

## Order and slots

Edit on the Installed list (iOS EditButton and drag, Android Edit and up/down arrows) sets the order of the apps
on the watch. It is a list of package names kept on the phone per watch (iOS UserDefaults `app-order`, keyed by the
watch's BLE identifier; Android prefs `app`, `order|<watch id>`), and the list shows that order; apps it doesn't name
come after, by slot.

The order reaches the watch inside the loader package (cmf-watch-sdk `docs/app-order.md`): Done patches the store's
loader with the names in its `WP2ORDER` table (`setOrder` in WireKit and the Android wire, checked against
`order-vectors.json` from the SDK's own `package.set_order`, made by `tools/order-vectors.py`), re-signs it and
installs it to slot `0xFF`, about 54 KB. `Busy` (the Apps menu or an app on screen) leaves it unsent; it goes on the
next read of the watch. Update App Loader installs the patched loader too, and the Firmware page compares the watch's
loader CRC with that, so an ordered loader doesn't read as outdated. A store loader without the table (older than the
feature) can't carry the order: it stays on the phone.

The stub has 8 app slots before version 8 and 16 from it (`appSlots(stub:)` in WireKit, `appSlots` in the Android
wire). The version is INFO on slot `0xFE`; `readLoader`, `installed` and `install` read that many.

## Widget icons in packages

An app may carry the icons of its widget card in a `WP2W` trailer after the relocation table (cmf-watch-sdk
`docs/app-icons.md`, "Widget icons"). `body_crc` and the header don't count it, so the 64-byte header the Apps tab
reads says the same with and without icons. `install` (WireKit, the Android wire) reads the stub first:

- stub 9 or later gets the file as it is. The stub checks the trailer's own CRC; with a damaged one the app installs
  without icons, so the phone doesn't check it too.
- an older stub refuses any byte past the header's sizes, so it gets the file cut there: byte for byte the package
  packed without icons, damaged trailer or not.

A trailer adds up to 77 KB (16 icons of 4800 B).

## Weather's card

The companion keeps the widget card of the store's Weather app (package `weather`) fresh: now and the next three hours,
as a `columns` record pushed to stub 9 or later. The record, the icon order and the gate are in
[miniapp-rpc.md](miniapp-rpc.md), "Weather's card". On each platform:

- It runs in the services' loop and only there: iOS `RPCListener` (in the foreground and in the wakes it gets anyway),
  Android `RpcService` (so only with the services switched on). On connect, then when the hour changes: iOS sees that
  within 5 s while it runs, Android within a minute.
- It uses the forecast cached for the `weather` service. An expired one is fetched for the phone's last known location:
  the card never asks for a fix and never prompts. A forecast fetched for an old location that way isn't reused for
  the app's own `weather` request, which takes a fix as before.
- It stays out of installs, face and firmware sessions and the wait for a flashed watch to restart.
- The slot and the stub come from one read per session. Reading again before each push would drop an install another
  host has open (INFO does that; PUSH doesn't). So an app another host put into Weather's slot meanwhile would get
  the card until the next reconnect; the companion's own installs restart the session.

## What the phone keeps for watch apps

- Grants, pending asks and "Show text on the watch": `Permissions` (UserDefaults) / `Grants` (prefs "grants").
- Headers per (package, host): Keychain / SecureStore. Cookies: in memory. Both go with Reset permissions.
- `storage` (0x60–0x62): one file per key, iOS `Application Support/storage` excluded from backup, Android
  `noBackupFilesDir/storage`; `KeyValueStore` in WireKit and the wire. Delete from the Watch clears it, Reset
  permissions doesn't (it is the app's data, not an answer of the user's).
- Background jobs (0x90): `Jobs` (UserDefaults "rpc-jobs" / prefs "jobs"), run by `RPCListener` / `RpcService` while
  the link is up, delivered with the stub's `PUSH` (stub 8+, cmf-watch-sdk `docs/widget-push.md`) into the app's
  widget card or start blob. Reset permissions and Delete from the Watch clear them.

What one platform can't do answers `UNAVAILABLE` there and stays out of `caps`: notifications, media on iOS,
reminders on Android. Details per method in [miniapp-rpc.md](miniapp-rpc.md).

## One link, several sessions

There's one BLE link, the one Nothing X holds, but more than one client can use it. Android shares the LE link between
apps' GATT clients, so we connect next to Nothing X without a bind or a popup. We already run two sessions on it
ourselves: `RPCListener` and the watch check in `WatchModel.check`.

The catch is that replies don't carry a request id. Every session sees every reply, so requests have to go one at a
time. `KLock` on iOS and `kLock` (`Watch.kt`) on Android do that between our own sessions. Another host sending its
own requests at the same moment can still take our reply, and nothing guards against that.

The watch is read again by itself in two cases. When the listener's link comes back after a drop (a restart, out of
range), `WatchModel.linkCameBack` / `AppModel.linkCameBack` runs `check()`: not before the user's first read, not
within 30 s of the last one, not while a restart is awaited (`recheckDue` in WireKit and the wire). Installs, flashes
and K jobs stop the listener, so they never meet that read. After a firmware is sent, `awaitRestart` /
`afterFlash` reads the watch every 20 s for up to 10 min (`retry`) until it answers with the new stub; the Watch tab
and Firmware page say "The watch is installing the update…" meanwhile. App installs and deletes, the order and
App Loader updates call `check()` themselves.

Installing a watch face is the exception. The stock session binds the watch, so `RPCListener` stops for the install
and the user has to close Nothing X first.

## iOS in the background

With `bluetooth-central`, iOS wakes the app on each BLE notify from the watch and gives it about 10 seconds. That's why
every method answers within 8 s. `beginBackgroundTask` keeps the reply going until it's sent, but there's no extra time
to count on.

- Swiped away by the user: the app doesn't run at all until it's opened again.
- Killed by the system: CoreBluetooth state restoration could bring it back. We don't use it yet, so the listener is
  gone until the next launch.
- After a reboot and before the first unlock, keychain items with the default protection can't be read, so there's no K.
- Nobody knows yet whether a notify on the link Nothing X holds wakes our app at all. The DEBUG Wake probe
  (`ios/App/WakeProbe.swift`) checks it, and it hasn't been run on hardware. If it doesn't wake, services on iOS only
  work while the app is open.

## Why not web modules

The idea came up to do it like KernelSU: each module is config plus a web UI, and the app is a JS bridge to a web
renderer. It doesn't fit here.

The phone side runs in the background almost all the time. A web UI needs its screen open, so when a watch app asks for
the weather with the phone in a pocket, nothing is there to answer. That's the hard part, and a web layer just sits
next to it.

Then there's the App Store. Downloading third-party JS that changes what the app does runs into guideline 2.5.2.
KernelSU never goes through review. We do.

Permissions are the third problem. Each watch app gets its own grant for calendar, location or notifications, and
native code checks the OS permission before any service runs. A JS bridge would have to expose all of that again and
keep modules from getting around it. A fixed list of methods is much easier to get right.

So the phone side stays a small set of native services. A new capability is a new method in miniapp-rpc.md, not code
loaded at runtime. Anyone who needs something much bigger can build their own companion on the same wire protocol.
