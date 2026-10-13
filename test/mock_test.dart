import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:polar/polar.dart';

import 'tests.dart';

const identifier = 'asdf';
final info = jsonEncode(
  const PolarDeviceInfo(
    deviceId: identifier,
    address: '',
    rssi: 0,
    name: '',
    isConnectable: true,
  ),
);
const methodChannel = MethodChannel('polar/methods');
const eventChannel = EventChannel('polar/events');
const searchChannel = EventChannel('polar/search');

final eventHandler = EventHandler();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, handleMethodCall);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(eventChannel, eventHandler);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(searchChannel, SearchHandler());
  });

  testSearch(identifier);
  testConnection(identifier);
  testBasicData(
    identifier,
    expectedChargeState: PolarChargeState.dischargingActive,
  );
  testBleSdkFeatures(identifier, features: PolarSdkFeature.values.toSet());
  testStreaming(identifier, features: PolarDataType.values.toSet());
  testRecording(identifier, wait: false);
  testSdkMode(identifier);
  testMisc(identifier, supportsLedConfig: true);
  testFtu(identifier);

  test('feature names match both native platforms', () {
    for (final feature in PolarSdkFeature.values) {
      final androidName = feature.toJson(TargetPlatform.android);
      expect(PolarSdkFeature.fromJson(androidName), feature);

      if (feature == PolarSdkFeature.companionDeviceManagement) {
        expect(
          () => feature.toJson(TargetPlatform.iOS),
          throwsUnsupportedError,
        );
      } else {
        final iosName = feature.toJson(TargetPlatform.iOS);
        expect(PolarSdkFeature.fromJson(iosName), feature);
      }
    }

    expect(
      PolarSdkFeature.telemetry.toJson(TargetPlatform.android),
      'FEATURE_TELEMETRY',
    );
    expect(
      PolarSdkFeature.telemetry.toJson(TargetPlatform.iOS),
      'feature_telemetry_data_streaming',
    );
  });

  test(
    'connection and device control methods use distinct native calls',
    () async {
      factoryResetRequested = false;
      restartRequested = false;
      await polar.setAutomaticReconnection(false);
      expect(automaticReconnection, false);
      await polar.waitForConnection(identifier, requestPermissions: false);
      expect(
        await polar.isFeatureReady(identifier, PolarSdkFeature.deviceControl),
        true,
      );

      await polar.doRestart(identifier);
      expect(restartRequested, true);
      expect(factoryResetRequested, false);
    },
  );

  test('connectToDevice propagates immediate native errors', () async {
    connectError = PlatformException(
      code: 'invalid_identifier',
      message: 'Invalid device identifier',
    );
    addTearDown(() => connectError = null);

    await expectLater(
      polar.connectToDevice(identifier, requestPermissions: false),
      throwsA(isA<PlatformException>()),
    );
  });

  test('factory reset can explicitly remove pairing information', () async {
    factoryResetRequested = false;
    preservePairingInformation = null;

    await polar.doFactoryReset(identifier, false);

    expect(factoryResetRequested, true);
    expect(preservePairingInformation, false);
  });
}

final exercises = <PolarExerciseEntry>[];
var recording = false;
var exerciseId = '';
var sdkModeEnabled = false;
var automaticReconnection = true;
var factoryResetRequested = false;
var restartRequested = false;
bool? preservePairingInformation;
PlatformException? connectError;

Future<dynamic> handleMethodCall(MethodCall call) async {
  switch (call.method) {
    case 'connectToDevice':
      final error = connectError;
      if (error != null) throw error;
      return null;
    case 'waitForConnection':
      return null;
    case 'setAutomaticReconnection':
      automaticReconnection = call.arguments as bool;
      return null;
    case 'disconnectFromDevice':
      eventHandler.emitDisconnected();
      return null;
    case 'isFeatureReady':
      final arguments = call.arguments as List<Object?>;
      return PolarSdkFeature.fromJson(arguments[1]) !=
          PolarSdkFeature.companionDeviceManagement;
    case 'getAvailableOnlineStreamDataTypes':
      return jsonEncode(PolarDataType.values.map((e) => e.toJson()).toList());
    case 'requestStreamSettings':
      return jsonEncode(PolarSensorSetting(const {}));
    case 'createStreamingChannel':
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(
            EventChannel(call.arguments[0] as String),
            StreamingHandler(PolarDataType.fromJson(call.arguments[2])),
          );
      return null;
    case 'startRecording':
      recording = true;
      exerciseId = call.arguments[1];
      return null;
    case 'stopRecording':
      recording = false;
      exercises.add(
        PolarExerciseEntry(
          path: '',
          date: DateTime.timestamp(),
          entryId: exerciseId,
        ),
      );
      return null;
    case 'requestRecordingStatus':
      return [recording, exerciseId];
    case 'listExercises':
      return exercises.map(jsonEncode).toList();
    case 'fetchExercise':
      return jsonEncode({
        'recordingInterval': 0,
        'hrSamples': [0],
      });
    case 'removeExercise':
      exercises.clear();
      return null;
    case 'setLedConfig':
      return null;
    case 'enableSdkMode':
      sdkModeEnabled = true;
      return null;
    case 'disableSdkMode':
      sdkModeEnabled = false;
      return null;
    case 'isSdkModeEnabled':
      return sdkModeEnabled;
    case 'doFactoryReset':
      factoryResetRequested = true;
      preservePairingInformation = (call.arguments as List<Object?>)[1] as bool;
      return null;
    case 'doRestart':
      restartRequested = true;
      return null;
    case 'doFirstTimeUse':
      final payload =
          jsonDecode(call.arguments[1] as String) as Map<String, dynamic>;
      expect(payload['birthDate'], {'year': 1990, 'month': 1, 'day': 1});
      expect(payload['deviceTime'], isA<String>());
      return null;
    case 'isFtuDone':
      return true;
    case 'shutDown':
      return null;
    default:
      throw UnimplementedError();
  }
}

class EventHandler extends MockStreamHandler {
  MockStreamHandlerEventSink? _sink;

  @override
  void onListen(dynamic arguments, MockStreamHandlerEventSink events) {
    _sink = events;
  }

  @override
  void onCancel(dynamic arguments) {
    _sink = null;
  }

  void emitConnecting() {
    _sink?.success({'event': 'deviceConnecting', 'data': info});
  }

  void emitConnected() {
    _sink?.success({'event': 'deviceConnected', 'data': info});
    _sink?.success({
      'event': 'disInformationReceived',
      'data': [identifier, '', ''],
    });
    _sink?.success({
      'event': 'batteryLevelReceived',
      'data': [identifier, 100],
    });
    _sink?.success({
      'event': 'batteryChargingStatusReceived',
      'data': [identifier, PolarChargeState.dischargingActive.toJson()],
    });
    for (final feature in PolarSdkFeature.values) {
      _sink?.success({
        'event': 'sdkFeatureReady',
        'data': [identifier, feature.toJson()],
      });
    }
    _sink?.success({
      'event': 'sdkFeaturesReadiness',
      'data': [
        identifier,
        PolarSdkFeature.values.map((e) => e.toJson()).toList(),
        <String>[],
      ],
    });
  }

  void emitDisconnected() {
    _sink?.success({
      'event': 'deviceDisconnected',
      'data': [info, false],
    });
  }
}

class SearchHandler extends MockStreamHandler {
  @override
  void onListen(dynamic arguments, MockStreamHandlerEventSink events) {
    events.success(info);
  }

  @override
  void onCancel(dynamic arguments) {}
}

@immutable
class StreamingHandler extends MockStreamHandler {
  final PolarDataType type;

  const StreamingHandler(this.type);

  @override
  void onListen(dynamic arguments, MockStreamHandlerEventSink events) {
    final PolarStreamingData data;
    switch (type) {
      case PolarDataType.ecg:
        data = PolarEcgData(
          samples: [
            PolarEcgSample(timeStamp: DateTime.timestamp(), voltage: 0),
          ],
        );
      case PolarDataType.acc:
        data = PolarAccData(
          samples: [
            PolarAccSample(timeStamp: DateTime.timestamp(), x: 0, y: 0, z: 0),
          ],
        );
      case PolarDataType.ppg:
        data = PolarPpgData(
          type: PpgDataType.ppg3_ambient1,
          samples: [
            PolarPpgSample(
              timeStamp: DateTime.timestamp(),
              channelSamples: const [],
              statusBits: const [],
            ),
          ],
        );
      case PolarDataType.ppi:
        data = const PolarPpiData(
          samples: [
            PolarPpiSample(
              timeStamp: 0,
              ppi: 0,
              errorEstimate: 0,
              hr: 0,
              blockerBit: false,
              skinContactStatus: false,
              skinContactSupported: false,
            ),
          ],
        );
      case PolarDataType.gyro:
        data = PolarGyroData(
          samples: [
            PolarGyroSample(timeStamp: DateTime.timestamp(), x: 0, y: 0, z: 0),
          ],
        );
      case PolarDataType.magnetometer:
        data = PolarMagnetometerData(
          samples: [
            PolarMagnetometerSample(
              timeStamp: DateTime.timestamp(),
              x: 0,
              y: 0,
              z: 0,
            ),
          ],
        );
      case PolarDataType.hr:
        data = const PolarHrData(
          samples: [
            PolarHrSample(
              hr: 0,
              ppgQuality: 0,
              correctedHr: 0,
              rrsMs: [],
              contactStatus: false,
              contactStatusSupported: false,
            ),
          ],
        );
      case PolarDataType.temperature:
        data = PolarTemperatureData(
          samples: [
            PolarTemperatureSample(
              timeStamp: DateTime.timestamp(),
              temperature: 0,
            ),
          ],
        );
      case PolarDataType.pressure:
        data = PolarPressureData(
          samples: [
            PolarPressureSample(timeStamp: DateTime.timestamp(), pressure: 0),
          ],
        );
      case PolarDataType.skinTemperature:
        data = PolarTemperatureData(
          samples: [
            PolarTemperatureSample(
              timeStamp: DateTime.timestamp(),
              temperature: 0,
            ),
          ],
        );
      case PolarDataType.location:
        data = PolarLocationData(
          samples: [
            PolarLocationDataSample(
              timeStamp: DateTime.timestamp(),
              latitude: 0,
              longitude: 0,
              time: '',
              speed: 0,
              cumulativeDistance: 0,
              usedAccelerationSpeed: 0,
              coordinateSpeed: 0,
              accelerationSpeedFactor: 0,
              course: 0,
              gpsChipSpeed: 0,
              fix: true,
              speedFlag: 0,
              fusionState: 0,
            ),
          ],
        );
    }

    events.success(jsonEncode(data));
  }

  @override
  void onCancel(dynamic arguments) {}
}
