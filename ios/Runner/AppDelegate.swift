import UIKit
import Flutter
import CoreBluetooth

// MARK: - AppDelegate

@UIApplicationMain
class AppDelegate: FlutterAppDelegate {

    // ── Flutter channels ──────────────────────────────────────────
    private let kMethodChannel  = "agp_sdk"
    private let kHrChannel      = "agp_sdk/hr_stream"
    private let kConnChannel    = "agp_sdk/conn_stream"
    private let kSpo2Channel    = "agp_sdk/spo2_stream"
    private let kBpChannel      = "agp_sdk/bp_stream"
    private let kTempChannel    = "agp_sdk/temp_stream"
    private let kHrvChannel     = "agp_sdk/hrv_stream"
    private let kStressChannel  = "agp_sdk/stress_stream"
    private let kDiagChannel    = "agp_sdk/diag_stream"

    // ── BLE (QCCentralManager from QCBandSDKDemo) ─────────────────
    private var scannedDevices: [[String: Any]] = []
    private var peripheralMap: [String: CBPeripheral] = [:]
    private var scanResultSent = false
    private var pendingScanResult: FlutterResult?
    private var scanTimer: Timer?

    // ── Connection state ──────────────────────────────────────────
    private var connectedDeviceId: String?
    private var connectedPeripheral: CBPeripheral?
    private var pendingConnectResult: FlutterResult?
    private var pendingConnectDeviceId: String?
    private var connectTimeoutTimer: Timer?
    private var serviceReady = false

    // ── Measurement state ─────────────────────────────────────────
    private var oneClickRunning = false
    private var oneClickContinuous = false
    private var callReminderEnabled = false

    // ── Cached vital values ───────────────────────────────────────
    private var lastHr = 0, lastSpo2 = 0, lastSbp = 0, lastDbp = 0
    private var lastTempRaw = 0, lastHrv = 0, lastStress = 0
    private var lastSteps = 0, lastCalories = 0

    // ── Event sinks ───────────────────────────────────────────────
    private var hrSink: FlutterEventSink?
    private var connSink: FlutterEventSink?
    private var spo2Sink: FlutterEventSink?
    private var bpSink: FlutterEventSink?
    private var tempSink: FlutterEventSink?
    private var hrvSink: FlutterEventSink?
    private var stressSink: FlutterEventSink?
    private var diagSink: FlutterEventSink?

    // ═════════════════════════════════════════════════════════════
    // MARK: - Application lifecycle
    // ═════════════════════════════════════════════════════════════

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let controller = window!.rootViewController as! FlutterViewController
        let messenger  = controller.binaryMessenger

        FlutterMethodChannel(name: kMethodChannel, binaryMessenger: messenger)
            .setMethodCallHandler { [weak self] call, result in
                self?.handleMethodCall(call, result: result)
            }

        FlutterEventChannel(name: kHrChannel,     binaryMessenger: messenger).setStreamHandler(makeHandler { [weak self] s in self?.hrSink = s })
        FlutterEventChannel(name: kConnChannel,   binaryMessenger: messenger).setStreamHandler(makeHandler { [weak self] s in self?.connSink = s })
        FlutterEventChannel(name: kSpo2Channel,   binaryMessenger: messenger).setStreamHandler(makeHandler { [weak self] s in self?.spo2Sink = s })
        FlutterEventChannel(name: kBpChannel,     binaryMessenger: messenger).setStreamHandler(makeHandler { [weak self] s in self?.bpSink = s })
        FlutterEventChannel(name: kTempChannel,   binaryMessenger: messenger).setStreamHandler(makeHandler { [weak self] s in self?.tempSink = s })
        FlutterEventChannel(name: kHrvChannel,    binaryMessenger: messenger).setStreamHandler(makeHandler { [weak self] s in self?.hrvSink = s })
        FlutterEventChannel(name: kStressChannel, binaryMessenger: messenger).setStreamHandler(makeHandler { [weak self] s in self?.stressSink = s })
        FlutterEventChannel(name: kDiagChannel,   binaryMessenger: messenger).setStreamHandler(makeHandler { [weak self] s in self?.diagSink = s })

        // QCBandSDK notification center (required for real-time vitals)
        OdmBandNotifyCenter.registerNotify()

        // BLE central manager from demo — handles scan/connect/reconnect/ANCS
        QCCentralManager.shared().delegate = self

        setupSdkCallbacks()
        registerNotificationObservers()

        GeneratedPluginRegistrant.register(with: self)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // ── SDK callbacks (block-based) ───────────────────────────────

    private func setupSdkCallbacks() {
        let sdk = QCSDKManager.shareInstance()!

        sdk.hrMeasuring = { [weak self] hr in
            guard let self = self else { return }
            let v = Int(hr)
            if self.isValidHr(v) {
                self.lastHr = v
                DispatchQueue.main.async { self.hrSink?(v) }
            }
        }

        sdk.realTimeHeartRate = { [weak self] hr in
            guard let self = self else { return }
            let v = Int(hr)
            if self.isValidHr(v) {
                self.lastHr = v
                DispatchQueue.main.async { self.hrSink?(v) }
            }
        }

        sdk.bpMeasuring = { [weak self] sbp, dbp in
            guard let self = self else { return }
            let s = Int(sbp), d = Int(dbp)
            if self.isValidSbp(s) && self.isValidDbp(d) {
                self.lastSbp = s; self.lastDbp = d
                DispatchQueue.main.async { self.bpSink?(["systolic": s, "diastolic": d]) }
            }
        }

        sdk.boMeasuring = { [weak self] so2 in
            guard let self = self else { return }
            let v = Int(so2)
            if self.isValidSpo2(v) {
                self.lastSpo2 = v
                DispatchQueue.main.async { self.spo2Sink?(v) }
            }
        }

        sdk.currentStepInfo = { [weak self] step, calorie, _ in
            guard let self = self else { return }
            self.lastSteps = Int(step)
            self.lastCalories = Int(calorie)
            self.diag("[STEP_NOTIFY] step=\(step) calorie=\(calorie)")
        }

        sdk.currentBatteryInfo = { [weak self] battery, _ in
            self?.diag("[BATTERY_NOTIFY] \(battery)%")
        }
    }

    // ── NSNotificationCenter observers ────────────────────────────

    private func registerNotificationObservers() {
        let nc = NotificationCenter.default

        nc.addObserver(forName: NSNotification.Name(OdmBandRealTimeHRV), object: nil, queue: .main) { [weak self] n in
            guard let self = self else { return }
            if let val = n.userInfo?[OdmHeartRateHRVKey] as? NSNumber {
                let hrv = val.intValue
                if self.isValidHrv(hrv) {
                    self.lastHrv = hrv
                    self.hrvSink?(hrv)
                }
            }
        }

        nc.addObserver(forName: NSNotification.Name(OdmBandRealTimeStress), object: nil, queue: .main) { [weak self] n in
            guard let self = self else { return }
            if let val = n.userInfo?[OdmStressKey] as? NSNumber {
                let stress = val.intValue
                if self.isValidStress(stress) {
                    self.lastStress = stress
                    self.stressSink?(stress)
                }
            }
        }

        nc.addObserver(forName: NSNotification.Name(OdmBandRealTimeBodyTemperature), object: nil, queue: .main) { [weak self] n in
            guard let self = self else { return }
            if let val = n.userInfo?[OdmTempKey] as? NSNumber {
                let t = val.intValue
                if self.isValidTempRaw(t) {
                    self.lastTempRaw = t
                    self.tempSink?(t)
                }
            }
        }

        nc.addObserver(forName: NSNotification.Name(OdmBandRealTimeSO2), object: nil, queue: .main) { [weak self] n in
            guard let self = self else { return }
            if let val = n.userInfo?[OdmValueKey] as? NSNumber {
                let spo2 = val.intValue
                if self.isValidSpo2(spo2) {
                    self.lastSpo2 = spo2
                    self.spo2Sink?(spo2)
                }
            }
        }

        nc.addObserver(forName: NSNotification.Name(OdmBandRealTimeSBP_DBP), object: nil, queue: .main) { [weak self] n in
            guard let self = self else { return }
            if let sbpN = n.userInfo?[OdmBandRealTimeSBPKey] as? NSNumber,
               let dbpN = n.userInfo?[OdmBandRealTimeDBPKey] as? NSNumber {
                let sbp = sbpN.intValue, dbp = dbpN.intValue
                if self.isValidSbp(sbp) && self.isValidDbp(dbp) {
                    self.lastSbp = sbp; self.lastDbp = dbp
                    self.bpSink?(["systolic": sbp, "diastolic": dbp])
                }
            }
        }

        nc.addObserver(forName: NSNotification.Name(OdmBandRealOneKeyMeasureHeartRate), object: nil, queue: .main) { [weak self] n in
            guard let self = self else { return }
            if let model = n.object as? QCRealOneKeyMeasureHeartRateModel {
                self.pushOneKeyModel(model, source: "notification")
            } else if let model = n.userInfo?["model"] as? QCRealOneKeyMeasureHeartRateModel {
                self.pushOneKeyModel(model, source: "notification_userInfo")
            }
        }
    }

    private func pushOneKeyModel(_ m: QCRealOneKeyMeasureHeartRateModel, source: String) {
        let hr = Int(m.heartRateValue)
        if isValidHr(hr) { lastHr = hr; hrSink?(hr) }

        let sbp = Int(m.bloodPressureSbp), dbp = Int(m.bloodPressureDbp)
        if isValidSbp(sbp) && isValidDbp(dbp) {
            lastSbp = sbp; lastDbp = dbp
            bpSink?(["systolic": sbp, "diastolic": dbp])
        }

        let temp = Int(m.temp)
        if isValidTempRaw(temp) { lastTempRaw = temp; tempSink?(temp) }

        let hrv = Int(m.heartRateHRV)
        if isValidHrv(hrv) { lastHrv = hrv; hrvSink?(hrv) }

        let stress = Int(m.stress)
        if isValidStress(stress) { lastStress = stress; stressSink?(stress) }

        diag("[ONEKEY/\(source)] hr=\(hr) bp=\(sbp)/\(dbp) temp=\(temp) hrv=\(hrv) stress=\(stress)")
    }

    private func diag(_ msg: String) {
        NSLog("[QcSdkPlugin] %@", msg)
        DispatchQueue.main.async { self.diagSink?(msg) }
    }

    // ── One-key measurement (matches Android oneClickMeasurement) ─

    private func startOneKeyFallback(source: String, continuous: Bool = false) {
        if oneClickRunning && !continuous { return }
        oneClickRunning = true
        oneClickContinuous = continuous
        diag("[ONEKEY] start from \(source) continuous=\(continuous)")
        startOneKeyMeasurement()
    }

    private func startOneKeyMeasurement() {
        QCSDKManager.shareInstance()?.startToMeasuringWithOperateType(
            .oneKeyMeasure,
            measuringHandle: { [weak self] result in
                guard let self = self else { return }
                if let model = result as? QCRealOneKeyMeasureHeartRateModel {
                    self.pushOneKeyModel(model, source: "measuringHandle")
                }
            },
            completedHandle: { [weak self] success, result, _ in
                guard let self = self else { return }
                if let model = result as? QCRealOneKeyMeasureHeartRateModel {
                    self.pushOneKeyModel(model, source: "completedHandle")
                }
                if self.oneClickContinuous && self.oneClickRunning && success {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        if self.oneClickRunning && self.oneClickContinuous {
                            self.startOneKeyMeasurement()
                        }
                    }
                }
            })
    }

    private func stopOneKeyFallback(source: String) {
        guard oneClickRunning else { return }
        oneClickContinuous = false
        QCSDKManager.shareInstance()?.stopToMeasuringWithOperateType(
            .oneKeyMeasure,
            completedHandle: { [weak self] _, _ in
                self?.diag("[ONEKEY] stopped from \(source)")
            })
        oneClickRunning = false
    }

    // ═════════════════════════════════════════════════════════════
    // MARK: - MethodChannel dispatcher
    // ═════════════════════════════════════════════════════════════

    private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        switch call.method {

        case "scan":
            handleScan(result: result)

        case "connect":
            guard let id = args?["id"] as? String else { result(missingId()); return }
            handleConnect(deviceId: id, result: result)

        case "disconnect":
            handleDisconnect(result: result)

        case "getConnectionStatus":
            result(["connected": serviceReady && connectedDeviceId != nil,
                    "deviceId": connectedDeviceId as Any])

        case "readMetrics":
            guard let id = args?["id"] as? String else { result(missingId()); return }
            handleReadMetrics(deviceId: id, result: result)

        case "startHeartRateNotifications":
            guard let id = args?["id"] as? String else { result(missingId()); return }
            handleStartHr(deviceId: id, result: result)

        case "stopHeartRateNotifications":
            guard let id = args?["id"] as? String else { result(missingId()); return }
            handleStopHr(deviceId: id, result: result)

        case "syncTime":
            handleSyncTime(result: result)

        case "getBattery":
            handleGetBattery(result: result)

        case "setHeartRateInterval":
            let interval = args?["interval"] as? Int ?? 10
            let enable   = args?["enable"]   as? Bool ?? true
            handleSetHrInterval(enable: enable, interval: interval, result: result)

        case "startSpO2":
            guard let id = args?["id"] as? String else { result(missingId()); return }
            handleStartSpO2(deviceId: id, result: result)

        case "stopSpO2":
            guard let id = args?["id"] as? String else { result(missingId()); return }
            handleStopSpO2(deviceId: id, result: result)

        case "startBloodPressure":
            guard let id = args?["id"] as? String else { result(missingId()); return }
            handleStartBP(deviceId: id, result: result)

        case "stopBloodPressure":
            guard let id = args?["id"] as? String else { result(missingId()); return }
            handleStopBP(deviceId: id, result: result)

        case "startTemperature":
            guard let id = args?["id"] as? String else { result(missingId()); return }
            handleStartTemp(deviceId: id, result: result)

        case "stopTemperature":
            guard let id = args?["id"] as? String else { result(missingId()); return }
            handleStopTemp(deviceId: id, result: result)

        case "startHrv":
            guard let id = args?["id"] as? String else { result(missingId()); return }
            handleStartHrv(deviceId: id, result: result)

        case "stopHrv":
            guard let id = args?["id"] as? String else { result(missingId()); return }
            handleStopHrv(deviceId: id, result: result)

        case "checkNow":
            guard let id = args?["id"] as? String else { result(missingId()); return }
            handleCheckNow(deviceId: id, result: result)

        case "findDevice":
            handleFindDevice(result: result)

        case "enterCamera":
            handleEnterCamera(result: result)

        case "exitCamera":
            handleExitCamera(result: result)

        case "setCallReminder":
            let enable = args?["enable"] as? Bool ?? true
            handleSetCallReminder(enable: enable, result: result)

        case "isNotificationAccessEnabled":
            result(true)

        case "openNotificationAccessSettings":
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
            result(true)

        case "setSedentaryReminder":
            let enable  = args?["enable"]      as? Bool ?? true
            let interval = args?["interval"]   as? Int  ?? 60
            let startH  = args?["startHour"]   as? Int  ?? 9
            let startM  = args?["startMinute"] as? Int  ?? 0
            let endH    = args?["endHour"]     as? Int  ?? 18
            let endM    = args?["endMinute"]   as? Int  ?? 0
            handleSetSedentaryReminder(enable: enable, interval: interval,
                                       startH: startH, startM: startM,
                                       endH: endH, endM: endM, result: result)

        case "setDnd":
            let enable = args?["enable"]      as? Bool ?? false
            let startH = args?["startHour"]   as? Int  ?? 22
            let startM = args?["startMinute"] as? Int  ?? 0
            let endH   = args?["endHour"]     as? Int  ?? 7
            let endM   = args?["endMinute"]   as? Int  ?? 0
            handleSetDnd(enable: enable, startH: startH, startM: startM,
                         endH: endH, endM: endM, result: result)

        case "setAlarm":
            let index    = args?["index"]    as? Int  ?? 0
            let enable   = args?["enable"]   as? Bool ?? true
            let hour     = args?["hour"]     as? Int  ?? 8
            let minute   = args?["minute"]   as? Int  ?? 0
            let weekMask = args?["weekMask"] as? Int  ?? 0x7F
            handleSetAlarm(index: index, enable: enable, hour: hour,
                           minute: minute, weekMask: weekMask, result: result)

        case "readAlarms":
            result([])

        case "syncSleep":
            handleSyncSleep(result: result)

        case "getLastVitalValues":
            result(["hr": lastHr, "spo2": lastSpo2, "sbp": lastSbp,
                    "dbp": lastDbp, "temp": lastTempRaw, "hrv": lastHrv,
                    "stress": lastStress])

        case "startContinuousMeasurement":
            handleStartContinuousMeasurement(result: result)

        case "stopContinuousMeasurement":
            handleStopContinuousMeasurement(result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // ═════════════════════════════════════════════════════════════
    // MARK: - Handlers
    // ═════════════════════════════════════════════════════════════

    // ── Scan (QCCentralManager — same as QCBandSDKDemo) ───────────

    private func handleScan(result: @escaping FlutterResult) {
        let bleState = QCCentralManager.shared().bleState
        if bleState == QCBluetoothStatePoweredOff {
            result(FlutterError(code: "BLE_OFF", message: "Bluetooth is turned off", details: nil))
            return
        }

        scannedDevices = []
        peripheralMap = [:]
        scanResultSent = false
        pendingScanResult = result
        scanTimer?.invalidate()

        QCCentralManager.shared().scan(withTimeout: 12)

        scanTimer = Timer.scheduledTimer(withTimeInterval: 12.0, repeats: false) { [weak self] _ in
            self?.finishScan()
        }
    }

    private func finishScan() {
        guard !scanResultSent else { return }
        scanResultSent = true
        QCCentralManager.shared().stopScan()
        scanTimer?.invalidate()
        pendingScanResult?(scannedDevices)
        pendingScanResult = nil
    }

    private func updateScanResults(_ peripherals: [QCBlePeripheral]) {
        var devices: [[String: Any]] = []
        for qc in peripherals {
            guard let p = qc.peripheral, let name = p.name, !name.isEmpty else { continue }
            let id = p.identifier.uuidString
            peripheralMap[id] = p
            let displayName = (qc.mac as String?)?.isEmpty == false ? "\(name) (\(qc.mac!))" : name
            devices.append([
                "id": id,
                "name": displayName,
                "rssi": qc.rssi?.intValue ?? -100
            ])
        }
        scannedDevices = devices
    }

    // ── Connect ───────────────────────────────────────────────────

    private func handleConnect(deviceId: String, result: @escaping FlutterResult) {
        if connectedDeviceId == deviceId && serviceReady {
            result(true); return
        }

        if let pending = pendingConnectResult {
            connectTimeoutTimer?.invalidate()
            pending(FlutterError(code: "CONNECT_REPLACED", message: "New connect started", details: nil))
        }

        serviceReady = false
        pendingConnectResult = result
        pendingConnectDeviceId = deviceId
        connectedDeviceId = deviceId

        guard let peripheral = resolvePeripheral(deviceId: deviceId) else {
            result(FlutterError(code: "DEVICE_NOT_FOUND",
                                message: "Device \(deviceId) not found. Scan first.",
                                details: nil))
            pendingConnectResult = nil
            pendingConnectDeviceId = nil
            connectedDeviceId = nil
            return
        }

        connectedPeripheral = peripheral
        // Watch type enables ANCS for call/SMS notifications on bracelet
        QCCentralManager.shared().connect(peripheral, timeout: 25, deviceType: .watch)

        connectTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 25.0, repeats: false) { [weak self] _ in
            guard let self = self, self.pendingConnectResult != nil else { return }
            self.pendingConnectResult?(FlutterError(code: "CONNECT_TIMEOUT",
                                                    message: "Could not connect in 25s",
                                                    details: nil))
            self.pendingConnectResult = nil
            self.pendingConnectDeviceId = nil
            self.connectedDeviceId = nil
        }
    }

    private func resolvePeripheral(deviceId: String) -> CBPeripheral? {
        if let p = peripheralMap[deviceId] { return p }
        if let p = QCCentralManager.shared().connectedPeripheral,
           p.identifier.uuidString == deviceId { return p }
        guard let uuid = UUID(uuidString: deviceId) else { return nil }
        let list = QCCentralManager.shared().centerManager.retrievePeripherals(withIdentifiers: [uuid])
        return list.first
    }

    private func onDeviceConnected(deviceId: String) {
        serviceReady = true
        connectedDeviceId = deviceId
        connectTimeoutTimer?.invalidate()

        QCSDKCmdCreator.setTime(Date(), success: { _ in }, failed: {})
        QCSDKCmdCreator.alertBindingSuccess({ }, fail: { })
        QCSDKCmdCreator.setANCSFlagSuccess({ }, fail: { })

        diag("[CONNECT] ready for \(deviceId)")
        connSink?(["deviceId": deviceId, "connected": true])
        pendingConnectResult?(true)
        pendingConnectResult = nil
        pendingConnectDeviceId = nil
    }

    private func onDeviceDisconnected() {
        serviceReady = false
        stopOneKeyFallback(source: "disconnect")
        let id = connectedDeviceId
        connectedDeviceId = nil
        connectedPeripheral = nil
        if let id = id {
            connSink?(["deviceId": id, "connected": false])
        }
    }

    // ── Disconnect ────────────────────────────────────────────────

    private func handleDisconnect(result: @escaping FlutterResult) {
        QCCentralManager.shared().remove()
        onDeviceDisconnected()
        result(true)
    }

    // ── Read metrics ──────────────────────────────────────────────

    private func handleReadMetrics(deviceId: String, result: @escaping FlutterResult) {
        guard serviceReady else {
            result(["heartRate": 0, "steps": lastSteps, "battery": 0,
                    "spo2": NSNull(), "calories": lastCalories > 0 ? lastCalories : NSNull()])
            return
        }
        var metrics: [String: Any] = [
            "heartRate": lastHr,
            "steps": lastSteps,
            "battery": 0,
            "spo2": lastSpo2 > 0 ? lastSpo2 : NSNull(),
            "calories": lastCalories > 0 ? lastCalories : NSNull()
        ]
        let group = DispatchGroup()

        group.enter()
        QCSDKCmdCreator.readBatterySuccess({ bat, _ in
            metrics["battery"] = Int(bat); group.leave()
        }, failed: { group.leave() })

        group.enter()
        QCSDKCmdCreator.getCurrentSportSucess({ sport in
            if let s = sport {
                self.lastSteps = Int(s.totalStepCount)
                self.lastCalories = Int(s.calories)
                metrics["steps"]    = Int(s.totalStepCount)
                metrics["calories"] = Int(s.calories)
            }
            group.leave()
        }, failed: { group.leave() })

        group.notify(queue: .main) {
            self.diag("[READ_METRICS] \(metrics)")
            result(metrics)
        }
    }

    // ── Heart Rate (oneKey — matches Android) ─────────────────────

    private func handleStartHr(deviceId: String, result: @escaping FlutterResult) {
        guard serviceReady else { result(notConnectedError()); return }
        startOneKeyFallback(source: "hr")
        result(nil)
    }

    private func handleStopHr(deviceId: String, result: @escaping FlutterResult) {
        stopOneKeyFallback(source: "hr")
        result(nil)
    }

    // ── Sync time ─────────────────────────────────────────────────

    private func handleSyncTime(result: @escaping FlutterResult) {
        QCSDKCmdCreator.setTime(Date(), success: { _ in }, failed: {})
        result(true)
    }

    // ── Battery ───────────────────────────────────────────────────

    private func handleGetBattery(result: @escaping FlutterResult) {
        guard serviceReady else { result(0); return }
        var replied = false
        QCSDKCmdCreator.readBatterySuccess({ bat, _ in
            if !replied { replied = true; DispatchQueue.main.async { result(Int(bat)) } }
        }, failed: {
            if !replied { replied = true; DispatchQueue.main.async { result(0) } }
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if !replied { replied = true; result(0) }
        }
    }

    // ── HR Interval ───────────────────────────────────────────────

    private func handleSetHrInterval(enable: Bool, interval: Int, result: @escaping FlutterResult) {
        QCSDKCmdCreator.setSchedualHeartRateStatus(enable,
            timeInterval: interval,
            success: { DispatchQueue.main.async { result(true) } },
            fail:    { DispatchQueue.main.async { result(false) } })
    }

    // ── SpO2 ──────────────────────────────────────────────────────

    private func handleStartSpO2(deviceId: String, result: @escaping FlutterResult) {
        guard serviceReady else { result(notConnectedError()); return }
        QCSDKManager.shareInstance()?.startToMeasuringWithOperateType(
            .bloodOxygen,
            measuringHandle: { [weak self] val in
                guard let self = self, let n = val as? NSNumber else { return }
                let v = n.intValue
                if self.isValidSpo2(v) { self.lastSpo2 = v; self.spo2Sink?(v) }
            },
            completedHandle: { _, _, _ in })
        result(nil)
    }

    private func handleStopSpO2(deviceId: String, result: @escaping FlutterResult) {
        QCSDKManager.shareInstance()?.stopToMeasuringWithOperateType(.bloodOxygen,
                                                                      completedHandle: { _, _ in })
        result(nil)
    }

    // ── Blood Pressure ────────────────────────────────────────────

    private func handleStartBP(deviceId: String, result: @escaping FlutterResult) {
        guard serviceReady else { result(notConnectedError()); return }
        QCSDKManager.shareInstance()?.startToMeasuringWithOperateType(
            .bloodPressue,
            measuringHandle: { _ in },
            completedHandle: { _, _, _ in })
        result(nil)
    }

    private func handleStopBP(deviceId: String, result: @escaping FlutterResult) {
        QCSDKManager.shareInstance()?.stopToMeasuringWithOperateType(.bloodPressue,
                                                                      completedHandle: { _, _ in })
        result(nil)
    }

    // ── Temperature ───────────────────────────────────────────────

    private func handleStartTemp(deviceId: String, result: @escaping FlutterResult) {
        guard serviceReady else { result(notConnectedError()); return }
        QCSDKManager.shareInstance()?.startToMeasuringWithOperateType(
            .bodyTemperature,
            measuringHandle: { [weak self] val in
                guard let self = self, let n = val as? NSNumber else { return }
                let t = n.intValue
                if self.isValidTempRaw(t) { self.lastTempRaw = t; self.tempSink?(t) }
            },
            completedHandle: { _, _, _ in })
        result(nil)
    }

    private func handleStopTemp(deviceId: String, result: @escaping FlutterResult) {
        QCSDKManager.shareInstance()?.stopToMeasuringWithOperateType(.bodyTemperature,
                                                                      completedHandle: { _, _ in })
        result(nil)
    }

    // ── HRV (oneKey — matches Android) ────────────────────────────

    private func handleStartHrv(deviceId: String, result: @escaping FlutterResult) {
        guard serviceReady else { result(notConnectedError()); return }
        startOneKeyFallback(source: "hrv")
        result(nil)
    }

    private func handleStopHrv(deviceId: String, result: @escaping FlutterResult) {
        stopOneKeyFallback(source: "hrv")
        result(nil)
    }

    // ── Check Now (sequential: HR → SpO2 → HRV) ──────────────────

    private func handleCheckNow(deviceId: String, result: @escaping FlutterResult) {
        guard serviceReady else { result([String: Any]()); return }
        var collected: [String: Any] = [:]
        var replied = false

        QCSDKCmdCreator.readBatterySuccess({ bat, _ in collected["battery"] = Int(bat) }, failed: {})
        QCSDKCmdCreator.getCurrentSportSucess({ sport in
            if let s = sport {
                collected["steps"]    = Int(s.totalStepCount)
                collected["calories"] = Int(s.calories)
            }
        }, failed: {})

        QCSDKManager.shareInstance()?.startToMeasuringWithOperateType(
            .heartRate, timeout: 12,
            measuringHandle: { [weak self] val in
                guard let self = self, let n = val as? NSNumber, !collected.keys.contains("heartRate") else { return }
                let hr = n.intValue
                if self.isValidHr(hr) {
                    collected["heartRate"] = hr
                    DispatchQueue.main.async { self.hrSink?(hr) }
                }
            },
            completedHandle: { [weak self] _, _, _ in
                guard let self = self else { return }
                QCSDKManager.shareInstance()?.startToMeasuringWithOperateType(
                    .bloodOxygen, timeout: 12,
                    measuringHandle: { val in
                        guard let n = val as? NSNumber, !collected.keys.contains("spo2") else { return }
                        let v = n.intValue
                        if self.isValidSpo2(v) {
                            collected["spo2"] = v
                            DispatchQueue.main.async { self.spo2Sink?(v) }
                        }
                    },
                    completedHandle: { [weak self] _, _, _ in
                        guard let self = self else { return }
                        QCSDKManager.shareInstance()?.startToMeasuringWithOperateType(
                            .HRV, timeout: 12,
                            measuringHandle: { _ in },
                            completedHandle: { [weak self] _, _, _ in
                                guard let self = self else { return }
                                if !replied {
                                    replied = true
                                    collected["hrv"] = self.lastHrv > 0 ? self.lastHrv : nil
                                    collected["stress"] = self.lastStress > 0 ? self.lastStress : nil
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                        self.diag("[CHECKNOW] done: \(collected)")
                                        result(collected)
                                    }
                                }
                            })
                    })
            })

        DispatchQueue.main.asyncAfter(deadline: .now() + 37) {
            if !replied { replied = true; result(collected) }
        }
    }

    // ── Find Device ───────────────────────────────────────────────

    private func handleFindDevice(result: @escaping FlutterResult) {
        guard serviceReady else { result(false); return }
        QCSDKCmdCreator.lookupDeviceSuccess({ result(true) }, fail: { result(false) })
    }

    // ── Camera ────────────────────────────────────────────────────

    private func handleEnterCamera(result: @escaping FlutterResult) {
        guard serviceReady else { result(false); return }
        QCSDKCmdCreator.switchToPhotoUISuccess({ result(true) }, fail: { result(false) })
    }

    private func handleExitCamera(result: @escaping FlutterResult) {
        guard serviceReady else { result(false); return }
        QCSDKCmdCreator.stopTakingPhotoSuccess({ result(true) }, fail: { result(false) })
    }

    // ── Call / Notification reminder (ANCS) ───────────────────────

    private func handleSetCallReminder(enable: Bool, result: @escaping FlutterResult) {
        guard serviceReady else { result(false); return }
        let filters: [String] = enable
            ? ["1","1","0","0","0","0","0","0","0","0","0","0","0","0","0"]
            : ["0","0","0","0","0","0","0","0","0","0","0","0","0","0","0"]
        QCSDKCmdCreator.setANCSFlagSuccess({ [weak self] in
            QCSDKCmdCreator.setFilter(filters, success: { [weak self] in
                self?.callReminderEnabled = enable
                DispatchQueue.main.async { result(true) }
            }, failed: { DispatchQueue.main.async { result(false) } })
        }, fail: { DispatchQueue.main.async { result(false) } })
    }

    // ── Sedentary reminder ────────────────────────────────────────

    private func handleSetSedentaryReminder(
        enable: Bool, interval: Int,
        startH: Int, startM: Int, endH: Int, endM: Int,
        result: @escaping FlutterResult
    ) {
        guard serviceReady else { result(false); return }
        let begin = String(format: "%02d:%02d", startH, startM)
        let end   = String(format: "%02d:%02d", endH,   endM)
        let rep: [NSNumber] = enable ? [1,1,1,1,1,1,1] : [0,0,0,0,0,0,0]
        QCSDKCmdCreator.setBeginTime(begin, endTime: end, repeatModel: rep,
                                     timeInterval: UInt(interval),
                                     success: { DispatchQueue.main.async { result(true) } },
                                     fail:    { DispatchQueue.main.async { result(false) } })
    }

    // ── Do Not Disturb ────────────────────────────────────────────

    private func handleSetDnd(
        enable: Bool, startH: Int, startM: Int, endH: Int, endM: Int,
        result: @escaping FlutterResult
    ) {
        guard serviceReady else { result(false); return }
        let begin = String(format: "%02d:%02d", startH, startM)
        let end   = String(format: "%02d:%02d", endH,   endM)
        QCSDKCmdCreator.setDontDisturbOn(enable, beginTime: begin, endTime: end,
            success: { _, _, _ in DispatchQueue.main.async { result(true) } },
            fail:    { DispatchQueue.main.async { result(false) } })
    }

    // ── Alarm ─────────────────────────────────────────────────────

    private func handleSetAlarm(
        index: Int, enable: Bool, hour: Int, minute: Int, weekMask: Int,
        result: @escaping FlutterResult
    ) {
        guard serviceReady else { result(false); return }
        let timeStr = String(format: "%02d:%02d", hour, minute)
        let type: ALARMTYPE = enable ? ALARMOTHER : ALARMCLOSE
        let weekArr: [NSNumber] = [
            weekMask & 0x40 != 0 ? 1 : 0,
            weekMask & 0x01 != 0 ? 1 : 0,
            weekMask & 0x02 != 0 ? 1 : 0,
            weekMask & 0x04 != 0 ? 1 : 0,
            weekMask & 0x08 != 0 ? 1 : 0,
            weekMask & 0x10 != 0 ? 1 : 0,
            weekMask & 0x20 != 0 ? 1 : 0,
        ]
        QCSDKCmdCreator.setDrinkWaterRemindIndex(UInt(index), type: type, time: timeStr,
            cycle: weekArr,
            success: { DispatchQueue.main.async { result(true) } },
            failed:  { DispatchQueue.main.async { result(false) } })
    }

    // ── Sleep sync ────────────────────────────────────────────────

    private func handleSyncSleep(result: @escaping FlutterResult) {
        guard serviceReady else { result(nil); return }
        var replied = false
        QCSDKCmdCreator.getSleepDetailData(byDay: 0, sleepDatas: { sleeps in
            if replied { return }
            replied = true
            var segments: [[String: Any]] = []
            var deep = 0, light = 0, rem = 0, awake = 0
            sleeps?.forEach { s in
                segments.append(["start": s.happenDate as Any,
                                 "end":   s.endTime    as Any,
                                 "type":  s.type.rawValue])
                switch s.type {
                case SLEEPTYPEDEEP:  deep  += Int(s.total)
                case SLEEPTYPELIGHT: light += Int(s.total)
                case SLEEPTYPEREM:   rem   += Int(s.total)
                case SLEEPTYPESOBER: awake += Int(s.total)
                default: break
                }
            }
            let total = deep + light + rem
            let map: [String: Any] = [
                "totalSleep": total, "deepSleep": deep,
                "lightSleep": light, "remSleep":  rem,
                "awake": awake, "wakingCount": 0,
                "sleepTime": 0, "wakeTime": 0,
                "segments": segments
            ]
            DispatchQueue.main.async { result(map) }
        }, fail: {
            if !replied { replied = true; DispatchQueue.main.async { result(nil) } }
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            if !replied { replied = true; result(nil) }
        }
    }

    // ── Continuous measurement (oneKey loop — matches Android) ──────

    private func handleStartContinuousMeasurement(result: @escaping FlutterResult) {
        guard serviceReady else { result(notConnectedError()); return }
        if oneClickRunning { result(nil); return }
        lastHr = 0; lastSpo2 = 0; lastSbp = 0; lastDbp = 0
        lastTempRaw = 0; lastHrv = 0; lastStress = 0
        startOneKeyFallback(source: "continuous", continuous: true)
        result(nil)
    }

    private func handleStopContinuousMeasurement(result: @escaping FlutterResult) {
        stopOneKeyFallback(source: "continuous")
        result(nil)
    }

    // ═════════════════════════════════════════════════════════════
    // MARK: - Validation helpers
    // ═════════════════════════════════════════════════════════════

    private func isValidHr(_ v: Int)      -> Bool { v >= 30  && v <= 240 }
    private func isValidSpo2(_ v: Int)    -> Bool { v >= 70  && v <= 100 }
    private func isValidSbp(_ v: Int)     -> Bool { v >= 70  && v <= 240 }
    private func isValidDbp(_ v: Int)     -> Bool { v >= 40  && v <= 140 }
    private func isValidTempRaw(_ v: Int) -> Bool { (v >= 300 && v <= 450) || (v >= 85 && v <= 115) }
    private func isValidHrv(_ v: Int)     -> Bool { v >= 5   && v <= 250 }
    private func isValidStress(_ v: Int)  -> Bool { v >= 1   && v <= 100 }

    // ═════════════════════════════════════════════════════════════
    // MARK: - Convenience
    // ═════════════════════════════════════════════════════════════

    private func makeHandler(_ onListen: @escaping (FlutterEventSink?) -> Void) -> FlutterStreamHandler {
        return QcStreamHandler(onListen: onListen)
    }

    private func notConnectedError() -> FlutterError {
        FlutterError(code: "NOT_CONNECTED", message: "Device not connected or service not ready", details: nil)
    }

    private func missingId() -> FlutterError {
        FlutterError(code: "MISSING_ID", message: "Device ID required", details: nil)
    }
}

// ═════════════════════════════════════════════════════════════════
// MARK: - QCCentralManagerDelegate (from QCBandSDKDemo)
// ═════════════════════════════════════════════════════════════════

extension AppDelegate: QCCentralManagerDelegate {

    func didState(_ state: QCState) {
        switch state {
        case QCStateConnected:
            if let p = QCCentralManager.shared().connectedPeripheral {
                connectedPeripheral = p
                let id = pendingConnectDeviceId ?? p.identifier.uuidString
                if pendingConnectResult != nil || !serviceReady {
                    onDeviceConnected(deviceId: id)
                }
            }
        case QCStateUnbind, QCStateDisconnected:
            if serviceReady || connectedDeviceId != nil {
                onDeviceDisconnected()
            }
        case QCStateConnecting:
            diag("[BLE] connecting...")
        default:
            break
        }
    }

    func didBluetoothState(_ state: QCBluetoothState) {
        if state == QCBluetoothStatePoweredOff {
            onDeviceDisconnected()
        }
    }

    func didScanPeripherals(_ peripheralArr: [QCBlePeripheral]) {
        updateScanResults(peripheralArr)
    }

    func didFailConnected(_ peripheral: CBPeripheral, error: Error?) {
        connectTimeoutTimer?.invalidate()
        let msg = error?.localizedDescription ?? "Connect failed"
        diag("[BLE] connect failed: \(msg)")
        pendingConnectResult?(FlutterError(code: "CONNECT_FAILED", message: msg, details: nil))
        pendingConnectResult = nil
        pendingConnectDeviceId = nil
        connectedDeviceId = nil
        connectedPeripheral = nil
        serviceReady = false
    }
}

// ═════════════════════════════════════════════════════════════════
// MARK: - QcStreamHandler (FlutterStreamHandler)
// ═════════════════════════════════════════════════════════════════

private class QcStreamHandler: NSObject, FlutterStreamHandler {
    private let block: (FlutterEventSink?) -> Void
    init(onListen: @escaping (FlutterEventSink?) -> Void) { block = onListen }

    func onListen(withArguments arguments: Any?,
                  eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        block(events); return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        block(nil); return nil
    }
}
