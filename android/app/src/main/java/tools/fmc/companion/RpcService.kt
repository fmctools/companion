package tools.fmc.companion

import android.Manifest
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.withLock
import tools.fmc.companion.wire.Cmd
import tools.fmc.companion.wire.KSession
import tools.fmc.companion.wire.Status
import tools.fmc.companion.wire.WireError
import kotlinx.coroutines.withTimeoutOrNull
import tools.fmc.companion.wire.LOADER_SLOT
import tools.fmc.companion.wire.PushResult
import tools.fmc.companion.wire.RefreshJob
import tools.fmc.companion.wire.appSlots
import tools.fmc.companion.wire.canPush
import tools.fmc.companion.wire.installed
import tools.fmc.companion.wire.push
import tools.fmc.companion.wire.stubVersion
import tools.fmc.companion.wire.RpcError
import tools.fmc.companion.wire.RpcStatus
import tools.fmc.companion.wire.answer
import tools.fmc.companion.wire.runJob
import tools.fmc.companion.wire.bytes
import tools.fmc.companion.wire.parseHeader
import tools.fmc.companion.wire.parseRequest
import tools.fmc.companion.wire.u8

// Holds the link and answers the miniapps' requests (docs/miniapp-rpc.md) while it runs: a foreground service of
// type connectedDevice, plus location once that is allowed (Android gives an FGS location only by its type).
// One request at a time, in order. A dropped link or a dead session: a new one 30 s later.

class RpcService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var job: Job? = null

    override fun onBind(intent: Intent?) = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        channel(this, "service", getString(R.string.channel_service), NotificationManager.IMPORTANCE_LOW)
        val n = NotificationCompat.Builder(this, "service")
            .setSmallIcon(R.drawable.ic_watch)
            .setContentTitle(getString(R.string.service_title))
            .setContentText(getString(R.string.service_text))
            .setContentIntent(appsIntent(this))
            .setOngoing(true)
            .build()
        val location = if (granted(this, Manifest.permission.ACCESS_COARSE_LOCATION)) ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION else 0
        try {
            startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE or location)
        } catch (e: Exception) {
            // no Bluetooth permission, or started from the background where Android forbids it
            Log.w(TAG, "can't run in the foreground", e)
            stopSelf()
            return START_NOT_STICKY
        }
        if (job == null) job = scope.launch { run() }
        return START_STICKY
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    private suspend fun run() {
        val store = SecureStore(this)
        val phone = PhoneServices(this, Grants(this))
        while (scope.isActive) {
            val link = BleLink(this)
            try {
                link.connect()
                val account = "k-${link.watchId}"
                val session = kLock.withLock {
                    try {
                        KSession.open(link, store[account] ?: throw WireError.Timeout("no cached K")).first
                    } catch (e: WireError) {
                        // K changes with a factory reset: read it again
                        KSession.open(link).also { store[account] = it.second }.first
                    }
                }
                Log.i(TAG, "listening")
                DevLog.log(this, "listening")
                // the watch is back (a restart, a reconnect): the Watch tab and Firmware page read it again
                WatchLink.back.tryEmit(Unit)
                listen(session, phone)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "link: ${e.message}")
                DevLog.log(this, "link: ${e.message}")
            } finally {
                link.disconnect()
            }
            delay(30_000)
        }
    }

    private suspend fun listen(s: KSession, phone: PhoneServices) {
        // slot → package. ponytail: read once per session (INFO drops an install in progress, so not per request);
        // an app installed into a used slot while this runs keeps the old name until the next reconnect.
        val names = mutableMapOf<Int, String>()
        val push = PushTarget()
        while (true) {
            runDueJobs(s, phone, push)
            val (slot, m) = try {
                s.recvFrom(60_000)
            } catch (_: WireError.Timeout) {
                kLock.withLock { s.ping() } // registers again (a rebooted watch forgets us) and throws on a dead link
                continue
            }
            if (parseRequest(m) == null) continue
            val pkg = names[slot] ?: kLock.withLock { packageIn(s, slot) }?.also { names[slot] = it } ?: continue
            // empty: a part of http.request before its last
            val replies = answer(pkg, m, phone)?.takeIf { it.isNotEmpty() } ?: continue
            val line = DevLog.request(pkg, m, replies)
            try {
                kLock.withLock { for (r in replies) s.send(r) }
                DevLog.log(this, "$line, ${replies.size} msg")
            } catch (e: WireError) {
                Log.w(TAG, "reply to $pkg: ${e.message}") // the app closed meanwhile
                DevLog.log(this, "$line, send failed: ${e.message}")
            }
        }
    }

    /** The watch apps' background jobs that are due, while the link is up (checked at least once a minute). */
    private suspend fun runDueJobs(s: KSession, phone: PhoneServices, push: PushTarget) {
        val jobs = Jobs(this)
        val now = System.currentTimeMillis()
        for ((pkg, list) in jobs.all()) for (j in list.filter { it.due(now) }) {
            jobs.ran(pkg, j.id, now) // first: a failing job waits its interval, not the next loop
            val records = try {
                withTimeoutOrNull(10_000) { runJob(pkg, j, phone) } ?: throw RpcError(RpcStatus.UNAVAILABLE)
            } catch (e: RpcError) {
                DevLog.log(this, "$pkg job ${j.id}: status ${e.status}")
                continue
            } catch (e: Exception) {
                DevLog.log(this, "$pkg job ${j.id}: ${e.message}")
                continue
            }
            kLock.withLock { deliverJob(s, pkg, j, records, push, now) }
        }
    }

    /** The stub's version and the apps' slots, read once per session for PUSH. */
    private class PushTarget {
        var stub: Long? = null
        var slots: Map<String, Int>? = null
    }

    /** Writes a job's records to the app's widget card or start blob (PUSH, stub 8, cmf-watch-sdk docs/widget-push.md). */
    private suspend fun deliverJob(s: KSession, pkg: String, job: RefreshJob, records: List<ByteArray>, t: PushTarget, now: Long) {
        val line = "$pkg job ${job.id}"
        val data = job.pushData(records) ?: return DevLog.log(this, "$line: nothing to push (${records.size} records)")
        val stub = t.stub ?: stubVersion(s).also { t.stub = it }
        if (!canPush(stub)) return DevLog.log(this, "$line: stub $stub takes no PUSH (8+)")
        val slots = t.slots ?: installed(s, appSlots(stub)).filterKeys { it != LOADER_SLOT }.entries
            .associate { it.value.name to it.key }.also { t.slots = it }
        val slot = slots[pkg] ?: return DevLog.log(this, "$line: not on the watch")
        when (val r = push(s, slot, job.target, data)) {
            PushResult.Ok -> DevLog.log(this, "$line: pushed to slot $slot")
            // due again once the watch takes a write for this slot
            is PushResult.Later -> Jobs(this).ran(pkg, job.id, now + r.ms - job.minutes * 60_000L)
            is PushResult.Refused -> {
                if (r.status == Status.NO_APP.code) t.slots = null // moved or removed: read the slots again next time
                DevLog.log(this, "$line: push refused (${r.status})")
            }
        }
    }

    private suspend fun packageIn(s: KSession, slot: Int): String? {
        val r = s.call(Cmd.INFO, bytes(slot), 4000)
        return if (r.isNotEmpty() && r.u8(0) == Status.OK.code) parseHeader(r.copyOfRange(1, r.size))?.name else null
    }

    companion object {
        private const val TAG = "rpc"

        fun start(context: Context) {
            if (!granted(context, Manifest.permission.BLUETOOTH_CONNECT)) return
            runCatching { ContextCompat.startForegroundService(context, Intent(context, RpcService::class.java)) }
        }

        fun stop(context: Context) = context.stopService(Intent(context, RpcService::class.java))
    }
}

fun granted(context: Context, permission: String) =
    ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
