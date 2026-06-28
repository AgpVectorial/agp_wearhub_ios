package com.agptech.agp_wear_hub

import android.app.Application
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import androidx.localbroadcastmanager.content.LocalBroadcastManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

import com.oudmon.ble.base.bluetooth.BleAction
import com.oudmon.ble.base.bluetooth.BleOperateManager
import com.oudmon.ble.base.bluetooth.DeviceManager
import com.oudmon.ble.base.bluetooth.ListenerKey
import com.oudmon.ble.base.bluetooth.QCBluetoothCallbackCloneReceiver
import com.oudmon.ble.base.communication.CommandHandle
import com.oudmon.ble.base.communication.Constants
import com.oudmon.ble.base.communication.ICommandResponse
import com.oudmon.ble.base.communication.LargeDataHandler
import com.oudmon.ble.base.communication.req.*
import com.oudmon.ble.base.communication.rsp.*
import com.oudmon.ble.base.communication.entity.StartEndTimeEntity
import com.oudmon.ble.base.communication.entity.AlarmEntity
import com.oudmon.ble.base.bean.SleepDisplay
import com.oudmon.ble.base.communication.ILargeDataSleepResponse
import com.oudmon.ble.base.communication.ILargeDataLaunchSleepResponse
import com.oudmon.ble.base.communication.responseImpl.DeviceNotifyListener
import com.oudmon.ble.base.communication.rsp.SleepNewProtoResp
import com.oudmon.ble.base.util.MessPushUtil

/**
 * Plugin care face punte între Flutter (MethodChannel/EventChannel) și QC Wireless SDK.
 *
 * MethodChannel  "agp_sdk"          → scan, connect, disconnect, readMetrics, startHR, stopHR, battery
 * EventChannel   "agp_sdk/hr_stream" → HR notifications push
 * EventChannel   "agp_sdk/conn_stream" → connection status push
 */
class QcSdkPlugin(
    private val context: Context,
    flutterEngine: FlutterEngine
) {
    companion object {
        private const val TAG = "QcSdkPlugin"
        private const val METHOD_CHANNEL = "agp_sdk"
        private const val HR_EVENT_CHANNEL = "agp_sdk/hr_stream"
        private const val CONN_EVENT_CHANNEL = "agp_sdk/conn_stream"
        private const val SPO2_EVENT_CHANNEL = "agp_sdk/spo2_stream"
        private const val BP_EVENT_CHANNEL = "agp_sdk/bp_stream"
        private const val TEMP_EVENT_CHANNEL = "agp_sdk/temp_stream"
        private const val HRV_EVENT_CHANNEL = "agp_sdk/hrv_stream"
        private const val STRESS_EVENT_CHANNEL = "agp_sdk/stress_stream"
        private const val DIAG_EVENT_CHANNEL    = "agp_sdk/diag_stream"

        @Volatile
        private var activeInstance: QcSdkPlugin? = null

        fun getActiveInstance(): QcSdkPlugin? = activeInstance
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val bleManager: BleOperateManager
    private val app: Application = context.applicationContext as Application

    // EventChannel sinks
    private var hrSink: EventChannel.EventSink? = null
    private var connSink: EventChannel.EventSink? = null
    private var spo2Sink: EventChannel.EventSink? = null
    private var bpSink: EventChannel.EventSink? = null
    private var tempSink: EventChannel.EventSink? = null
    private var hrvSink: EventChannel.EventSink? = null
    private var stressSink: EventChannel.EventSink? = null
    private var diagSink:   EventChannel.EventSink? = null
    private var oneClickRunning = false
    private var callReminderEnabled = false

    // Cached last-measured vital values (for polling fallback)
    @Volatile private var lastHr = 0
    @Volatile private var lastSpo2 = 0
    @Volatile private var lastSbp = 0
    @Volatile private var lastDbp = 0
    @Volatile private var lastTempRaw = 0
    @Volatile private var lastHrv = 0
    @Volatile private var lastStress = 0
    @Volatile private var lastSteps = 0
    @Volatile private var lastCalories = 0

    // Track connected device
    private var connectedDeviceId: String? = null

    // Pending connect result (fulfilled by onServiceDiscovered callback)
    private var pendingConnectResult: MethodChannel.Result? = null
    private var pendingConnectDeviceId: String? = null
    private var connectTimeoutRunnable: Runnable? = null

    // Delayed poll runnables for vitals that use shared SDK bleManager.response field
    private var tempPollRunnable: Runnable? = null
    private var bpPollRunnable: Runnable? = null
    @Volatile private var tempPollActive = false

    // Active native scan callback
    private var activeScanCallback: ScanCallback? = null

    // Service discovered flag — commands only work after this
    private var serviceReady = false

    private val deviceNotifyListener = object : DeviceNotifyListener() {
        override fun onDataResponse(resultEntity: DeviceNotifyRsp?) {
            if (resultEntity == null || resultEntity.status != BaseRspCmd.RESULT_OK) return
            when (resultEntity.dataType) {
                0x12 -> {
                    val data = resultEntity.loadData ?: return
                    if (data.size < 10) return
                    val step = bytesToInt(data[1], data[2], data[3])
                    val calorie = bytesToInt(data[4], data[5], data[6])
                    lastSteps = step
                    lastCalories = calorie
                    diag("[STEP_NOTIFY] step=$step calorie=$calorie")
                }
                4 -> diag("[STEP_NOTIFY] dataType=4 received")
            }
        }
    }

    // ────────────────────────────────────────────────────────────────
    //  SDK LocalBroadcast receiver (GATT events, service discovery)
    // ────────────────────────────────────────────────────────────────

    private val bleCallbackReceiver = object : QCBluetoothCallbackCloneReceiver() {
        override fun connectStatue(device: BluetoothDevice?, connected: Boolean) {
            Log.d(TAG, ">>> connectStatue: device=${device?.address} name=${device?.name} connected=$connected")
            if (device != null && connected) {
                if (device.name != null) {
                    DeviceManager.getInstance().deviceName = device.name
                }
            } else {
                // Disconnected
                serviceReady = false
                val id = connectedDeviceId
                connectedDeviceId = null
                if (id != null) {
                    mainHandler.post {
                        connSink?.success(mapOf("deviceId" to id, "connected" to false))
                    }
                }
                // If a connect was pending, fail it
                pendingConnectResult?.let { r ->
                    mainHandler.post {
                        r.error("CONNECT_FAILED", "Device disconnected during setup", null)
                    }
                    pendingConnectResult = null
                    pendingConnectDeviceId = null
                }
            }
        }

        override fun onServiceDiscovered() {
            Log.d(TAG, ">>> onServiceDiscovered! Calling LargeDataHandler.initEnable()...")
            serviceReady = true

            // CRITICAL: SDK requires this before any commands
            LargeDataHandler.getInstance().initEnable()

            mainHandler.postDelayed({
                // Send CMD_BIND_SUCCESS (tells watch binding is complete)
                try {
                    CommandHandle.getInstance()
                        .executeReqCmd(SimpleKeyReq(Constants.CMD_BIND_SUCCESS), null)
                    Log.d(TAG, "CMD_BIND_SUCCESS sent")
                } catch (e: Exception) {
                    Log.e(TAG, "CMD_BIND_SUCCESS failed", e)
                }

                // Sync time
                syncTimeInternal()

                // Fulfill pending connect result
                val deviceId = pendingConnectDeviceId ?: connectedDeviceId
                if (deviceId != null) {
                    connectedDeviceId = deviceId
                    // Cancel timeout
                    connectTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
                    connectTimeoutRunnable = null

                    connSink?.success(mapOf("deviceId" to deviceId, "connected" to true))
                    pendingConnectResult?.success(true)
                    pendingConnectResult = null
                    pendingConnectDeviceId = null

                    Log.d(TAG, "Connection fully ready for $deviceId")
                }
            }, 1000)
        }

        override fun onCharacteristicChange(address: String?, uuid: String?, data: ByteArray?) {
            // SDK handles this internally
        }

        override fun onCharacteristicRead(uuid: String?, data: ByteArray?) {
            if (uuid != null && data != null) {
                val version = String(data, Charsets.UTF_8)
                Log.d(TAG, "Characteristic read: uuid=$uuid value=$version")
            }
        }
    }

    // ────────────────────────────────────────────────────────────────
    //  System Bluetooth state receiver
    // ────────────────────────────────────────────────────────────────

    private val bluetoothReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            when (intent.action) {
                BluetoothAdapter.ACTION_STATE_CHANGED -> {
                    val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, -1)
                    if (state == BluetoothAdapter.STATE_OFF) {
                        Log.d(TAG, "Bluetooth OFF")
                        bleManager.setBluetoothTurnOff(false)
                        bleManager.disconnect()
                        serviceReady = false
                        val id = connectedDeviceId
                        connectedDeviceId = null
                        if (id != null) {
                            mainHandler.post {
                                connSink?.success(mapOf("deviceId" to id, "connected" to false))
                            }
                        }
                    } else if (state == BluetoothAdapter.STATE_ON) {
                        Log.d(TAG, "Bluetooth ON")
                        bleManager.setBluetoothTurnOff(true)
                        val mac = DeviceManager.getInstance().deviceAddress
                        if (!mac.isNullOrEmpty()) {
                            bleManager.reConnectMac = mac
                            bleManager.connectDirectly(mac)
                        }
                    }
                }
                BluetoothDevice.ACTION_ACL_CONNECTED ->
                    Log.d(TAG, "ACL_CONNECTED")
                BluetoothDevice.ACTION_ACL_DISCONNECTED ->
                    Log.d(TAG, "ACL_DISCONNECTED")
                BluetoothDevice.ACTION_BOND_STATE_CHANGED ->
                    Log.d(TAG, "BOND_STATE_CHANGED")
            }
        }
    }

    // ────────────────────────────────────────────────────────────────
    //  Init — order matches SDK sample: receivers FIRST, then init()
    // ────────────────────────────────────────────────────────────────

    init {
        activeInstance = this

        // 1. Register LocalBroadcast receiver BEFORE SDK init (required!)
        val intentFilter = BleAction.getIntentFilter()
        LocalBroadcastManager.getInstance(app)
            .registerReceiver(bleCallbackReceiver, intentFilter)
        Log.d(TAG, "LocalBroadcast receiver registered for SDK events")

        // 2. Init BLE SDK
        bleManager = BleOperateManager.getInstance(app)
        bleManager.init()
        Log.d(TAG, "BleOperateManager initialized")

        // 3. Register system Bluetooth state receiver
        val deviceFilter = BleAction.getDeviceIntentFilter()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            app.registerReceiver(bluetoothReceiver, deviceFilter, Context.RECEIVER_EXPORTED)
        } else {
            app.registerReceiver(bluetoothReceiver, deviceFilter)
        }
        Log.d(TAG, "System Bluetooth receiver registered")

        // 4. Setup Flutter channels
        setupMethodChannel(flutterEngine)
        setupHrEventChannel(flutterEngine)
        setupConnEventChannel(flutterEngine)
        setupSpO2EventChannel(flutterEngine)
        setupBpEventChannel(flutterEngine)
        setupTempEventChannel(flutterEngine)
        setupHrvEventChannel(flutterEngine)
        setupStressEventChannel(flutterEngine)
        setupDiagEventChannel(flutterEngine)
        bleManager.addOutDeviceListener(ListenerKey.All, deviceNotifyListener)
    }

    // ────────────────────────────────────────────────────────────────
    //  MethodChannel
    // ────────────────────────────────────────────────────────────────

    private fun setupMethodChannel(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "scan" -> handleScan(result)
                    "connect" -> {
                        val id = call.argument<String>("id")
                        if (id != null) handleConnect(id, result)
                        else result.error("MISSING_ID", "Device ID required", null)
                    }
                    "disconnect" -> handleDisconnect(result)
                    "getConnectionStatus" -> {
                        val id = connectedDeviceId
                        result.success(mapOf(
                            "connected" to (id != null && serviceReady && bleManager.isConnected),
                            "deviceId" to id
                        ))
                    }
                    "readMetrics" -> {
                        val id = call.argument<String>("id")
                        if (id != null) handleReadMetrics(id, result)
                        else result.error("MISSING_ID", "Device ID required", null)
                    }
                    "startHeartRateNotifications" -> {
                        val id = call.argument<String>("id")
                        if (id != null) handleStartHr(id, result)
                        else result.error("MISSING_ID", "Device ID required", null)
                    }
                    "stopHeartRateNotifications" -> {
                        val id = call.argument<String>("id")
                        if (id != null) handleStopHr(id, result)
                        else result.error("MISSING_ID", "Device ID required", null)
                    }
                    "syncTime" -> handleSyncTime(result)
                    "getBattery" -> handleGetBattery(result)
                    "setHeartRateInterval" -> {
                        val interval = call.argument<Int>("interval") ?: 10
                        val enable = call.argument<Boolean>("enable") ?: true
                        handleSetHrInterval(enable, interval, result)
                    }
                    "startSpO2" -> {
                        val id = call.argument<String>("id")
                        if (id != null) handleStartSpO2(id, result)
                        else result.error("MISSING_ID", "Device ID required", null)
                    }
                    "stopSpO2" -> {
                        val id = call.argument<String>("id")
                        if (id != null) handleStopSpO2(id, result)
                        else result.error("MISSING_ID", "Device ID required", null)
                    }
                    "startBloodPressure" -> {
                        val id = call.argument<String>("id")
                        if (id != null) handleStartBP(id, result)
                        else result.error("MISSING_ID", "Device ID required", null)
                    }
                    "stopBloodPressure" -> {
                        val id = call.argument<String>("id")
                        if (id != null) handleStopBP(id, result)
                        else result.error("MISSING_ID", "Device ID required", null)
                    }
                    "startTemperature" -> {
                        val id = call.argument<String>("id")
                        if (id != null) handleStartTemp(id, result)
                        else result.error("MISSING_ID", "Device ID required", null)
                    }
                    "stopTemperature" -> {
                        val id = call.argument<String>("id")
                        if (id != null) handleStopTemp(id, result)
                        else result.error("MISSING_ID", "Device ID required", null)
                    }
                    "startHrv" -> {
                        val id = call.argument<String>("id")
                        if (id != null) handleStartHrv(id, result)
                        else result.error("MISSING_ID", "Device ID required", null)
                    }
                    "stopHrv" -> {
                        val id = call.argument<String>("id")
                        if (id != null) handleStopHrv(id, result)
                        else result.error("MISSING_ID", "Device ID required", null)
                    }
                    "checkNow" -> {
                        val id = call.argument<String>("id")
                        if (id != null) handleCheckNow(id, result)
                        else result.error("MISSING_ID", "Device ID required", null)
                    }
                    "findDevice" -> handleFindDevice(result)
                    "enterCamera" -> handleEnterCamera(result)
                    "exitCamera" -> handleExitCamera(result)
                    "setCallReminder" -> {
                        val enable = call.argument<Boolean>("enable") ?: true
                        handleSetCallReminder(enable, result)
                    }
                    "isNotificationAccessEnabled" -> {
                        result.success(isNotificationAccessEnabled())
                    }
                    "openNotificationAccessSettings" -> {
                        openNotificationAccessSettings()
                        result.success(true)
                    }
                    "setSedentaryReminder" -> {
                        val enable = call.argument<Boolean>("enable") ?: true
                        val interval = call.argument<Int>("interval") ?: 60
                        val startH = call.argument<Int>("startHour") ?: 9
                        val startM = call.argument<Int>("startMinute") ?: 0
                        val endH = call.argument<Int>("endHour") ?: 18
                        val endM = call.argument<Int>("endMinute") ?: 0
                        handleSetSedentaryReminder(enable, interval, startH, startM, endH, endM, result)
                    }
                    "setDnd" -> {
                        val enable = call.argument<Boolean>("enable") ?: false
                        val startH = call.argument<Int>("startHour") ?: 22
                        val startM = call.argument<Int>("startMinute") ?: 0
                        val endH = call.argument<Int>("endHour") ?: 7
                        val endM = call.argument<Int>("endMinute") ?: 0
                        handleSetDnd(enable, startH, startM, endH, endM, result)
                    }
                    "setAlarm" -> {
                        val index = call.argument<Int>("index") ?: 0
                        val enable = call.argument<Boolean>("enable") ?: true
                        val hour = call.argument<Int>("hour") ?: 8
                        val minute = call.argument<Int>("minute") ?: 0
                        val weekMask = call.argument<Int>("weekMask") ?: 0x7F
                        handleSetAlarm(index, enable, hour, minute, weekMask, result)
                    }
                    "readAlarms" -> handleReadAlarms(result)
                    "syncSleep" -> handleSyncSleep(result)
                    "getLastVitalValues" -> handleGetLastVitalValues(result)
                    "startContinuousMeasurement" -> handleStartContinuousMeasurement(result)
                    "stopContinuousMeasurement" -> handleStopContinuousMeasurement(result)
                    else -> result.notImplemented()
                }
            }
    }

    // ── Scan (Native Android BLE – bypasses SDK name filter) ──

    private fun handleScan(result: MethodChannel.Result) {
        val devices = mutableListOf<Map<String, Any?>>()
        var resultSent = false

        val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val adapter = bluetoothManager?.adapter
        if (adapter == null) {
            Log.e(TAG, "BluetoothAdapter is null – no BLE hardware?")
            result.error("BLE_UNAVAILABLE", "Bluetooth adapter not available", null)
            return
        }
        if (!adapter.isEnabled) {
            Log.e(TAG, "Bluetooth is OFF")
            result.error("BLE_OFF", "Bluetooth is turned off. Please enable Bluetooth.", null)
            return
        }
        val scanner = adapter.bluetoothLeScanner
        if (scanner == null) {
            Log.e(TAG, "BluetoothLeScanner is null – BLE off or not supported")
            result.error("BLE_UNAVAILABLE", "BLE scanner not available. Is Bluetooth on?", null)
            return
        }

        Log.d(TAG, "Starting native BLE scan...")

        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, sr: ScanResult) {
                val address = sr.device?.address ?: return
                val name = sr.device?.name ?: sr.scanRecord?.deviceName ?: address
                Log.d(TAG, "onScanResult: name=$name addr=$address rssi=${sr.rssi}")
                val entry = mapOf<String, Any?>(
                    "id" to address,
                    "name" to name,
                    "rssi" to sr.rssi
                )
                synchronized(devices) {
                    if (devices.none { it["id"] == address }) {
                        devices.add(entry)
                    }
                }
            }

            override fun onBatchScanResults(results: MutableList<ScanResult>?) {
                Log.d(TAG, "onBatchScanResults: ${results?.size ?: 0} results")
                results?.forEach { sr ->
                    val address = sr.device?.address ?: return@forEach
                    val name = sr.device?.name ?: sr.scanRecord?.deviceName ?: address
                    val entry = mapOf<String, Any?>(
                        "id" to address,
                        "name" to name,
                        "rssi" to sr.rssi
                    )
                    synchronized(devices) {
                        if (devices.none { it["id"] == address }) {
                            devices.add(entry)
                        }
                    }
                }
            }

            override fun onScanFailed(errorCode: Int) {
                Log.e(TAG, "Native BLE scan failed with error: $errorCode")
                if (!resultSent) {
                    resultSent = true
                    val errMsg = when (errorCode) {
                        1 -> "SCAN_FAILED_ALREADY_STARTED"
                        2 -> "SCAN_FAILED_APPLICATION_REGISTRATION_FAILED"
                        3 -> "SCAN_FAILED_INTERNAL_ERROR"
                        4 -> "SCAN_FAILED_FEATURE_UNSUPPORTED"
                        5 -> "SCAN_FAILED_OUT_OF_HARDWARE_RESOURCES"
                        6 -> "SCAN_FAILED_SCANNING_TOO_FREQUENTLY"
                        else -> "UNKNOWN_ERROR_$errorCode"
                    }
                    mainHandler.post { result.error("SCAN_FAILED", errMsg, null) }
                }
            }
        }

        activeScanCallback = callback

        try {
            scanner.startScan(callback)
            Log.d(TAG, "Native BLE scan started")
        } catch (e: SecurityException) {
            Log.e(TAG, "BLE scan SecurityException – missing permissions?", e)
            result.error("PERMISSION_ERROR", "BLE scan requires location/bluetooth permissions: ${e.message}", null)
            return
        } catch (e: Exception) {
            Log.e(TAG, "BLE scan start failed", e)
            result.error("SCAN_ERROR", e.message, null)
            return
        }

        // Stop scan and return results after 12 seconds
        mainHandler.postDelayed({
            try {
                scanner.stopScan(callback)
                Log.d(TAG, "Native BLE scan stopped. Found ${devices.size} devices")
            } catch (_: Exception) {}
            activeScanCallback = null
            if (!resultSent) {
                resultSent = true
                result.success(devices)
            }
        }, 12000)
    }

    // ── Connect — waits for onServiceDiscovered before reporting success ──

    private fun handleConnect(deviceId: String, result: MethodChannel.Result) {
        Log.d(TAG, "handleConnect: deviceId=$deviceId")

        // Already connected and ready — return success immediately
        if (connectedDeviceId == deviceId && serviceReady && bleManager.isConnected) {
            Log.d(TAG, "Already connected to $deviceId with serviceReady — returning success")
            result.success(true)
            return
        }

        // If there's a pending connect result, fail it before starting a new one
        pendingConnectResult?.let { old ->
            Log.w(TAG, "Replacing pending connect result — failing old one")
            connectTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
            connectTimeoutRunnable = null
            try { old.error("CONNECT_REPLACED", "New connect request replaced this one", null) } catch (_: Exception) {}
        }

        try {
            serviceReady = false
            pendingConnectResult = result
            pendingConnectDeviceId = deviceId
            connectedDeviceId = deviceId

            // Set reconnect MAC
            bleManager.reConnectMac = deviceId

            // Connect directly by MAC
            bleManager.connectDirectly(deviceId)
            Log.d(TAG, "connectDirectly($deviceId) called, waiting for onServiceDiscovered...")

            // Timeout — if onServiceDiscovered doesn't fire within 25s
            val timeout = Runnable {
                if (pendingConnectResult != null) {
                    Log.e(TAG, "Connection timeout — onServiceDiscovered not received in 25s")
                    pendingConnectResult?.error(
                        "CONNECT_TIMEOUT",
                        "Could not connect to $deviceId within 25s. Make sure bracelet is awake and nearby.",
                        null
                    )
                    pendingConnectResult = null
                    pendingConnectDeviceId = null
                    connectedDeviceId = null
                }
            }
            connectTimeoutRunnable = timeout
            mainHandler.postDelayed(timeout, 25000)

        } catch (e: Exception) {
            Log.e(TAG, "Connect failed", e)
            pendingConnectResult = null
            pendingConnectDeviceId = null
            connectedDeviceId = null
            result.error("CONNECT_ERROR", e.message, null)
        }
    }

    // ── Disconnect ──

    private fun handleDisconnect(result: MethodChannel.Result) {
        try {
            bleManager.unBindDevice()
            val id = connectedDeviceId
            connectedDeviceId = null
            serviceReady = false
            mainHandler.post {
                if (id != null) {
                    connSink?.success(mapOf("deviceId" to id, "connected" to false))
                }
                result.success(true)
            }
        } catch (e: Exception) {
            result.error("DISCONNECT_ERROR", e.message, null)
        }
    }

    // ── Read Metrics ──

    private fun handleReadMetrics(deviceId: String, result: MethodChannel.Result) {
        Log.d(TAG, "readMetrics: isConnected=${bleManager.isConnected} serviceReady=$serviceReady")

        if (!bleManager.isConnected || !serviceReady) {
            Log.w(TAG, "readMetrics called but BLE not ready!")
            result.success(mapOf(
                "heartRate" to 0,
                "steps" to 0,
                "battery" to 0,
                "spo2" to null,
                "calories" to null
            ))
            return
        }

        val metrics = mutableMapOf<String, Any?>(
            "heartRate" to 0,
            "steps" to lastSteps,
            "battery" to 0,
            "spo2" to null,
            "calories" to if (lastCalories > 0) lastCalories else null
        )

        // Get battery
        try {
            CommandHandle.getInstance().executeReqCmd(
                SimpleKeyReq(Constants.CMD_GET_DEVICE_ELECTRICITY_VALUE)
            ) { rsp ->
                Log.d(TAG, "Battery rsp: status=${rsp.status}")
                if (rsp.status == BaseRspCmd.RESULT_OK) {
                    try {
                        val battRsp = rsp as? BatteryRsp
                        if (battRsp != null) {
                            metrics["battery"] = battRsp.batteryValue
                            Log.d(TAG, "Battery: ${battRsp.batteryValue}%")
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "Battery cast failed", e)
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Battery read failed", e)
        }

        // Get today steps
        try {
            CommandHandle.getInstance().executeReqCmd(
                SimpleKeyReq(Constants.CMD_GET_STEP_TODAY)
            ) { rsp ->
                Log.d(TAG, "Steps rsp: status=${rsp.status}")
                if (rsp.status == BaseRspCmd.RESULT_OK) {
                    try {
                        val stepsRsp = rsp as? TodaySportDataRsp
                        if (stepsRsp != null) {
                            val total = stepsRsp.sportTotal
                            if (total != null) {
                                lastSteps = total.totalSteps
                                lastCalories = total.calorie
                                metrics["steps"] = total.totalSteps
                                metrics["calories"] = total.calorie
                                diag("[READ_METRICS] steps=${total.totalSteps} calories=${total.calorie}")
                            }
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "Steps cast failed", e)
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Steps read failed", e)
        }

        // Return after a short delay to allow callbacks
        var replied = false
        mainHandler.postDelayed({
            if (!replied) {
                replied = true
                diag("[READ_METRICS] returning: $metrics")
                result.success(HashMap(metrics))
            }
        }, 2000)
    }

    // ── Diagnostic helper — logs to Logcat AND bridges to Flutter LogViewer ──
    private fun diag(msg: String) {
        Log.d(TAG, msg)
        mainHandler.post { diagSink?.success(msg) }
    }

    private fun bytesToInt(vararg bytes: Byte): Int {
        var result = 0
        for (byte in bytes) {
            result = (result shl 8) or (byte.toInt() and 0xFF)
        }
        return result
    }

    private fun isValidHr(value: Int): Boolean = value in 30..240
    private fun isValidSpo2(value: Int): Boolean = value in 70..100
    private fun isValidSbp(value: Int): Boolean = value in 70..240
    private fun isValidDbp(value: Int): Boolean = value in 40..140
    private fun isValidTempRaw(value: Int): Boolean = value in 300..450 || value in 85..115
    private fun isValidHrv(value: Int): Boolean = value in 5..250
    private fun isValidStress(value: Int): Boolean = value in 1..100

    private fun isNotificationAccessEnabled(): Boolean {
        return NotificationManagerCompat.getEnabledListenerPackages(context)
            .contains(context.packageName)
    }

    private fun openNotificationAccessSettings() {
        val intent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
    }

    fun pushIncomingCallNotification(title: String?, body: String?) {
        if (!serviceReady || !bleManager.isConnected || !callReminderEnabled) return
        try {
            val text = listOfNotNull(title, body)
                .joinToString(" ")
                .trim()
                .ifEmpty { "Incoming call" }
            MessPushUtil.pushMsg(PushMsgUintReq.TYPE_PHONE_RING.toInt(), text)
            Log.d(TAG, "pushIncomingCallNotification sent: $text")
        } catch (e: Exception) {
            Log.e(TAG, "pushIncomingCallNotification failed", e)
        }
    }

    fun pushIncomingMessageNotification(title: String?, body: String?) {
        if (!serviceReady || !bleManager.isConnected || !callReminderEnabled) return
        try {
            val text = listOfNotNull(title, body)
                .joinToString(" ")
                .trim()
                .ifEmpty { "New message" }
            MessPushUtil.pushMsg(PushMsgUintReq.TYPE_SMS.toInt(), text)
            Log.d(TAG, "pushIncomingMessageNotification sent: $text")
        } catch (e: Exception) {
            Log.e(TAG, "pushIncomingMessageNotification failed", e)
        }
    }

    private fun pushOneClickSamples(rsp: StopHeartRateRsp, source: String) {
        val hr = listOf(rsp.heartRate, rsp.heart, rsp.value).maxOrNull() ?: 0
        val spo2 = if (rsp.bloodOxygen in 70..100) rsp.bloodOxygen else if (rsp.value in 70..100) rsp.value else 0
        val sbp = rsp.sbp
        val dbp = rsp.dbp
        val temp = if (rsp.temperature > 0) rsp.temperature else rsp.value
        val hrv = rsp.hrv
        val stress = rsp.stress

        Log.d(
            TAG,
            "oneClick[$source]: err=${rsp.errCode} hr=$hr spo2=$spo2 bp=$sbp/$dbp temp=$temp hrv=$hrv stress=$stress"
        )

        if (isValidHr(hr)) {
            lastHr = hr
            mainHandler.post { hrSink?.success(hr) }
        }
        if (isValidSpo2(spo2)) {
            lastSpo2 = spo2
            mainHandler.post { spo2Sink?.success(spo2) }
        }
        if (isValidSbp(sbp) && isValidDbp(dbp)) {
            lastSbp = sbp; lastDbp = dbp
            mainHandler.post { bpSink?.success(mapOf("systolic" to sbp, "diastolic" to dbp)) }
        }
        if (temp in 300..450) {
            lastTempRaw = temp
            mainHandler.post { tempSink?.success(temp) }
        }
        if (isValidHrv(hrv)) {
            lastHrv = hrv
            mainHandler.post { hrvSink?.success(hrv) }
        }
        if (isValidStress(stress)) {
            lastStress = stress
            mainHandler.post { stressSink?.success(stress) }
        }
    }

    private fun startOneClickFallback(source: String) {
        if (oneClickRunning) return
        try {
            oneClickRunning = true
            bleManager.oneClickMeasurement({ rsp ->
                pushOneClickSamples(rsp, source)
            }, false)
            Log.d(TAG, "oneClick fallback started from $source")
        } catch (e: Exception) {
            oneClickRunning = false
            Log.e(TAG, "oneClick fallback start failed ($source)", e)
        }
    }

    private fun stopOneClickFallback(source: String) {
        if (!oneClickRunning) return
        try {
            bleManager.oneClickMeasurement({ rsp ->
                pushOneClickSamples(rsp, "${source}_stop")
            }, true)
            Log.d(TAG, "oneClick fallback stopped from $source")
        } catch (e: Exception) {
            Log.e(TAG, "oneClick fallback stop failed ($source)", e)
        } finally {
            oneClickRunning = false
        }
    }

    // ── Continuous Measurement (uses oneClick as sole method) ──

    private fun handleStartContinuousMeasurement(result: MethodChannel.Result) {
        Log.d(TAG, "startContinuous: isConnected=${bleManager.isConnected} serviceReady=$serviceReady oneClickRunning=$oneClickRunning")
        if (!bleManager.isConnected || !serviceReady) {
            result.error("NOT_CONNECTED", "Device not connected or service not ready", null)
            return
        }
        if (oneClickRunning) {
            Log.d(TAG, "startContinuous: already running")
            result.success(null)
            return
        }
        try {
            oneClickRunning = true
            // Reset cached values so fresh data is detected
            lastHr = 0; lastSpo2 = 0; lastSbp = 0; lastDbp = 0
            lastTempRaw = 0; lastHrv = 0; lastStress = 0
            bleManager.oneClickMeasurement({ rsp ->
                pushOneClickSamples(rsp, "continuous")
            }, false)
            Log.d(TAG, "startContinuous: oneClick started successfully")
            result.success(null)
        } catch (e: Exception) {
            oneClickRunning = false
            Log.e(TAG, "startContinuous failed", e)
            result.error("MEASUREMENT_ERROR", e.message, null)
        }
    }

    private fun handleStopContinuousMeasurement(result: MethodChannel.Result) {
        Log.d(TAG, "stopContinuous: oneClickRunning=$oneClickRunning")
        if (!oneClickRunning) {
            result.success(null)
            return
        }
        try {
            bleManager.oneClickMeasurement({ rsp ->
                pushOneClickSamples(rsp, "continuous_stop")
            }, true)
            Log.d(TAG, "stopContinuous: oneClick stopped")
        } catch (e: Exception) {
            Log.e(TAG, "stopContinuous failed", e)
        } finally {
            oneClickRunning = false
        }
        result.success(null)
    }

    // ── Heart Rate — matches SDK sample: manualModeHeart with value/errCode ──

    private fun handleStartHr(deviceId: String, result: MethodChannel.Result) {
        Log.d(TAG, "startHR: isConnected=${bleManager.isConnected} serviceReady=$serviceReady")

        if (!bleManager.isConnected || !serviceReady) {
            Log.w(TAG, "startHR called but BLE not ready!")
            result.error("NOT_CONNECTED", "Device not connected or service not ready", null)
            return
        }

        try {
            // Manual HR callbacks on this firmware report only zeros.
            // oneClickMeasurement returns heartRate/heart/hrv/stress reliably in StopHeartRateRsp.
            startOneClickFallback("hr")
            diag("[HR] start via oneClickMeasurement")
            mainHandler.post { result.success(null) }
        } catch (e: Exception) {
            Log.e(TAG, "startHR failed", e)
            result.error("HR_START_ERROR", e.message, null)
        }
    }

    private fun handleStopHr(deviceId: String, result: MethodChannel.Result) {
        try {
            stopOneClickFallback("hr")
            diag("[HR] stopped via oneClickMeasurement")
            mainHandler.post { result.success(null) }
        } catch (e: Exception) {
            result.error("HR_STOP_ERROR", e.message, null)
        }
    }

    // ── Sync Time ──

    private fun handleSyncTime(result: MethodChannel.Result) {
        syncTimeInternal()
        result.success(true)
    }

    private fun syncTimeInternal() {
        try {
            CommandHandle.getInstance().executeReqCmd(SetTimeReq(0)) { rsp ->
                Log.d(TAG, "Time synced: status=${rsp.status}")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Sync time failed", e)
        }
    }

    // ── Battery ──

    private fun handleGetBattery(result: MethodChannel.Result) {
        if (!serviceReady) {
            result.success(0)
            return
        }
        var replied = false
        try {
            CommandHandle.getInstance().executeReqCmd(
                SimpleKeyReq(Constants.CMD_GET_DEVICE_ELECTRICITY_VALUE)
            ) { rsp ->
                if (replied) return@executeReqCmd
                replied = true
                if (rsp.status == BaseRspCmd.RESULT_OK) {
                    val battRsp = rsp as? BatteryRsp
                    mainHandler.post { result.success(battRsp?.batteryValue ?: 0) }
                } else {
                    mainHandler.post { result.success(0) }
                }
            }
            // Timeout fallback
            mainHandler.postDelayed({
                if (!replied) {
                    replied = true
                    result.success(0)
                }
            }, 3000)
        } catch (e: Exception) {
            if (!replied) {
                replied = true
                result.error("BATTERY_ERROR", e.message, null)
            }
        }
    }

    // ── HR Interval Setting ──

    private fun handleSetHrInterval(enable: Boolean, interval: Int, result: MethodChannel.Result) {
        if (!serviceReady) {
            result.success(false)
            return
        }
        try {
            CommandHandle.getInstance().executeReqCmd(
                HeartRateSettingReq.getWriteInstance(enable, interval)
            ) { rsp ->
                mainHandler.post { result.success(rsp.status == BaseRspCmd.RESULT_OK) }
            }
        } catch (e: Exception) {
            result.error("HR_INTERVAL_ERROR", e.message, null)
        }
    }

    // ── SpO2 — manual mode with real-time callback ──

    private fun handleStartSpO2(deviceId: String, result: MethodChannel.Result) {
        Log.d(TAG, "startSpO2: isConnected=${bleManager.isConnected} serviceReady=$serviceReady")
        if (!bleManager.isConnected || !serviceReady) {
            result.error("NOT_CONNECTED", "Device not connected or service not ready", null)
            return
        }
        try {
            bleManager.manualModeSpO2({ rsp ->
                val spo2 = listOf(rsp.bloodOxygen, rsp.value).maxOrNull() ?: 0
                Log.d(TAG, "SpO2 callback: errCode=${rsp.errCode} value=${rsp.value} bloodOxygen=${rsp.bloodOxygen} => spo2=$spo2")
                if (isValidSpo2(spo2)) {
                    lastSpo2 = spo2
                    mainHandler.post { spo2Sink?.success(spo2) }
                }
            }, false)
            // No oneClick fallback — it interferes with manual SpO2 mode
            mainHandler.post { result.success(null) }
        } catch (e: Exception) {
            Log.e(TAG, "startSpO2 failed", e)
            result.error("SPO2_START_ERROR", e.message, null)
        }
    }

    private fun handleStopSpO2(deviceId: String, result: MethodChannel.Result) {
        try {
            bleManager.manualModeSpO2({ rsp ->
                Log.d(TAG, "SpO2 stopped: errCode=${rsp.errCode}")
            }, true)
            mainHandler.post { result.success(null) }
        } catch (e: Exception) {
            result.error("SPO2_STOP_ERROR", e.message, null)
        }
    }

    // ── Blood Pressure — manual mode with real-time callback ──

    private fun handleStartBP(deviceId: String, result: MethodChannel.Result) {
        Log.d(TAG, "startBP: isConnected=${bleManager.isConnected} serviceReady=$serviceReady")
        if (!bleManager.isConnected || !serviceReady) {
            result.error("NOT_CONNECTED", "Device not connected or service not ready", null)
            return
        }
        try {
            bleManager.manualModeBP({ rsp ->
                // bpRunnable fires after 30s via shared bleManager.response — may call wrong
                // callback when rotation overwrites it. Direct field polling below is reliable.
                Log.d(TAG, "BP callback: errCode=${rsp.errCode}")
            }, false)
            // Poll bleManager.sbp/dbp directly with unsigned byte conversion after ring measurement
            bpPollRunnable?.let { mainHandler.removeCallbacks(it) }
            val bpPoll = Runnable {
                val sbp = bleManager.sbp.toInt() and 0xFF
                val dbp = bleManager.dbp.toInt() and 0xFF
                Log.d(TAG, "BP direct poll: sbp=$sbp dbp=$dbp")
                if (isValidSbp(sbp) && isValidDbp(dbp)) {
                    lastSbp = sbp; lastDbp = dbp
                    mainHandler.post { bpSink?.success(mapOf("systolic" to sbp, "diastolic" to dbp)) }
                }
            }
            bpPollRunnable = bpPoll
            mainHandler.postDelayed(bpPoll, 25000)
            mainHandler.post { result.success(null) }
        } catch (e: Exception) {
            Log.e(TAG, "startBP failed", e)
            result.error("BP_START_ERROR", e.message, null)
        }
    }

    private fun handleStopBP(deviceId: String, result: MethodChannel.Result) {
        try {
            bpPollRunnable?.let { mainHandler.removeCallbacks(it) }
            bpPollRunnable = null
            // Capture BP value immediately before stopping
            val sbp = bleManager.sbp.toInt() and 0xFF
            val dbp = bleManager.dbp.toInt() and 0xFF
            if (isValidSbp(sbp) && isValidDbp(dbp)) {
                lastSbp = sbp; lastDbp = dbp
                mainHandler.post { bpSink?.success(mapOf("systolic" to sbp, "diastolic" to dbp)) }
            }
            bleManager.manualModeBP({ rsp ->
                Log.d(TAG, "BP stopped: errCode=${rsp.errCode}")
            }, true)
            mainHandler.post { result.success(null) }
        } catch (e: Exception) {
            result.error("BP_STOP_ERROR", e.message, null)
        }
    }

    // ── Temperature — manual mode with real-time callback ──

    private fun handleStartTemp(deviceId: String, result: MethodChannel.Result) {
        Log.d(TAG, "startTemp: isConnected=${bleManager.isConnected} serviceReady=$serviceReady")
        if (!bleManager.isConnected || !serviceReady) {
            result.error("NOT_CONNECTED", "Device not connected or service not ready", null)
            return
        }
        try {
            bleManager.manualTemperature({ rsp ->
                // QC docs: manualTemperature returns Celsius*10 in rsp.value.
                val tempFromRsp = rsp.value
                val tempDirect  = bleManager.temperature
                diag("[TEMP] cb: errCode=${rsp.errCode} rsp.value=$tempFromRsp bleManager.temperature=$tempDirect")
                val raw = when {
                    isValidTempRaw(tempFromRsp) -> tempFromRsp
                    tempDirect in 300..450 -> tempDirect
                    else -> 0
                }
                if (raw > 0) {
                    lastTempRaw = raw
                    tempPollActive = false  // got a reading via callback — stop polling
                    mainHandler.post { tempSink?.success(raw) }
                }
            }, false)
            // Repeating 5s poll of bleManager.temperature (set by SDK before callback fires).
            // Stops automatically once a valid reading is found.
            tempPollActive = true
            tempPollRunnable?.let { mainHandler.removeCallbacks(it) }
            val pollTask = object : Runnable {
                override fun run() {
                    if (!tempPollActive) return
                    val tempRaw = bleManager.temperature
                    diag("[TEMP] poll: bleManager.temperature=$tempRaw (valid=${isValidTempRaw(tempRaw)})")
                    if (tempRaw in 300..450) {
                        lastTempRaw = tempRaw
                        tempPollActive = false
                        mainHandler.post { tempSink?.success(tempRaw) }
                        return
                    }
                    mainHandler.postDelayed(this, 5000)
                }
            }
            tempPollRunnable = pollTask
            mainHandler.postDelayed(pollTask, 5000)
            mainHandler.post { result.success(null) }
        } catch (e: Exception) {
            Log.e(TAG, "startTemp failed", e)
            result.error("TEMP_START_ERROR", e.message, null)
        }
    }

    private fun handleStopTemp(deviceId: String, result: MethodChannel.Result) {
        try {
            tempPollActive = false
            tempPollRunnable?.let { mainHandler.removeCallbacks(it) }
            tempPollRunnable = null
            // Final read — might have a value even if poll hadn't fired yet
            val tempRaw = bleManager.temperature
            diag("[TEMP] stopTemp: final bleManager.temperature=$tempRaw lastTempRaw=$lastTempRaw")
            if (isValidTempRaw(tempRaw) && tempRaw != lastTempRaw) {
                lastTempRaw = tempRaw
                mainHandler.post { tempSink?.success(tempRaw) }
            }
            bleManager.manualTemperature({ rsp ->
                diag("[TEMP] stopped: errCode=${rsp.errCode}")
            }, true)
            mainHandler.post { result.success(null) }
        } catch (e: Exception) {
            result.error("TEMP_STOP_ERROR", e.message, null)
        }
    }

    // ── HRV — manual mode with real-time callback ──

    private fun handleStartHrv(deviceId: String, result: MethodChannel.Result) {
        Log.d(TAG, "startHrv: isConnected=${bleManager.isConnected} serviceReady=$serviceReady")
        if (!bleManager.isConnected || !serviceReady) {
            result.error("NOT_CONNECTED", "Device not connected or service not ready", null)
            return
        }
        try {
            // Manual HRV callbacks on this firmware report zero in both value and hrv.
            // oneClickMeasurement returns hrv/stress in StopHeartRateRsp.
            startOneClickFallback("hrv")
            diag("[HRV] start via oneClickMeasurement")
            mainHandler.post { result.success(null) }
        } catch (e: Exception) {
            Log.e(TAG, "startHrv failed", e)
            result.error("HRV_START_ERROR", e.message, null)
        }
    }

    private fun handleStopHrv(deviceId: String, result: MethodChannel.Result) {
        try {
            stopOneClickFallback("hrv")
            diag("[HRV] stopped via oneClickMeasurement")
            mainHandler.post { result.success(null) }
        } catch (e: Exception) {
            result.error("HRV_STOP_ERROR", e.message, null)
        }
    }

    // ── Check Now — starts all manual measurements, collects results via callbacks ──

    private fun handleCheckNow(deviceId: String, result: MethodChannel.Result) {
        Log.d(TAG, "checkNow: isConnected=${bleManager.isConnected} serviceReady=$serviceReady")

        if (!bleManager.isConnected || !serviceReady) {
            result.success(mapOf<String, Any?>())
            return
        }

        val collected = mutableMapOf<String, Any?>()
        var replied = false

        // Bracelet only supports ONE manual mode at a time.
        // Run them SEQUENTIALLY: HR (12s) → SpO2 (12s) → HRV+Stress (12s)
        // Total: ~36 seconds.

        // Battery + Steps first (command-response, instant)
        try {
            CommandHandle.getInstance().executeReqCmd(
                SimpleKeyReq(Constants.CMD_GET_DEVICE_ELECTRICITY_VALUE)
            ) { rsp ->
                if (rsp.status == BaseRspCmd.RESULT_OK) {
                    val battRsp = rsp as? BatteryRsp
                    if (battRsp != null) collected["battery"] = battRsp.batteryValue
                }
            }
        } catch (e: Exception) { Log.e(TAG, "checkNow battery failed", e) }

        try {
            CommandHandle.getInstance().executeReqCmd(
                SimpleKeyReq(Constants.CMD_GET_STEP_TODAY)
            ) { rsp ->
                if (rsp.status == BaseRspCmd.RESULT_OK) {
                    val stepsRsp = rsp as? TodaySportDataRsp
                    val total = stepsRsp?.sportTotal
                    if (total != null) {
                        collected["steps"] = total.totalSteps
                        collected["calories"] = total.calorie
                    }
                }
            }
        } catch (e: Exception) { Log.e(TAG, "checkNow steps failed", e) }

        // Phase 1: Heart Rate + Blood Pressure (12 seconds)
        try {
            bleManager.manualModeHeart({ rsp ->
                // Try all HR fields — SDK may populate heartRate, heart, or value depending on firmware
                val hrFromHeartRate = rsp.heartRate
                val hrFromHeart = rsp.heart
                val hrFromValue = rsp.value and 0xFF
                val hr = listOf(hrFromHeartRate, hrFromHeart, hrFromValue)
                    .filter { it in 30..240 }.maxOrNull() ?: 0
                val sbp = rsp.sbp
                val dbp = rsp.dbp
                diag("[CHECKNOW/HR] errCode=${rsp.errCode} heartRate=$hrFromHeartRate heart=$hrFromHeart value=${rsp.value}\u2192$hrFromValue sbp=$sbp dbp=$dbp => hr=$hr")
                if (hr > 0 && !collected.containsKey("heartRate")) {
                    collected["heartRate"] = hr
                    lastHr = hr
                    mainHandler.post { hrSink?.success(hr) }
                }
                if (isValidSbp(sbp) && isValidDbp(dbp) && !collected.containsKey("systolic")) {
                    collected["systolic"] = sbp
                    collected["diastolic"] = dbp
                    lastSbp = sbp; lastDbp = dbp
                    mainHandler.post { bpSink?.success(mapOf("systolic" to sbp, "diastolic" to dbp)) }
                }
            }, false)
        } catch (e: Exception) { Log.e(TAG, "checkNow HR phase failed", e) }

        // Phase 2: SpO2 (starts at 12s, runs until 24s)
        mainHandler.postDelayed({
            diag("[CHECKNOW] phase 2: starting SpO2")
            try {
                bleManager.manualModeSpO2({ rsp ->
                    val spo2 = listOf(rsp.bloodOxygen, rsp.value).maxOrNull() ?: 0
                    diag("[CHECKNOW/SpO2] errCode=${rsp.errCode} bloodOxygen=${rsp.bloodOxygen} value=${rsp.value} => spo2=$spo2")
                    if (isValidSpo2(spo2) && !collected.containsKey("spo2")) {
                        collected["spo2"] = spo2
                        lastSpo2 = spo2
                        mainHandler.post { spo2Sink?.success(spo2) }
                    }
                }, false)
            } catch (e: Exception) { Log.e(TAG, "checkNow SpO2 phase failed", e) }
        }, 12000)

        // Phase 3: HRV + Stress (starts at 24s, runs until 36s)
        mainHandler.postDelayed({
            diag("[CHECKNOW] phase 3: starting HRV")
            try {
                bleManager.manualModeHrv({ rsp ->
                    val hrvFromValue = rsp.value
                    val hrvFromField = rsp.hrv
                    val hrv = when {
                        hrvFromValue in 5..250 -> hrvFromValue
                        hrvFromField in 5..250 -> hrvFromField
                        else -> 0
                    }
                    val stress = bleManager.pressure.toInt() and 0xFF
                    diag("[CHECKNOW/HRV] errCode=${rsp.errCode} value=$hrvFromValue hrv=$hrvFromField => hrv=$hrv | pressure=${bleManager.pressure}\u2192stress=$stress")
                    if (hrv > 0 && !collected.containsKey("hrv")) {
                        collected["hrv"] = hrv
                        lastHrv = hrv
                        mainHandler.post { hrvSink?.success(hrv) }
                    }
                    if (isValidStress(stress) && !collected.containsKey("stress")) {
                        collected["stress"] = stress
                        lastStress = stress
                        mainHandler.post { stressSink?.success(stress) }
                    }
                }, false)
            } catch (e: Exception) { Log.e(TAG, "checkNow HRV phase failed", e) }
        }, 24000)

        // Return collected results after 36 seconds
        mainHandler.postDelayed({
            if (!replied) {
                replied = true
                diag("[CHECKNOW] done: $collected")
                result.success(HashMap(collected))
            }
        }, 36000)
    }

    // ── Find Device — makes bracelet vibrate/beep ──

    private fun handleFindDevice(result: MethodChannel.Result) {
        if (!serviceReady) { result.success(false); return }
        try {
            CommandHandle.getInstance().executeReqCmd(FindDeviceReq()) { rsp ->
                Log.d(TAG, "FindDevice: status=${rsp.status}")
            }
            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "findDevice failed", e)
            result.error("FIND_ERROR", e.message, null)
        }
    }

    // ── Camera Control ──

    private fun handleEnterCamera(result: MethodChannel.Result) {
        if (!serviceReady) { result.success(false); return }
        try {
            CommandHandle.getInstance().executeReqCmd(CameraReq(CameraReq.ACTION_INTO_CAMARA_UI)) { rsp ->
                Log.d(TAG, "EnterCamera: status=${rsp.status}")
            }
            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "enterCamera failed", e)
            result.error("CAMERA_ERROR", e.message, null)
        }
    }

    private fun handleExitCamera(result: MethodChannel.Result) {
        if (!serviceReady) { result.success(false); return }
        try {
            CommandHandle.getInstance().executeReqCmd(CameraReq(CameraReq.ACTION_FINISH)) { rsp ->
                Log.d(TAG, "ExitCamera: status=${rsp.status}")
            }
            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "exitCamera failed", e)
            result.error("CAMERA_ERROR", e.message, null)
        }
    }

    // ── Call Reminder (ANCS) ──

    private fun handleSetCallReminder(enable: Boolean, result: MethodChannel.Result) {
        if (!serviceReady) { result.success(false); return }
        var replied = false
        try {
            CommandHandle.getInstance().executeReqCmd(BindAncsReq()) { bindRsp ->
                Log.d(TAG, "BindANCS: status=${bindRsp.status}")
                val req = SetANCSReq()
                req.setCall(enable)
                req.setSms(enable)
                CommandHandle.getInstance().executeReqCmd(req) { rsp ->
                    Log.d(TAG, "SetCallReminder($enable): status=${rsp.status}")
                    if (!replied) {
                        replied = true
                        val ok = rsp.status == BaseRspCmd.RESULT_OK
                        if (ok) {
                            callReminderEnabled = enable
                        }
                        mainHandler.post { result.success(ok) }
                    }
                }
            }

            mainHandler.postDelayed({
                if (!replied) {
                    replied = true
                    callReminderEnabled = enable
                    result.success(true)
                }
            }, 5000)
        } catch (e: Exception) {
            Log.e(TAG, "setCallReminder failed", e)
            if (!replied) { replied = true; result.error("ANCS_ERROR", e.message, null) }
        }
    }

    // ── Sedentary Reminder ──

    private fun handleSetSedentaryReminder(
        enable: Boolean, interval: Int,
        startH: Int, startM: Int, endH: Int, endM: Int,
        result: MethodChannel.Result
    ) {
        if (!serviceReady) { result.success(false); return }
        var replied = false
        try {
            val time = StartEndTimeEntity(startH, startM, endH, endM)
            val enableByte: Byte = if (enable) 1 else 0
            CommandHandle.getInstance().executeReqCmd(
                SetSitLongReq(time, enableByte, interval)
            ) { rsp ->
                Log.d(TAG, "SetSedentary($enable, ${interval}min): status=${rsp.status}")
                if (!replied) {
                    replied = true
                    mainHandler.post { result.success(rsp.status == BaseRspCmd.RESULT_OK) }
                }
            }
            mainHandler.postDelayed({
                if (!replied) {
                    replied = true
                    result.success(true)
                }
            }, 5000)
        } catch (e: Exception) {
            Log.e(TAG, "setSedentaryReminder failed", e)
            if (!replied) { replied = true; result.error("SEDENTARY_ERROR", e.message, null) }
        }
    }

    // ── Do Not Disturb ──

    private fun handleSetDnd(
        enable: Boolean, startH: Int, startM: Int, endH: Int, endM: Int,
        result: MethodChannel.Result
    ) {
        if (!serviceReady) { result.success(false); return }
        var replied = false
        try {
            val time = StartEndTimeEntity(startH, startM, endH, endM)
            CommandHandle.getInstance().executeReqCmd(
                DndReq.getWriteInstance(enable, time)
            ) { rsp ->
                Log.d(TAG, "SetDND($enable): status=${rsp.status}")
                if (!replied) {
                    replied = true
                    mainHandler.post { result.success(rsp.status == BaseRspCmd.RESULT_OK) }
                }
            }
            mainHandler.postDelayed({
                if (!replied) { replied = true; result.success(true) }
            }, 5000)
        } catch (e: Exception) {
            Log.e(TAG, "setDnd failed", e)
            if (!replied) { replied = true; result.error("DND_ERROR", e.message, null) }
        }
    }

    // ── Alarm ──

    private fun handleSetAlarm(
        index: Int, enable: Boolean, hour: Int, minute: Int, weekMask: Int,
        result: MethodChannel.Result
    ) {
        if (!serviceReady) { result.success(false); return }
        var replied = false
        try {
            val enableInt = if (enable) 1 else 0
            val alarm = AlarmEntity(index, enableInt, hour, minute, weekMask.toByte())
            CommandHandle.getInstance().executeReqCmd(SetAlarmReq(alarm)) { rsp ->
                Log.d(TAG, "SetAlarm(idx=$index, $hour:$minute, enable=$enable): status=${rsp.status}")
                if (!replied) {
                    replied = true
                    mainHandler.post { result.success(rsp.status == BaseRspCmd.RESULT_OK) }
                }
            }
            mainHandler.postDelayed({
                if (!replied) { replied = true; result.success(true) }
            }, 5000)
        } catch (e: Exception) {
            Log.e(TAG, "setAlarm failed", e)
            if (!replied) { replied = true; result.error("ALARM_ERROR", e.message, null) }
        }
    }

    private fun handleReadAlarms(result: MethodChannel.Result) {
        if (!serviceReady) { result.success(listOf<Map<String, Any>>()); return }
        var replied = false
        try {
            CommandHandle.getInstance().executeReqCmd(ReadAlarmReq(1)) { rsp ->
                if (replied) return@executeReqCmd
                replied = true
                Log.d(TAG, "ReadAlarms: status=${rsp.status}")
                // Return empty list — alarm data parsing requires further work
                mainHandler.post { result.success(listOf<Map<String, Any>>()) }
            }
            mainHandler.postDelayed({
                if (!replied) { replied = true; result.success(listOf<Map<String, Any>>()) }
            }, 3000)
        } catch (e: Exception) {
            if (!replied) { replied = true; result.error("ALARM_ERROR", e.message, null) }
        }
    }

    // ── Get Last Vital Values (polling fallback) ──

    private fun handleGetLastVitalValues(result: MethodChannel.Result) {
        // Refresh temperature directly from SDK field (Celsius*10, e.g., 367 = 36.7°C)
        val sdkTemp = bleManager.temperature
        if (sdkTemp > 0 && isValidTempRaw(sdkTemp)) lastTempRaw = sdkTemp
        // Refresh BP directly from SDK fields with unsigned byte conversion
        val sdkSbp = bleManager.sbp.toInt() and 0xFF
        val sdkDbp = bleManager.dbp.toInt() and 0xFF
        if (isValidSbp(sdkSbp) && isValidDbp(sdkDbp)) { lastSbp = sdkSbp; lastDbp = sdkDbp }
        result.success(mapOf(
            "hr" to lastHr,
            "spo2" to lastSpo2,
            "sbp" to lastSbp,
            "dbp" to lastDbp,
            "temp" to lastTempRaw,
            "hrv" to lastHrv,
            "stress" to lastStress
        ))
    }

    // ── Sleep Sync ──

    private fun handleSyncSleep(result: MethodChannel.Result) {
        if (!serviceReady) { result.success(null); return }
        var replied = false
        try {
            LargeDataHandler.getInstance().syncSleepList(
                1, // totalDays = 1 (last night)
                object : ILargeDataSleepResponse {
                    override fun sleepData(display: SleepDisplay?) {
                        if (replied) return
                        replied = true
                        if (display == null) {
                            Log.d(TAG, "SyncSleep: no data")
                            mainHandler.post { result.success(null) }
                            return
                        }
                        Log.d(TAG, "SyncSleep: total=${display.totalSleepDuration}, deep=${display.deepSleepDuration}, light=${display.shallowSleepDuration}, rem=${display.rapidDuration}, awake=${display.awakeDuration}")
                        val segments = mutableListOf<Map<String, Any>>()
                        display.list?.forEach { bean ->
                            segments.add(mapOf(
                                "start" to bean.sleepStart,
                                "end" to bean.sleepEnd,
                                "type" to bean.type
                            ))
                        }
                        val map = hashMapOf<String, Any?>(
                            "totalSleep" to display.totalSleepDuration,
                            "deepSleep" to display.deepSleepDuration,
                            "lightSleep" to display.shallowSleepDuration,
                            "remSleep" to display.rapidDuration,
                            "awake" to display.awakeDuration,
                            "wakingCount" to display.wakingCount,
                            "sleepTime" to display.sleepTime,
                            "wakeTime" to display.wakeTime,
                            "segments" to segments
                        )
                        mainHandler.post { result.success(map) }
                    }
                },
                object : ILargeDataLaunchSleepResponse {
                    override fun sleepData(resp: SleepNewProtoResp?) {
                        // New protocol response — use as fallback if old callback doesn't fire
                        if (replied) return
                        replied = true
                        if (resp == null) {
                            mainHandler.post { result.success(null) }
                            return
                        }
                        Log.d(TAG, "SyncSleep(newProto): st=${resp.st}, et=${resp.et}")
                        val segments = mutableListOf<Map<String, Any>>()
                        resp.list?.forEach { bean ->
                            segments.add(mapOf(
                                "duration" to bean.d,
                                "type" to bean.t
                            ))
                        }
                        val map = hashMapOf<String, Any?>(
                            "totalSleep" to 0,
                            "deepSleep" to 0,
                            "lightSleep" to 0,
                            "remSleep" to 0,
                            "awake" to 0,
                            "wakingCount" to 0,
                            "sleepTime" to resp.st,
                            "wakeTime" to resp.et,
                            "segments" to segments
                        )
                        mainHandler.post { result.success(map) }
                    }
                }
            )
            // Timeout — 10s for sleep sync (large data transfer)
            mainHandler.postDelayed({
                if (!replied) { replied = true; result.success(null) }
            }, 10000)
        } catch (e: Exception) {
            Log.e(TAG, "syncSleep failed", e)
            if (!replied) { replied = true; result.error("SLEEP_ERROR", e.message, null) }
        }
    }

    // ────────────────────────────────────────────────────────────────
    //  EventChannels
    // ────────────────────────────────────────────────────────────────

    private fun setupHrEventChannel(engine: FlutterEngine) {
        EventChannel(engine.dartExecutor.binaryMessenger, HR_EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    hrSink = events
                    Log.d(TAG, "HR EventChannel: onListen")
                }
                override fun onCancel(arguments: Any?) {
                    hrSink = null
                    Log.d(TAG, "HR EventChannel: onCancel")
                }
            })
    }

    private fun setupConnEventChannel(engine: FlutterEngine) {
        EventChannel(engine.dartExecutor.binaryMessenger, CONN_EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    connSink = events
                    Log.d(TAG, "Connection EventChannel: onListen")
                }
                override fun onCancel(arguments: Any?) {
                    connSink = null
                    Log.d(TAG, "Connection EventChannel: onCancel")
                }
            })
    }

    private fun setupSpO2EventChannel(engine: FlutterEngine) {
        EventChannel(engine.dartExecutor.binaryMessenger, SPO2_EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    spo2Sink = events
                    Log.d(TAG, "SpO2 EventChannel: onListen")
                }
                override fun onCancel(arguments: Any?) {
                    spo2Sink = null
                    Log.d(TAG, "SpO2 EventChannel: onCancel")
                }
            })
    }

    private fun setupBpEventChannel(engine: FlutterEngine) {
        EventChannel(engine.dartExecutor.binaryMessenger, BP_EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    bpSink = events
                    Log.d(TAG, "BP EventChannel: onListen")
                }
                override fun onCancel(arguments: Any?) {
                    bpSink = null
                    Log.d(TAG, "BP EventChannel: onCancel")
                }
            })
    }

    private fun setupTempEventChannel(engine: FlutterEngine) {
        EventChannel(engine.dartExecutor.binaryMessenger, TEMP_EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    tempSink = events
                    Log.d(TAG, "Temp EventChannel: onListen")
                }
                override fun onCancel(arguments: Any?) {
                    tempSink = null
                    Log.d(TAG, "Temp EventChannel: onCancel")
                }
            })
    }

    private fun setupHrvEventChannel(engine: FlutterEngine) {
        EventChannel(engine.dartExecutor.binaryMessenger, HRV_EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    hrvSink = events
                    Log.d(TAG, "HRV EventChannel: onListen")
                }
                override fun onCancel(arguments: Any?) {
                    hrvSink = null
                    Log.d(TAG, "HRV EventChannel: onCancel")
                }
            })
    }

    private fun setupStressEventChannel(engine: FlutterEngine) {
        EventChannel(engine.dartExecutor.binaryMessenger, STRESS_EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    stressSink = events
                    Log.d(TAG, "Stress EventChannel: onListen")
                }
                override fun onCancel(arguments: Any?) {
                    stressSink = null
                    Log.d(TAG, "Stress EventChannel: onCancel")
                }
            })
    }

    private fun setupDiagEventChannel(engine: FlutterEngine) {
        EventChannel(engine.dartExecutor.binaryMessenger, DIAG_EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    diagSink = events
                    Log.d(TAG, "Diag EventChannel: onListen")
                }
                override fun onCancel(arguments: Any?) {
                    diagSink = null
                }
            })
    }

    // ────────────────────────────────────────────────────────────────
    //  Cleanup
    // ────────────────────────────────────────────────────────────────

    fun dispose() {
        try {
            bleManager.removeOthersListener()
            // Stop any active scan
            activeScanCallback?.let { cb ->
                val scanner = (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)
                    ?.adapter?.bluetoothLeScanner
                scanner?.stopScan(cb)
                activeScanCallback = null
            }
            // Unregister receivers
            LocalBroadcastManager.getInstance(app)
                .unregisterReceiver(bleCallbackReceiver)
            app.unregisterReceiver(bluetoothReceiver)
        } catch (_: Exception) {}
        hrSink = null
        connSink = null
        spo2Sink = null
        bpSink = null
        tempSink = null
        hrvSink = null
        stressSink = null
        diagSink = null
        connectedDeviceId = null
        serviceReady = false
        pendingConnectResult = null
        pendingConnectDeviceId = null
        activeInstance = null
    }
}
