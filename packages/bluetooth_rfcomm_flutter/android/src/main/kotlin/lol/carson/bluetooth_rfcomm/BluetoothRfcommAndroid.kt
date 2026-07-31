package lol.carson.bluetooth_rfcomm

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

/**
 * Android Bluetooth Classic implementation, driven from Dart via a C JNI shim
 * (see native/android/bluetooth_rfcomm_jni.c). All methods are static and
 * called through JNI; results that are "events" (discovery sightings, inbound
 * data, state changes) are pushed back to Dart by calling the `native*` methods,
 * which the shim registers with RegisterNatives.
 *
 * The app must already hold the runtime Bluetooth permissions.
 */
@Suppress("unused")
object BluetoothRfcommAndroid {
    private const val TAG = "BluetoothRfcomm"

    private val SPP_FALLBACK: UUID =
        UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")

    private var adapter: BluetoothAdapter? = null
    private var context: Context? = null
    private var discoveryReceiver: BroadcastReceiver? = null
    private var discoveryToken: Long = 0
    // Guards discoveryReceiver/discoveryToken so receiver swaps are atomic and
    // a stale receiver's FINISHED broadcast can't tear down a newer discovery.
    private val discoveryLock = Any()

    private val sockets = ConcurrentHashMap<Long, BluetoothSocket>()
    private val nextHandle = AtomicLong(1)
    // One single-threaded executor PER socket: writes to a given socket are never
    // reordered, and a stalled write on one socket can't block writes to others.
    private val writeExecutors = ConcurrentHashMap<Long, java.util.concurrent.ExecutorService>()
    // Bytes submitted to a socket's write executor and not yet written (or
    // failed): incremented at enqueue, decremented when the task finishes.
    // Read by pendingBytes() for the Dart-side pendingWriteBytes getter.
    private val pendingWrite = ConcurrentHashMap<Long, AtomicLong>()
    // Set once ANY executor write on the socket has failed. From that moment
    // the stream has a hole, so write() fail-fasts and flush() reports the
    // loss (-1) instead of pretending the drain succeeded — the failure also
    // closes the socket, which unblocks the read loop into its disconnect
    // report, so callers always learn the link is gone.
    private val writeFailed = ConcurrentHashMap<Long, Boolean>()

    // Implemented in the C shim (registered via RegisterNatives).
    @JvmStatic external fun nativeOnFound(token: Long, json: String)
    @JvmStatic external fun nativeOnInquiryDone(token: Long, aborted: Int)
    @JvmStatic external fun nativeOnData(token: Long, data: ByteArray)
    @JvmStatic external fun nativeOnState(token: Long, state: Int)

    // 0 = ready, 1 = no Bluetooth adapter (genuinely unsupported hardware),
    // 2 = no Application context (bridge ran before the app was up). Distinct
    // so the Dart layer can tell "this phone has no radio" from "the plumbing
    // is broken" — collapsing them is how infrastructure failures hide.
    @JvmStatic
    fun initialize(): Int {
        return try {
            val ctx = currentApplication() ?: return 2
            context = ctx
            val mgr = ctx.getSystemService(Context.BLUETOOTH_SERVICE)
                    as? BluetoothManager
            adapter = mgr?.adapter
            if (adapter == null) 1 else 0
        } catch (t: Throwable) {
            2
        }
    }

    @SuppressLint("MissingPermission")
    @JvmStatic
    fun adapterState(): Int {
        return try {
            val a = adapter ?: return 1 // unavailable
            when (a.state) {
                BluetoothAdapter.STATE_OFF -> 3
                BluetoothAdapter.STATE_TURNING_ON -> 4
                BluetoothAdapter.STATE_ON -> 5
                BluetoothAdapter.STATE_TURNING_OFF -> 6
                else -> 0
            }
        } catch (se: SecurityException) {
            2 // missing BLUETOOTH_CONNECT -> unauthorized (not "no radio")
        } catch (t: Throwable) {
            1 // unavailable
        }
    }

    // Failures return a JSON *object* envelope ({"error": code}) instead of an
    // array, so the Dart side can distinguish "genuinely zero bonded devices"
    // ("[]") from a failure — silently equating the two is how a missing
    // BLUETOOTH_CONNECT grant masquerades as an empty phone. Never throws
    // (a JNI-pending exception could abort the VM). Codes mirror connect():
    // -2 adapter unavailable, -3 permission, -1 anything else.
    @SuppressLint("MissingPermission")
    @JvmStatic
    fun bondedJson(): String {
        return try {
            val a = adapter ?: return """{"error":-2}"""
            val arr = JSONArray()
            for (d in a.bondedDevices.orEmpty()) {
                arr.put(deviceJson(d, bonded = true))
            }
            arr.toString()
        } catch (se: SecurityException) {
            """{"error":-3}"""
        } catch (t: Throwable) {
            """{"error":-1}"""
        }
    }

    @SuppressLint("MissingPermission")
    @JvmStatic
    fun startDiscovery(token: Long): Int {
        return try {
            val a = adapter ?: return -1
            val ctx = context ?: return -1
            synchronized(discoveryLock) {
                stopDiscoveryLocked()
                discoveryToken = token
                val receiver = object : BroadcastReceiver() {
                    override fun onReceive(c: Context, intent: Intent) {
                        when (intent.action) {
                            BluetoothDevice.ACTION_FOUND -> try {
                                val device = deviceExtra(intent)
                                val rssi = intent.getShortExtra(
                                    BluetoothDevice.EXTRA_RSSI, Short.MIN_VALUE
                                )
                                if (device != null) {
                                    val json = deviceJson(
                                        device,
                                        bonded = device.bondState ==
                                            BluetoothDevice.BOND_BONDED,
                                        rssi = if (rssi.toInt() == Short.MIN_VALUE.toInt())
                                            null else rssi.toInt(),
                                    )
                                    nativeOnFound(token, json.toString())
                                }
                            } catch (t: Throwable) {
                                // An uncaught throw in a BroadcastReceiver kills
                                // the whole process. bondState/name need
                                // BLUETOOTH_CONNECT, which can be missing while
                                // BLUETOOTH_SCAN is granted — drop the sighting,
                                // never crash the app.
                            }
                            BluetoothAdapter.ACTION_DISCOVERY_FINISHED -> {
                                // A FINISHED delivered to a STALE receiver (one
                                // already replaced by a newer startDiscovery,
                                // with the broadcast still in flight) must not
                                // cancel the new scan or unregister the new
                                // receiver: only the CURRENT receiver may act.
                                synchronized(discoveryLock) {
                                    if (discoveryReceiver !== this) return
                                    // Unregister before signalling done.
                                    stopDiscoveryLocked()
                                }
                                nativeOnInquiryDone(token, 0)
                            }
                        }
                    }
                }
                val filter = IntentFilter().apply {
                    addAction(BluetoothDevice.ACTION_FOUND)
                    addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED)
                }
                registerReceiverCompat(ctx, receiver, filter)
                discoveryReceiver = receiver
                if (a.startDiscovery()) {
                    0
                } else {
                    // Dart treats -1 as never-started; leaving the receiver
                    // registered would leak it until the next start/stop/reset.
                    stopDiscoveryLocked()
                    -1
                }
            }
        } catch (t: Throwable) {
            -1
        }
    }

    @Suppress("DEPRECATION")
    private fun deviceExtra(intent: Intent): BluetoothDevice? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(
                BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java
            )
        } else {
            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
        }
    }

    private fun registerReceiverCompat(
        ctx: Context,
        receiver: BroadcastReceiver,
        filter: IntentFilter,
    ) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ctx.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            ctx.registerReceiver(receiver, filter)
        }
    }

    @JvmStatic
    fun stopDiscovery(): Int {
        synchronized(discoveryLock) { stopDiscoveryLocked() }
        return 0
    }

    // Must be called with discoveryLock held.
    @SuppressLint("MissingPermission")
    private fun stopDiscoveryLocked() {
        // Independent try blocks: if cancelDiscovery throws (e.g. a
        // SecurityException), the receiver must still be unregistered or it
        // leaks for the lifetime of the process.
        try {
            adapter?.cancelDiscovery()
        } catch (_: Throwable) {
        }
        try {
            discoveryReceiver?.let { context?.unregisterReceiver(it) }
        } catch (_: Throwable) {
        }
        discoveryReceiver = null
    }

    /**
     * Returns a socket handle, or 0 on any failure. The JNI ABI has no error
     * channel, so all failure modes (SecurityException / missing
     * BLUETOOTH_CONNECT, hidden-API denial of createRfcommSocket, IOException
     * from connect) collapse into 0; the throwable is logged under [TAG] so
     * failures are diagnosable via logcat.
     */
    @SuppressLint("MissingPermission")
    @JvmStatic
    fun openRfcomm(token: Long, address: String, channel: Int, uuid: String): Long {
        val a = adapter ?: return 0
        return try {
            val device = a.getRemoteDevice(address)
            a.cancelDiscovery()
            val socket: BluetoothSocket = if (channel > 0) {
                // Explicit channel via the hidden createRfcommSocket(int).
                val m = device.javaClass.getMethod(
                    "createRfcommSocket", Int::class.javaPrimitiveType
                )
                m.invoke(device, channel) as BluetoothSocket
            } else {
                device.createRfcommSocketToServiceRecord(
                    runCatching { UUID.fromString(uuid) }.getOrDefault(SPP_FALLBACK)
                )
            }
            socket.connect()
            val handle = nextHandle.getAndIncrement()
            sockets[handle] = socket
            pendingWrite[handle] = AtomicLong(0)
            writeExecutors[handle] = Executors.newSingleThreadExecutor { r ->
                Thread(r, "btc-write-$handle").apply { isDaemon = true }
            }
            startReadLoop(token, handle, socket)
            handle
        } catch (t: Throwable) {
            Log.w(TAG, "openRfcomm failed for $address (channel=$channel)", t)
            0
        }
    }

    private fun startReadLoop(token: Long, handle: Long, socket: BluetoothSocket) {
        Thread({
            val buf = ByteArray(8192)
            val input = socket.inputStream
            try {
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    if (n > 0) nativeOnData(token, buf.copyOf(n))
                }
            } catch (_: Throwable) {
            } finally {
                nativeOnState(token, 0) // disconnected
                close(handle)
            }
            // Daemon so a never-closed handle can't keep the JVM from exiting.
        }, "btc-read-$handle").apply { isDaemon = true }.start()
    }

    @JvmStatic
    fun write(handle: Long, data: ByteArray): Int {
        val socket = sockets[handle] ?: return -1
        val exec = writeExecutors[handle] ?: return -1
        // A previous write already failed: the byte stream has a hole, so no
        // later message may be transmitted (or silently swallowed). Fail fast;
        // the read loop's disconnect is already on its way.
        if (writeFailed[handle] == true) return -1
        val pending = pendingWrite[handle]
        pending?.addAndGet(data.size.toLong())
        try {
            exec.execute {
                try {
                    socket.outputStream.write(data)
                    socket.outputStream.flush()
                } catch (_: Throwable) {
                    // A failed write means the link is dead. Mark the handle
                    // failed (write() fail-fasts, flush() reports the loss)
                    // and close the socket so the read loop unblocks and
                    // reports disconnect, instead of silently black-holing
                    // further writes.
                    writeFailed[handle] = true
                    try {
                        socket.close()
                    } catch (_: Throwable) {
                    }
                } finally {
                    pending?.addAndGet(-data.size.toLong())
                }
            }
        } catch (_: java.util.concurrent.RejectedExecutionException) {
            pending?.addAndGet(-data.size.toLong())
            return -1 // executor already shut down (closed)
        }
        return 0
    }

    /**
     * OS-advertised maximum single-write payload for the socket
     * (BluetoothSocket.getMaxTransmitPacketSize, API 23+). Returns -1 when the
     * handle is unknown or the value is unavailable.
     */
    @JvmStatic
    fun maxTxSize(handle: Long): Int {
        val socket = sockets[handle] ?: return -1
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                socket.maxTransmitPacketSize
            } else {
                -1
            }
        } catch (t: Throwable) {
            -1
        }
    }

    /**
     * Bytes submitted to the socket's write executor and not yet handed to the
     * socket (exact — maintained by an AtomicLong around each write task).
     * Returns 0 for an unknown/closed handle.
     */
    @JvmStatic
    fun pendingBytes(handle: Long): Long = pendingWrite[handle]?.get() ?: 0L

    /**
     * Drains the per-socket write queue: submits a marker task to the write
     * executor and blocks until it runs, i.e. until every write queued before
     * this call has been handed to the socket. Returns 0 on success, -1 if the
     * handle is unknown/closed or the drain doesn't finish within 10 seconds.
     */
    @JvmStatic
    fun flush(handle: Long): Int {
        val exec = writeExecutors[handle] ?: return -1
        return try {
            exec.submit(Runnable {}).get(10, java.util.concurrent.TimeUnit.SECONDS)
            // The marker draining is not enough: if any earlier write FAILED,
            // bytes were lost — flush must report that, not a clean drain.
            if (writeFailed[handle] == true) -1 else 0
        } catch (t: Throwable) {
            -1 // shut down (closed), interrupted, or timed out
        }
    }

    @JvmStatic
    fun close(handle: Long): Int {
        val socket = sockets.remove(handle)
        writeExecutors.remove(handle)?.shutdownNow()
        pendingWrite.remove(handle)
        writeFailed.remove(handle)
        if (socket == null) return 0
        try {
            socket.close()
        } catch (_: Throwable) {
        }
        return 0
    }

    /**
     * Quiesces every event source owned by this object: stops discovery
     * (unregistering the receiver) and closes every open socket, shutting the
     * write executors down and unblocking the read loops. Called by the Dart
     * layer at construction — BEFORE it registers new callback pointers — so
     * nothing left over from a dead isolate (Flutter hot restart) can invoke a
     * destroyed NativeCallable trampoline; also called at dispose.
     *
     * Deliberately does NOT touch the C callback pointers themselves: the Dart
     * side owns (re-)registration, reset only kills the event sources. The read
     * loops unblocked here still fire a final nativeOnState/close(handle) as
     * they die; both are harmless — close() on an absent handle is a no-op and
     * the stale token is dropped on the Dart side.
     */
    @JvmStatic
    fun reset(): Int {
        synchronized(discoveryLock) {
            stopDiscoveryLocked()
            // Drain both maps. close() removes each handle from both, so the
            // dying read loops' own close(handle) calls find nothing to do.
            for (handle in sockets.keys.toList()) close(handle)
            for (exec in writeExecutors.values) exec.shutdownNow()
            writeExecutors.clear()
            sockets.clear()
            pendingWrite.clear()
            writeFailed.clear()
        }
        return 0
    }

    @SuppressLint("MissingPermission")
    private fun deviceJson(
        d: BluetoothDevice,
        bonded: Boolean,
        rssi: Int? = null,
    ): JSONObject {
        return JSONObject().apply {
            put("address", d.address)
            // name/bluetoothClass need BLUETOOTH_CONNECT on API 31+; a missing
            // grant must degrade to an unnamed sighting, not lose the device.
            put("name", runCatching { d.name }.getOrNull() ?: JSONObject.NULL)
            put("bonded", bonded)
            put("connected", false)
            runCatching { d.bluetoothClass }.getOrNull()
                ?.let { put("classOfDevice", it.deviceClass) }
            if (rssi != null) put("rssi", rssi)
        }
    }

    private fun currentApplication(): Context? {
        // Obtain the app Context without a plugin registration so the package
        // stays Flutter-free.
        return try {
            val activityThread = Class.forName("android.app.ActivityThread")
            val app = activityThread.getMethod("currentApplication").invoke(null)
            app as? Context
        } catch (t: Throwable) {
            null
        }
    }
}
