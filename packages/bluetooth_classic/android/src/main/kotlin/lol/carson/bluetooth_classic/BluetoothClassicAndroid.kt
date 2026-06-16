package lol.carson.bluetooth_classic

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
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

/**
 * Android Bluetooth Classic implementation, driven from Dart via a C JNI shim
 * (see native/android/bluetooth_classic_jni.c). All methods are static and
 * called through JNI; results that are "events" (discovery sightings, inbound
 * data, state changes) are pushed back to Dart by calling the `native*` methods,
 * which the shim registers with RegisterNatives.
 *
 * The app must already hold the runtime Bluetooth permissions.
 */
@Suppress("unused")
object BluetoothClassicAndroid {
    private val SPP_FALLBACK: UUID =
        UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")

    private var adapter: BluetoothAdapter? = null
    private var context: Context? = null
    private var discoveryReceiver: BroadcastReceiver? = null
    private var discoveryToken: Long = 0

    private val sockets = ConcurrentHashMap<Long, BluetoothSocket>()
    private val nextHandle = AtomicLong(1)
    // Single-threaded so writes to a socket are never reordered/interleaved.
    private val writeExecutor = Executors.newSingleThreadExecutor()

    // Implemented in the C shim (registered via RegisterNatives).
    @JvmStatic external fun nativeOnFound(token: Long, json: String)
    @JvmStatic external fun nativeOnInquiryDone(token: Long, aborted: Int)
    @JvmStatic external fun nativeOnData(token: Long, data: ByteArray)
    @JvmStatic external fun nativeOnState(token: Long, state: Int)

    @JvmStatic
    fun initialize(): Int {
        return try {
            val ctx = currentApplication() ?: return 1 // unavailable
            context = ctx
            val mgr = ctx.getSystemService(Context.BLUETOOTH_SERVICE)
                    as? BluetoothManager
            adapter = mgr?.adapter
            if (adapter == null) 1 else 0
        } catch (t: Throwable) {
            1
        }
    }

    @JvmStatic
    fun adapterState(): Int {
        val a = adapter ?: return 1 // unavailable
        return when (a.state) {
            BluetoothAdapter.STATE_OFF -> 3
            BluetoothAdapter.STATE_TURNING_ON -> 4
            BluetoothAdapter.STATE_ON -> 5
            BluetoothAdapter.STATE_TURNING_OFF -> 6
            else -> 0
        }
    }

    // Returns "[]" on any failure (incl. SecurityException when BLUETOOTH_CONNECT
    // is not granted) so a JNI-pending exception can never abort the VM.
    @SuppressLint("MissingPermission")
    @JvmStatic
    fun bondedJson(): String {
        return try {
            val a = adapter ?: return "[]"
            val arr = JSONArray()
            for (d in a.bondedDevices.orEmpty()) {
                arr.put(deviceJson(d, bonded = true))
            }
            arr.toString()
        } catch (t: Throwable) {
            "[]"
        }
    }

    @SuppressLint("MissingPermission")
    @JvmStatic
    fun startDiscovery(token: Long): Int {
        return try {
            val a = adapter ?: return -1
            val ctx = context ?: return -1
            stopDiscovery()
            discoveryToken = token
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(c: Context, intent: Intent) {
                    when (intent.action) {
                        BluetoothDevice.ACTION_FOUND -> {
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
                        }
                        BluetoothAdapter.ACTION_DISCOVERY_FINISHED -> {
                            stopDiscovery() // unregister before signalling done
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
            if (a.startDiscovery()) 0 else -1
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

    @SuppressLint("MissingPermission")
    @JvmStatic
    fun stopDiscovery(): Int {
        try {
            adapter?.cancelDiscovery()
            discoveryReceiver?.let { context?.unregisterReceiver(it) }
        } catch (_: Throwable) {
        }
        discoveryReceiver = null
        return 0
    }

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
            startReadLoop(token, handle, socket)
            handle
        } catch (t: Throwable) {
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
        }, "btc-read-$handle").start()
    }

    @JvmStatic
    fun write(handle: Long, data: ByteArray): Int {
        val socket = sockets[handle] ?: return -1
        writeExecutor.execute {
            try {
                socket.outputStream.write(data)
                socket.outputStream.flush()
            } catch (_: Throwable) {
            }
        }
        return 0
    }

    @JvmStatic
    fun close(handle: Long): Int {
        val socket = sockets.remove(handle) ?: return 0
        try {
            socket.close()
        } catch (_: Throwable) {
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
            put("name", d.name ?: JSONObject.NULL)
            put("bonded", bonded)
            put("connected", false)
            d.bluetoothClass?.let { put("classOfDevice", it.deviceClass) }
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
