package lol.carson.bluetooth_le

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Android BLE central, driven from Dart via a C JNI shim (see
 * native/android/bluetooth_le_jni.c). All entry points are static and called
 * through JNI; async GATT results are pushed back to Dart by calling the
 * `native*` methods (registered via RegisterNatives), correlated by the
 * request/connection tokens Dart assigns.
 *
 * The app must already hold the runtime BLE permissions (BLUETOOTH_SCAN /
 * BLUETOOTH_CONNECT on API 31+, location on older).
 */
@Suppress("unused")
object BluetoothLeAndroid {
    private val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    private var adapter: BluetoothAdapter? = null
    private var context: Context? = null

    private var scanCallback: ScanCallback? = null
    private var scanToken: Long = 0

    private val connections = ConcurrentHashMap<Long, Conn>()

    // Implemented in the C shim (registered via RegisterNatives).
    @JvmStatic external fun nativeOnScan(token: Long, json: String)
    @JvmStatic external fun nativeOnState(token: Long, state: Int)
    @JvmStatic external fun nativeOnOp(reqId: Long, status: Int, json: String?, data: ByteArray?)
    @JvmStatic external fun nativeOnNotify(token: Long, key: String, data: ByteArray)

    /** Per-connection state: the live gatt plus the in-flight request ids. */
    private class Conn(val connToken: Long) {
        @Volatile var gatt: BluetoothGatt? = null
        @Volatile var discoverReq: Long = 0
        @Volatile var readReq: Long = 0
        @Volatile var writeReq: Long = 0
        @Volatile var mtuReq: Long = 0
    }

    @JvmStatic
    fun initialize(): Int {
        return try {
            val ctx = currentApplication() ?: return 1
            context = ctx
            val mgr = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
            adapter = mgr?.adapter
            if (adapter == null) 1 else 0
        } catch (t: Throwable) {
            1
        }
    }

    @JvmStatic
    fun adapterState(): Int {
        return try {
            val a = adapter ?: return 1
            when (a.state) {
                BluetoothAdapter.STATE_OFF -> 3
                BluetoothAdapter.STATE_TURNING_ON -> 4
                BluetoothAdapter.STATE_ON -> 5
                BluetoothAdapter.STATE_TURNING_OFF -> 6
                else -> 0
            }
        } catch (se: SecurityException) {
            2 // missing permission -> unauthorized (not "no radio")
        } catch (t: Throwable) {
            1
        }
    }

    // --- Scanning ------------------------------------------------------------

    @SuppressLint("MissingPermission")
    @JvmStatic
    fun startScan(token: Long, csv: String): Int {
        return try {
            val a = adapter ?: return -1
            val scanner = a.bluetoothLeScanner ?: return -1
            stopScan()
            scanToken = token
            val cb = object : ScanCallback() {
                override fun onScanResult(callbackType: Int, result: ScanResult) {
                    try {
                        nativeOnScan(token, scanJson(result).toString())
                    } catch (_: Throwable) {
                    }
                }

                override fun onBatchScanResults(results: MutableList<ScanResult>) {
                    for (r in results) onScanResult(0, r)
                }
            }
            scanCallback = cb
            // No filters here — Dart applies the service filter when starting the
            // scan; an empty filter list scans for everything.
            val settings = ScanSettings.Builder()
                .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
                .build()
            scanner.startScan(buildFilters(csv), settings, cb)
            0
        } catch (t: Throwable) {
            -1
        }
    }

    @SuppressLint("MissingPermission")
    @JvmStatic
    fun stopScan() {
        try {
            val cb = scanCallback ?: return
            adapter?.bluetoothLeScanner?.stopScan(cb)
        } catch (_: Throwable) {
        } finally {
            scanCallback = null
        }
    }

    private fun buildFilters(csv: String): List<android.bluetooth.le.ScanFilter> {
        if (csv.isBlank()) return emptyList()
        val filters = ArrayList<android.bluetooth.le.ScanFilter>()
        for (raw in csv.split(",")) {
            val t = raw.trim()
            if (t.isEmpty()) continue
            try {
                filters.add(
                    android.bluetooth.le.ScanFilter.Builder()
                        .setServiceUuid(android.os.ParcelUuid(UUID.fromString(t)))
                        .build()
                )
            } catch (_: Throwable) {
            }
        }
        return filters
    }

    // --- Connect -------------------------------------------------------------

    @SuppressLint("MissingPermission")
    @JvmStatic
    fun connect(connToken: Long, address: String): Int {
        return try {
            val a = adapter ?: return -1
            val device = a.getRemoteDevice(address) ?: return -1
            val conn = Conn(connToken)
            connections[connToken] = conn
            val callback = gattCallback(connToken)
            conn.gatt = device.connectGatt(
                context, false, callback, BluetoothDevice_TRANSPORT_LE
            )
            if (conn.gatt == null) {
                connections.remove(connToken)
                return -1
            }
            0
        } catch (t: Throwable) {
            connections.remove(connToken)
            -1
        }
    }

    @SuppressLint("MissingPermission")
    @JvmStatic
    fun disconnect(connToken: Long) {
        val conn = connections[connToken] ?: return
        try {
            conn.gatt?.disconnect()
            conn.gatt?.close()
        } catch (_: Throwable) {
        } finally {
            connections.remove(connToken)
        }
    }

    @SuppressLint("MissingPermission")
    @JvmStatic
    fun discoverServices(reqId: Long, connToken: Long) {
        val conn = connections[connToken]
        val gatt = conn?.gatt
        if (gatt == null) {
            nativeOnOp(reqId, GATT_FAILURE, null, null)
            return
        }
        conn.discoverReq = reqId
        if (!gatt.discoverServices()) nativeOnOp(reqId, GATT_FAILURE, null, null)
    }

    @SuppressLint("MissingPermission")
    @JvmStatic
    fun readCharacteristic(reqId: Long, connToken: Long, service: String, characteristic: String) {
        val conn = connections[connToken]
        val ch = findChar(conn, service, characteristic)
        if (conn == null || ch == null) {
            nativeOnOp(reqId, GATT_FAILURE, null, null)
            return
        }
        conn.readReq = reqId
        if (conn.gatt?.readCharacteristic(ch) != true) {
            conn.readReq = 0
            nativeOnOp(reqId, GATT_FAILURE, null, null)
        }
    }

    @SuppressLint("MissingPermission")
    @Suppress("DEPRECATION")
    @JvmStatic
    fun writeCharacteristic(
        reqId: Long,
        connToken: Long,
        service: String,
        characteristic: String,
        value: ByteArray,
        withoutResponse: Boolean,
    ) {
        val conn = connections[connToken]
        val ch = findChar(conn, service, characteristic)
        val gatt = conn?.gatt
        if (conn == null || ch == null || gatt == null) {
            nativeOnOp(reqId, GATT_FAILURE, null, null)
            return
        }
        val type = if (withoutResponse) {
            BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        } else {
            BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        }
        conn.writeReq = reqId
        val ok: Boolean = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gatt.writeCharacteristic(ch, value, type) ==
                BluetoothGatt.GATT_SUCCESS
        } else {
            ch.writeType = type
            ch.value = value
            gatt.writeCharacteristic(ch)
        }
        if (!ok) {
            conn.writeReq = 0
            nativeOnOp(reqId, GATT_FAILURE, null, null)
        }
    }

    @SuppressLint("MissingPermission")
    @Suppress("DEPRECATION")
    @JvmStatic
    fun subscribe(connToken: Long, service: String, characteristic: String, enable: Boolean) {
        val conn = connections[connToken]
        val ch = findChar(conn, service, characteristic)
        val gatt = conn?.gatt ?: return
        if (ch == null) return
        try {
            gatt.setCharacteristicNotification(ch, enable)
            val cccd: BluetoothGattDescriptor = ch.getDescriptor(CCCD) ?: return
            val value = when {
                !enable -> BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
                (ch.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY) != 0 ->
                    BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                else -> BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gatt.writeDescriptor(cccd, value)
            } else {
                cccd.value = value
                gatt.writeDescriptor(cccd)
            }
        } catch (_: Throwable) {
        }
    }

    @SuppressLint("MissingPermission")
    @JvmStatic
    fun requestMtu(reqId: Long, connToken: Long, mtu: Int) {
        val conn = connections[connToken]
        val gatt = conn?.gatt
        if (conn == null || gatt == null) {
            nativeOnOp(reqId, GATT_FAILURE, null, null)
            return
        }
        conn.mtuReq = reqId
        if (!gatt.requestMtu(mtu)) {
            conn.mtuReq = 0
            nativeOnOp(reqId, GATT_FAILURE, null, null)
        }
    }

    // --- GATT callback -------------------------------------------------------

    @Suppress("DEPRECATION")
    private fun gattCallback(connToken: Long): BluetoothGattCallback {
        return object : BluetoothGattCallback() {
            override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    nativeOnState(connToken, 0)
                    cleanup(connToken)
                    return
                }
                nativeOnState(connToken, newState)
                if (newState == BluetoothProfile.STATE_DISCONNECTED) cleanup(connToken)
            }

            override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
                val conn = connections[connToken] ?: return
                val reqId = conn.discoverReq
                conn.discoverReq = 0
                if (reqId == 0L) return
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    nativeOnOp(reqId, status, null, null)
                } else {
                    nativeOnOp(reqId, 0, servicesJson(gatt).toString(), null)
                }
            }

            override fun onCharacteristicRead(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                value: ByteArray,
                status: Int,
            ) = completeRead(connToken, status, value)

            override fun onCharacteristicRead(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int,
            ) {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                    completeRead(connToken, status, characteristic.value)
                }
            }

            override fun onCharacteristicWrite(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int,
            ) {
                val conn = connections[connToken] ?: return
                val reqId = conn.writeReq
                conn.writeReq = 0
                if (reqId != 0L) nativeOnOp(reqId, status, null, null)
            }

            override fun onCharacteristicChanged(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                value: ByteArray,
            ) = deliverNotify(characteristic, value)

            override fun onCharacteristicChanged(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
            ) {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                    deliverNotify(characteristic, characteristic.value ?: ByteArray(0))
                }
            }

            override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
                val conn = connections[connToken] ?: return
                val reqId = conn.mtuReq
                conn.mtuReq = 0
                if (reqId == 0L) return
                val json = JSONObject().apply { put("mtu", mtu) }
                nativeOnOp(reqId, status, json.toString(), null)
            }
        }
    }

    private fun completeRead(connToken: Long, status: Int, value: ByteArray?) {
        val conn = connections[connToken] ?: return
        val reqId = conn.readReq
        conn.readReq = 0
        if (reqId != 0L) nativeOnOp(reqId, status, null, value)
    }

    private fun deliverNotify(ch: BluetoothGattCharacteristic, value: ByteArray) {
        val service = ch.service ?: return
        val key = "${service.uuid}|${ch.uuid}"
        for ((token, conn) in connections) {
            if (conn.gatt?.getService(service.uuid)?.getCharacteristic(ch.uuid) === ch) {
                nativeOnNotify(token, key, value)
                return
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun cleanup(connToken: Long) {
        val conn = connections.remove(connToken) ?: return
        try {
            conn.gatt?.close()
        } catch (_: Throwable) {
        }
    }

    private fun findChar(
        conn: Conn?,
        service: String,
        characteristic: String,
    ): BluetoothGattCharacteristic? {
        val gatt = conn?.gatt ?: return null
        return try {
            gatt.getService(UUID.fromString(service))
                ?.getCharacteristic(UUID.fromString(characteristic))
        } catch (_: Throwable) {
            null
        }
    }

    private fun servicesJson(gatt: BluetoothGatt): JSONArray {
        val services = JSONArray()
        for (s in gatt.services.orEmpty()) {
            val chars = JSONArray()
            for (c in s.characteristics.orEmpty()) {
                chars.put(
                    JSONObject().apply {
                        put("uuid", c.uuid.toString())
                        put("properties", propertyNames(c.properties))
                    }
                )
            }
            services.put(
                JSONObject().apply {
                    put("uuid", s.uuid.toString())
                    put("characteristics", chars)
                }
            )
        }
        return services
    }

    private fun propertyNames(props: Int): JSONArray {
        val a = JSONArray()
        if (props and BluetoothGattCharacteristic.PROPERTY_READ != 0) a.put("read")
        if (props and BluetoothGattCharacteristic.PROPERTY_WRITE != 0) a.put("write")
        if (props and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0) {
            a.put("writeWithoutResponse")
        }
        if (props and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0) a.put("notify")
        if (props and BluetoothGattCharacteristic.PROPERTY_INDICATE != 0) a.put("indicate")
        return a
    }

    @SuppressLint("MissingPermission")
    private fun scanJson(result: ScanResult): JSONObject {
        val device = result.device
        val record = result.scanRecord
        return JSONObject().apply {
            put("id", device.address)
            val name = record?.deviceName ?: device.name
            if (name != null) put("name", name)
            put("rssi", result.rssi)
            put(
                "connectable",
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    result.isConnectable
                } else {
                    true
                },
            )
            record?.serviceUuids?.let { uuids ->
                val arr = JSONArray()
                for (u in uuids) arr.put(u.uuid.toString())
                if (arr.length() > 0) put("serviceUuids", arr)
            }
            record?.let { rec ->
                val mfg = rec.manufacturerSpecificData
                if (mfg != null && mfg.size() > 0) {
                    val obj = JSONObject()
                    for (i in 0 until mfg.size()) {
                        obj.put(mfg.keyAt(i).toString(), hexOf(mfg.valueAt(i)))
                    }
                    put("manufacturerData", obj)
                }
                rec.serviceData?.let { sd ->
                    if (sd.isNotEmpty()) {
                        val obj = JSONObject()
                        for ((k, v) in sd) obj.put(k.uuid.toString(), hexOf(v))
                        put("serviceData", obj)
                    }
                }
            }
        }
    }

    private fun hexOf(bytes: ByteArray?): String {
        if (bytes == null) return ""
        val sb = StringBuilder(bytes.size * 2)
        for (b in bytes) sb.append(String.format("%02x", b.toInt() and 0xff))
        return sb.toString()
    }

    private fun currentApplication(): Context? {
        return try {
            val activityThread = Class.forName("android.app.ActivityThread")
            val app = activityThread.getMethod("currentApplication").invoke(null)
            app as? Context
        } catch (t: Throwable) {
            null
        }
    }

    // BluetoothDevice.TRANSPORT_LE (== 2); referenced by literal so the import
    // list stays minimal.
    private const val BluetoothDevice_TRANSPORT_LE = 2
    private const val GATT_FAILURE = BluetoothGatt.GATT_FAILURE
}
