import CoreBluetooth
import Flutter
import PolarBleSdk
import UIKit

private let encoder = JSONEncoder()
private let decoder = JSONDecoder()

private func jsonEncode(_ value: Encodable) -> String? {
  guard let data = try? encoder.encode(value),
    let data = String(data: data, encoding: .utf8)
  else {
    return nil
  }

  return data
}

private enum PolarPluginError: LocalizedError {
  case serializationFailed
  case unsupportedFeature(String)

  var errorDescription: String? {
    switch self {
    case .serializationFailed:
      return "Unable to serialize Polar SDK response"
    case .unsupportedFeature(let feature):
      return "Unsupported Polar SDK feature: \(feature)"
    }
  }
}

private final class ManagedTask {
  var task: Task<Void, Never>?

  func cancel() {
    task?.cancel()
  }
}

public class PolarPlugin:
  NSObject,
  FlutterPlugin,
  FlutterStreamHandler,
  PolarBleApiObserver,
  PolarBleApiPowerStateObserver,
  PolarBleApiDeviceFeaturesObserver,
  PolarBleApiDeviceInfoObserver
{
  /// Binary messenger for dynamic EventChannel registration
  let messenger: FlutterBinaryMessenger

  /// Method channel
  let methodChannel: FlutterMethodChannel

  /// Event channel
  let eventChannel: FlutterEventChannel

  /// Search channel
  let searchChannel: FlutterEventChannel

  /// Streaming channels
  var streamingChannels = [String: StreamingChannel]()

  var api: PolarBleApi!
  var sinks: [Int: FlutterEventSink] = [:]
  private var operationTasks: [UUID: ManagedTask] = [:]
  private let operationTasksLock = NSLock()
  private var searchTask: Task<Void, Never>?

  init(
    messenger: FlutterBinaryMessenger,
    methodChannel: FlutterMethodChannel,
    eventChannel: FlutterEventChannel,
    searchChannel: FlutterEventChannel
  ) {
    self.messenger = messenger
    self.methodChannel = methodChannel
    self.eventChannel = eventChannel
    self.searchChannel = searchChannel
  }

  private func initApi() {
    guard api == nil else { return }
    api = PolarBleApiDefaultImpl.polarImplementation(
      DispatchQueue.main, features: Set(PolarBleSdkFeature.allCases))

    api.observer = self
    api.powerStateObserver = self
    api.deviceFeaturesObserver = self
    api.deviceInfoObserver = self
  }

  deinit {
    searchTask?.cancel()
    operationTasksLock.lock()
    let tasks = operationTasks.values
    operationTasks.removeAll()
    operationTasksLock.unlock()
    tasks.forEach { $0.cancel() }
    streamingChannels.values.forEach { $0.dispose() }
    api?.cleanup()
  }

  private func runOperation(
    _ result: @escaping FlutterResult,
    operation: @escaping () async throws -> Any?
  ) {
    let id = UUID()
    let managedTask = ManagedTask()
    operationTasksLock.lock()
    operationTasks[id] = managedTask
    operationTasksLock.unlock()

    managedTask.task = Task { [weak self, weak managedTask] in
      defer { self?.removeOperationTask(id) }
      do {
        let value = try await operation()
        guard managedTask?.task?.isCancelled != true else { return }
        DispatchQueue.main.async {
          guard managedTask?.task?.isCancelled != true else { return }
          result(value)
        }
      } catch is CancellationError {
        return
      } catch {
        guard managedTask?.task?.isCancelled != true else { return }
        DispatchQueue.main.async {
          guard managedTask?.task?.isCancelled != true else { return }
          result(
            FlutterError(
              code: "Error in Polar plugin",
              message: error.localizedDescription,
              details: nil
            )
          )
        }
      }
    }
  }

  private func removeOperationTask(_ id: UUID) {
    operationTasksLock.lock()
    operationTasks.removeValue(forKey: id)
    operationTasksLock.unlock()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let methodChannel = FlutterMethodChannel(
      name: "polar/methods", binaryMessenger: registrar.messenger())
    let eventChannel = FlutterEventChannel(
      name: "polar/events", binaryMessenger: registrar.messenger())
    let searchChannel = FlutterEventChannel(
      name: "polar/search", binaryMessenger: registrar.messenger())

    let instance = PolarPlugin(
      messenger: registrar.messenger(),
      methodChannel: methodChannel,
      eventChannel: eventChannel,
      searchChannel: searchChannel)

    registrar.addMethodCallDelegate(instance, channel: methodChannel)
    eventChannel.setStreamHandler(instance)
    searchChannel.setStreamHandler(instance.searchHandler)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    initApi()

    do {
      switch call.method {
      case "shutDown":
        shutDown()
        result(nil)
      case "connectToDevice":
        try api.connectToDevice(call.arguments as! String)
        result(nil)
      case "disconnectFromDevice":
        try api.disconnectFromDevice(call.arguments as! String)
        result(nil)
      case "waitForConnection":
        let api = api!
        let identifier = call.arguments as! String
        runOperation(result) {
          try await api.waitForConnection(identifier)
          return nil
        }
      case "setAutomaticReconnection":
        api.automaticReconnection = call.arguments as! Bool
        result(nil)
      case "getAvailableOnlineStreamDataTypes":
        getAvailableOnlineStreamDataTypes(call, result)
      case "getAvailableHrServiceDataTypes":
        getAvailableHrServiceDataTypes(call, result)
      case "requestStreamSettings":
        requestStreamSettings(call, result)
      case "createStreamingChannel":
        createStreamingChannel(call, result)
      case "startRecording":
        startRecording(call, result)
      case "stopRecording":
        stopRecording(call, result)
      case "requestRecordingStatus":
        requestRecordingStatus(call, result)
      case "listExercises":
        listExercises(call, result)
      case "fetchExercise":
        fetchExercise(call, result)
      case "removeExercise":
        removeExercise(call, result)
      case "setLedConfig":
        setLedConfig(call, result)
      case "doFactoryReset":
        doFactoryReset(call, result)
      case "doRestart":
        doRestart(call, result)
      case "isFeatureReady":
        try isFeatureReady(call, result)
      case "enableSdkMode":
        enableSdkMode(call, result)
      case "disableSdkMode":
        disableSdkMode(call, result)
      case "isSdkModeEnabled":
        isSdkModeEnabled(call, result)
      case "doFirstTimeUse":
        doFirstTimeUse(call, result)
      case "isFtuDone":
        isFtuDone(call, result)
      default: result(FlutterMethodNotImplemented)
      }
    } catch {
      result(
        FlutterError(
          code: "Error in Polar plugin", message: error.localizedDescription, details: nil))
    }
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    initApi()
    self.sinks[arguments as! Int] = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    guard let id = arguments as? Int else { return nil }
    self.sinks.removeValue(forKey: id)
    return nil
  }

  lazy var searchHandler = StreamHandler(
    onListen: { [weak self] _, events in
      guard let self else { return nil }
      initApi()
      searchTask?.cancel()
      let stream = api.searchForDevice()
      searchTask = Task {
        do {
          for try await device in stream {
            try Task.checkCancellation()
            guard let data = jsonEncode(PolarDeviceInfoCodable(device)) else {
              throw PolarPluginError.serializationFailed
            }
            await MainActor.run {
              events(data)
            }
          }
          await MainActor.run {
            events(FlutterEndOfEventStream)
          }
        } catch is CancellationError {
          return
        } catch {
          await MainActor.run {
            events(
              FlutterError(
                code: "Error in searchForDevice",
                message: error.localizedDescription,
                details: nil
              )
            )
          }
        }
      }
      return nil
    },
    onCancel: { [weak self] _ in
      self?.searchTask?.cancel()
      self?.searchTask = nil
      return nil
    })

  private func createStreamingChannel(_ call: FlutterMethodCall, _ result: @escaping FlutterResult)
  {
    let arguments = call.arguments as! [Any]
    let name = arguments[0] as! String
    let identifier = arguments[1] as! String
    let feature = PolarDeviceDataType.allCases[arguments[2] as! Int]

    if streamingChannels[name] == nil {
      streamingChannels[name] = StreamingChannel(messenger, name, api, identifier, feature)
    }

    result(nil)
  }

  func getAvailableOnlineStreamDataTypes(
    _ call: FlutterMethodCall, _ result: @escaping FlutterResult
  ) {
    let identifier = call.arguments as! String
    let api = api!
    runOperation(result) {
      let data = try await api.getAvailableOnlineStreamDataTypes(identifier)
      return try Self.encodeDataTypes(data)
    }
  }

  func getAvailableHrServiceDataTypes(
    _ call: FlutterMethodCall, _ result: @escaping FlutterResult
  ) {
    let identifier = call.arguments as! String
    let api = api!
    runOperation(result) {
      let data = try await api.getAvailableHRServiceDataTypes(identifier: identifier)
      return try Self.encodeDataTypes(data)
    }
  }

  private static func encodeDataTypes(_ dataTypes: Set<PolarDeviceDataType>) throws -> String {
    let indices = dataTypes.compactMap { PolarDeviceDataType.allCases.firstIndex(of: $0) }
    guard let data = jsonEncode(indices) else {
      throw PolarPluginError.serializationFailed
    }
    return data
  }

  private static func feature(named name: String) throws -> PolarBleSdkFeature {
    switch name.lowercased() {
    case "feature_hr": return .feature_hr
    case "feature_device_info": return .feature_device_info
    case "feature_battery_info": return .feature_battery_info
    case "feature_polar_online_streaming": return .feature_polar_online_streaming
    case "feature_polar_offline_recording": return .feature_polar_offline_recording
    case "feature_polar_h10_exercise_recording": return .feature_polar_h10_exercise_recording
    case "feature_polar_offline_exercise_v2": return .feature_polar_offline_exercise_v2
    case "feature_polar_device_time_setup": return .feature_polar_device_time_setup
    case "feature_polar_sdk_mode": return .feature_polar_sdk_mode
    case "feature_polar_led_animation": return .feature_polar_led_animation
    case "feature_polar_firmware_update": return .feature_polar_firmware_update
    case "feature_polar_activity_data": return .feature_polar_activity_data
    case "feature_polar_training_data": return .feature_polar_training_data
    case "feature_polar_sleep_data": return .feature_polar_sleep_data
    case "feature_polar_device_control": return .feature_polar_device_control
    case "feature_polar_file_transfer": return .feature_polar_file_transfer
    case "feature_hts": return .feature_hts
    case "feature_polar_temperature_data": return .feature_polar_temperature_data
    case "feature_polar_features_configuration_service":
      return .feature_polar_features_configuration_service
    case "feature_polar_spo2_test_data": return .feature_polar_spo2_test_data
    case "feature_polar_watch_faces_configuration":
      return .feature_polar_watch_faces_configuration
    case "feature_telemetry_data_streaming": return .feature_telemetry_data_streaming
    default: throw PolarPluginError.unsupportedFeature(name)
    }
  }

  func requestStreamSettings(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let arguments = call.arguments as! [Any]
    let identifier = arguments[0] as! String
    let feature = PolarDeviceDataType.allCases[arguments[1] as! Int]
    let api = api!
    runOperation(result) {
      let settings = try await api.requestStreamSettings(identifier, feature: feature)
      guard let data = jsonEncode(PolarSensorSettingCodable(settings)) else {
        throw PolarPluginError.serializationFailed
      }
      return data
    }
  }

  func startRecording(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let arguments = call.arguments as! [Any]
    let identifier = arguments[0] as! String
    let exerciseId = arguments[1] as! String
    let interval = RecordingInterval(rawValue: arguments[2] as! Int)!
    let sampleType = SampleType(rawValue: arguments[3] as! Int)!
    let api = api!
    runOperation(result) {
      try await api.startRecording(
        identifier,
        exerciseId: exerciseId,
        interval: interval,
        sampleType: sampleType
      )
      return nil
    }
  }

  func stopRecording(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let identifier = call.arguments as! String
    let api = api!
    runOperation(result) {
      try await api.stopRecording(identifier)
      return nil
    }
  }

  func requestRecordingStatus(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let identifier = call.arguments as! String
    let api = api!
    runOperation(result) {
      let status = try await api.requestRecordingStatus(identifier)
      return [status.ongoing, status.entryId]
    }
  }

  func listExercises(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let identifier = call.arguments as! String
    let api = api!
    runOperation(result) {
      var exercises = [String]()
      for try await exercise in api.listExercises(identifier) {
        guard let data = jsonEncode(PolarExerciseEntryCodable(exercise)) else {
          throw PolarPluginError.serializationFailed
        }
        exercises.append(data)
      }
      return exercises
    }
  }

  func fetchExercise(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let arguments = call.arguments as! [Any]
    let identifier = arguments[0] as! String
    let entry = try! decoder.decode(
      PolarExerciseEntryCodable.self,
      from: (arguments[1] as! String)
        .data(using: .utf8)!
    ).data
    let api = api!
    runOperation(result) {
      let exercise = try await api.fetchExercise(identifier, entry: entry)
      guard let data = jsonEncode(PolarExerciseDataCodable(exercise)) else {
        throw PolarPluginError.serializationFailed
      }
      return data
    }
  }

  func removeExercise(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let arguments = call.arguments as! [Any]
    let identifier = arguments[0] as! String
    let entry = try! decoder.decode(
      PolarExerciseEntryCodable.self,
      from: (arguments[1] as! String)
        .data(using: .utf8)!
    ).data
    let api = api!
    runOperation(result) {
      try await api.removeExercise(identifier, entry: entry)
      return nil
    }
  }

  func setLedConfig(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let arguments = call.arguments as! [Any]
    let identifier = arguments[0] as! String
    let config = try! decoder.decode(
      LedConfigCodable.self,
      from: (arguments[1] as! String)
        .data(using: .utf8)!
    ).data
    let api = api!
    runOperation(result) {
      try await api.setLedConfig(identifier, ledConfig: config)
      return nil
    }
  }

  func doFactoryReset(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let arguments = call.arguments as! [Any]
    let identifier = arguments[0] as! String
    let preservePairingInformation = arguments[1] as! Bool
    let api = api!
    runOperation(result) {
      try await api.doFactoryReset(
        identifier,
        preservePairingInformation: preservePairingInformation
      )
      return nil
    }
  }

  func doRestart(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let identifier = call.arguments as! String
    let api = api!
    runOperation(result) {
      try await api.doRestart(identifier)
      return nil
    }
  }

  func isFeatureReady(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) throws {
    let arguments = call.arguments as! [Any]
    let identifier = arguments[0] as! String
    let feature = try Self.feature(named: arguments[1] as! String)
    result(api.isFeatureReady(identifier, feature: feature))
  }

  func enableSdkMode(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let identifier = call.arguments as! String
    let api = api!
    runOperation(result) {
      try await api.enableSDKMode(identifier)
      return nil
    }
  }

  func disableSdkMode(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let identifier = call.arguments as! String
    let api = api!
    runOperation(result) {
      try await api.disableSDKMode(identifier)
      return nil
    }
  }

  func isSdkModeEnabled(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let identifier = call.arguments as! String
    let api = api!
    runOperation(result) {
      try await api.isSDKModeEnabled(identifier)
    }
  }

  func doFirstTimeUse(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let arguments = call.arguments as! [Any]
    let identifier = arguments[0] as! String
    let config = try! decoder.decode(
      PolarFirstTimeUseConfigCodable.self,
      from: (arguments[1] as! String).data(using: .utf8)!
    ).data
    let api = api!
    runOperation(result) {
      try await api.doFirstTimeUse(identifier, ftuConfig: config)
      return nil
    }
  }

  func isFtuDone(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let identifier = call.arguments as! String
    let api = api!
    runOperation(result) {
      try await api.isFtuDone(identifier)
    }
  }

  private func success(_ event: String, data: Any? = nil) {
    DispatchQueue.main.async {
      for sink in self.sinks {
        sink.value(["event": event, "data": data])
      }
    }
  }

  public func deviceConnecting(_ polarDeviceInfo: PolarDeviceInfo) {
    guard let data = jsonEncode(PolarDeviceInfoCodable(polarDeviceInfo))
    else {
      return
    }
    success("deviceConnecting", data: data)
  }

  public func deviceConnected(_ polarDeviceInfo: PolarDeviceInfo) {
    guard let data = jsonEncode(PolarDeviceInfoCodable(polarDeviceInfo))
    else {
      return
    }
    success("deviceConnected", data: data)
  }

  public func deviceDisconnected(_ polarDeviceInfo: PolarDeviceInfo, pairingError: Bool) {
    guard let data = jsonEncode(PolarDeviceInfoCodable(polarDeviceInfo))
    else {
      return
    }
    success("deviceDisconnected", data: [data, pairingError])
  }

  public func batteryLevelReceived(_ identifier: String, batteryLevel: UInt) {
    success("batteryLevelReceived", data: [identifier, batteryLevel])
  }

  public func batteryChargingStatusReceived(
    _ identifier: String, chargingStatus: BleBasClient.ChargeState
  ) {
    success(
      "batteryChargingStatusReceived", data: [identifier, String(describing: chargingStatus)])
  }

  public func batteryPowerSourcesStateReceived(
    _ identifier: String, powerSourcesState: BleBasClient.PowerSourcesState
  ) {
    // TODO
  }

  public func blePowerOn() {
    success("blePowerStateChanged", data: true)
  }

  public func blePowerOff() {
    success("blePowerStateChanged", data: false)
  }

  public func bleSdkFeatureReady(_ identifier: String, feature: PolarBleSdkFeature) {
    success(
      "sdkFeatureReady",
      data: [identifier, String(describing: feature)])
  }

  public func bleSdkFeaturesReadiness(
    _ identifier: String, ready: [PolarBleSdkFeature], unavailable: [PolarBleSdkFeature]
  ) {
    success(
      "sdkFeaturesReadiness",
      data: [
        identifier,
        ready.map { String(describing: $0) },
        unavailable.map { String(describing: $0) },
      ])
  }

  public func disInformationReceived(_ identifier: String, uuid: CBUUID, value: String) {
    success(
      "disInformationReceived", data: [identifier, uuid.uuidString, value])
  }

  public func disInformationReceivedWithKeysAsStrings(
    _ identifier: String, key: String, value: String
  ) {
    success("disInformationReceived", data: [identifier, key, value])
  }

  // MARK: Deprecated functions

  public func streamingFeaturesReady(
    _ identifier: String, streamingFeatures: Set<PolarBleSdk.PolarDeviceDataType>
  ) {
    // Do nothing
  }

  public func hrFeatureReady(_ identifier: String) {
    // Do nothing
  }

  public func ftpFeatureReady(_ identifier: String) {
    // Do nothing
  }
}

class StreamHandler: NSObject, FlutterStreamHandler {
  let onListen: (Any?, @escaping FlutterEventSink) -> FlutterError?
  let onCancel: (Any?) -> FlutterError?

  init(
    onListen: @escaping (Any?, @escaping FlutterEventSink) -> FlutterError?,
    onCancel: @escaping (Any?) -> FlutterError?
  ) {
    self.onListen = onListen
    self.onCancel = onCancel
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    return onListen(arguments, events)
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    return onCancel(arguments)
  }
}

class StreamingChannel: NSObject, FlutterStreamHandler {
  let api: PolarBleApi
  let identifier: String
  let feature: PolarDeviceDataType
  let channel: FlutterEventChannel

  var streamingTask: Task<Void, Never>?

  init(
    _ messenger: FlutterBinaryMessenger, _ name: String, _ api: PolarBleApi, _ identifier: String,
    _ feature: PolarDeviceDataType
  ) {
    self.api = api
    self.identifier = identifier
    self.feature = feature
    self.channel = FlutterEventChannel(name: name, binaryMessenger: messenger)

    super.init()

    channel.setStreamHandler(self)
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    streamingTask?.cancel()

    // Will be null for some features
    let settings = try? decoder.decode(
      PolarSensorSettingCodable.self,
      from: (arguments as! String)
        .data(using: .utf8)!
    ).data

    switch feature {
    case .ecg:
      startStreaming(api.startEcgStreaming(identifier, settings: settings!), events)
    case .acc:
      startStreaming(api.startAccStreaming(identifier, settings: settings!), events)
    case .ppg:
      startStreaming(api.startPpgStreaming(identifier, settings: settings!), events)
    case .ppi:
      startStreaming(api.startPpiStreaming(identifier), events)
    case .gyro:
      startStreaming(api.startGyroStreaming(identifier, settings: settings!), events)
    case .magnetometer:
      startStreaming(api.startMagnetometerStreaming(identifier, settings: settings!), events)
    case .hr:
      startStreaming(api.startHrStreaming(identifier), events)
    case .temperature:
      startStreaming(api.startTemperatureStreaming(identifier, settings: settings!), events)
    case .pressure:
      startStreaming(api.startPressureStreaming(identifier, settings: settings!), events)
    case .skinTemperature:
      startStreaming(api.startSkinTemperatureStreaming(identifier, settings: settings!), events)
    }

    return nil
  }

  private func startStreaming<Data>(
    _ stream: AsyncThrowingStream<Data, Error>,
    _ events: @escaping FlutterEventSink
  ) {
    streamingTask = Task { [weak self] in
      do {
        for try await sample in stream {
          try Task.checkCancellation()
          guard let data = jsonEncode(PolarDataCodable(sample)) else {
            throw PolarPluginError.serializationFailed
          }
          await MainActor.run {
            guard self?.streamingTask?.isCancelled == false else { return }
            events(data)
          }
        }
        await MainActor.run {
          guard self?.streamingTask?.isCancelled == false else { return }
          events(FlutterEndOfEventStream)
        }
      } catch is CancellationError {
        return
      } catch {
        await MainActor.run {
          guard self?.streamingTask?.isCancelled == false else { return }
          events(
            FlutterError(
              code: "Error while streaming",
              message: error.localizedDescription,
              details: nil
            )
          )
        }
      }
    }
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    streamingTask?.cancel()
    streamingTask = nil
    return nil
  }

  func dispose() {
    streamingTask?.cancel()
    streamingTask = nil
    channel.setStreamHandler(nil)
  }
}
