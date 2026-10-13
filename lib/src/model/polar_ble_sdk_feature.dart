import 'package:flutter/foundation.dart';

/// Features available in Polar BLE SDK library
enum PolarSdkFeature {
  /// Hr feature to receive hr and rr data from Polar or any other BLE device
  /// via standard HR BLE service
  hr,

  /// Device information feature to receive sw information from Polar or any
  /// other BLE device
  deviceInfo,

  /// Feature to receive battery level info from Polar or any other BLE device
  batteryInfo,

  /// Polar sensor streaming feature to stream live online data. For example
  /// hr, ecg, acc, ppg, ppi, etc...
  onlineStreaming,

  /// Polar offline recording feature to record offline data to Polar device
  /// without continuous BLE connection.
  offlineRecording,

  /// H10 exercise recording feature to record exercise data to Polar H10
  /// device without continuous BLE connection.
  h10ExerciseRecording,

  /// Offline exercise recording using the Data Merge protocol.
  offlineExerciseV2,

  /// Feature to read and set device time in Polar device
  deviceTimeSetup,

  /// In SDK mode the wider range of capabilities are available for the online
  /// stream or offline recoding than in normal operation mode.
  sdkMode,

  /// Feature to enable or disable SDK mode blinking LED animation.
  ledAnimation,

  /// Firmware update for Polar device.
  firmwareUpdate,

  /// Feature to receive activity data from Polar device.
  activityData,

  /// Feature to transfer files to and from Polar device.
  fileTransfer,

  /// Feature to receive HTS data from Polar device.
  hts,

  /// Feature to receive sleep data from Polar device.
  sleepData,

  /// Feature to receive temperature data from Polar device.
  temperatureData,

  /// Feature to receive SPO2 test data from Polar device.
  spo2TestData,

  /// Feature to access training session data and exercise session controls.
  trainingData,

  /// Feature to control device power and restart behavior.
  deviceControl,

  /// Feature to read and set device configuration through Polar Features
  /// Configuration Service.
  featuresConfigurationService,

  /// Feature to configure watch face complications.
  watchFacesConfiguration,

  /// Feature to receive device telemetry data.
  telemetry,

  /// Android-only Companion Device Manager integration.
  companionDeviceManagement;

  String get _androidName => switch (this) {
    hr => 'FEATURE_HR',
    deviceInfo => 'FEATURE_DEVICE_INFO',
    batteryInfo => 'FEATURE_BATTERY_INFO',
    onlineStreaming => 'FEATURE_POLAR_ONLINE_STREAMING',
    offlineRecording => 'FEATURE_POLAR_OFFLINE_RECORDING',
    h10ExerciseRecording => 'FEATURE_POLAR_H10_EXERCISE_RECORDING',
    offlineExerciseV2 => 'FEATURE_POLAR_OFFLINE_EXERCISE_V2',
    deviceTimeSetup => 'FEATURE_POLAR_DEVICE_TIME_SETUP',
    sdkMode => 'FEATURE_POLAR_SDK_MODE',
    ledAnimation => 'FEATURE_POLAR_LED_ANIMATION',
    firmwareUpdate => 'FEATURE_POLAR_FIRMWARE_UPDATE',
    activityData => 'FEATURE_POLAR_ACTIVITY_DATA',
    fileTransfer => 'FEATURE_POLAR_FILE_TRANSFER',
    hts => 'FEATURE_HTS',
    sleepData => 'FEATURE_POLAR_SLEEP_DATA',
    temperatureData => 'FEATURE_POLAR_TEMPERATURE_DATA',
    spo2TestData => 'FEATURE_POLAR_SPO2_TEST_DATA',
    trainingData => 'FEATURE_POLAR_TRAINING_DATA',
    deviceControl => 'FEATURE_POLAR_DEVICE_CONTROL',
    featuresConfigurationService =>
      'FEATURE_POLAR_FEATURES_CONFIGURATION_SERVICE',
    watchFacesConfiguration => 'FEATURE_WATCH_FACES_CONFIGURATION',
    telemetry => 'FEATURE_TELEMETRY',
    companionDeviceManagement => 'FEATURE_COMPANION_DEVICE_MANAGEMENT',
  };

  /// Create a [PolarSdkFeature] from json
  static PolarSdkFeature fromJson(dynamic json) {
    final nativeName = (json as String).toUpperCase();
    return values.firstWhere(
      (feature) =>
          feature._androidName == nativeName ||
          feature._iosName?.toUpperCase() == nativeName,
      orElse: () =>
          throw ArgumentError.value(json, 'json', 'Unknown Polar SDK feature'),
    );
  }

  /// Convert a [PolarSdkFeature] to json
  String toJson([TargetPlatform? platform]) {
    if ((platform ?? defaultTargetPlatform) == TargetPlatform.iOS) {
      return _iosName ??
          (throw UnsupportedError('$name is not available on iOS'));
    }
    return _androidName;
  }

  String? get _iosName => switch (this) {
    hr => 'feature_hr',
    deviceInfo => 'feature_device_info',
    batteryInfo => 'feature_battery_info',
    onlineStreaming => 'feature_polar_online_streaming',
    offlineRecording => 'feature_polar_offline_recording',
    h10ExerciseRecording => 'feature_polar_h10_exercise_recording',
    offlineExerciseV2 => 'feature_polar_offline_exercise_v2',
    deviceTimeSetup => 'feature_polar_device_time_setup',
    sdkMode => 'feature_polar_sdk_mode',
    ledAnimation => 'feature_polar_led_animation',
    firmwareUpdate => 'feature_polar_firmware_update',
    activityData => 'feature_polar_activity_data',
    fileTransfer => 'feature_polar_file_transfer',
    hts => 'feature_hts',
    sleepData => 'feature_polar_sleep_data',
    temperatureData => 'feature_polar_temperature_data',
    spo2TestData => 'feature_polar_spo2_test_data',
    trainingData => 'feature_polar_training_data',
    deviceControl => 'feature_polar_device_control',
    featuresConfigurationService =>
      'feature_polar_features_configuration_service',
    watchFacesConfiguration => 'feature_polar_watch_faces_configuration',
    telemetry => 'feature_telemetry_data_streaming',
    companionDeviceManagement => null,
  };
}
