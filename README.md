# polar

Plugin wrapper for the [Polar SDK](https://github.com/polarofficial/polar-ble-sdk)

## Note

This is an unofficial wrapper for the Polar SDK. For any questions regarding the underlying SDKs or Polar devices in general, please see the [official repository](https://github.com/polarofficial/polar-ble-sdk).

## Getting Started

### Android

The plugin uses Polar BLE SDK 8.4.0 and requires Android API 26 or newer.

android/app/src/main/AndroidManifest.xml:

```xml
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" android:maxSdkVersion="30" />
```

If you use `BLUETOOTH_SCAN` to determine location, remove `android:usesPermissionFlags="neverForLocation"`

If you use location services in your app, remove `android:maxSdkVersion="30"` from the location permission tags

### iOS

Change the deployment target in Xcode to iOS 14+

Podfile:

```ruby
platform :ios, '14.0'
```

Info.plist:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Used to connect to Polar devices</string>
<key>NSBluetoothPeripheralUsageDescription</key>
<string>Used to connect to Polar devices</string>
<key>UIBackgroundModes</key>
<array>
  <string>bluetooth-central</string>
</array>
```

## Usage

`connectToDevice` returns when the native SDK accepts the connection request.
Use `waitForConnection` separately when an operation must wait for the
SDK-managed session to open. The Polar SDK does not apply a timeout to
`waitForConnection`.

<!-- embedme readme/usage.dart -->
```dart
import 'package:flutter/foundation.dart';
import 'package:polar/polar.dart';

const identifier = '1C709B20';
final polar = Polar();

void example() {
  polar.connectToDevice(identifier);
  streamWhenReady();
}

void streamWhenReady() async {
  final readiness = await polar.sdkFeaturesReadiness.firstWhere(
    (e) => e.identifier == identifier,
  );
  if (!readiness.ready.contains(PolarSdkFeature.onlineStreaming)) {
    return;
  }

  final availabletypes = await polar.getAvailableOnlineStreamDataTypes(
    identifier,
  );

  debugPrint('available types: $availabletypes');

  if (availabletypes.contains(PolarDataType.hr)) {
    polar
        .startHrStreaming(identifier)
        .listen((e) => debugPrint('HR data received'));
  }
  if (availabletypes.contains(PolarDataType.ecg)) {
    polar
        .startEcgStreaming(identifier)
        .listen((e) => debugPrint('ECG data received'));
  }
  if (availabletypes.contains(PolarDataType.acc)) {
    polar
        .startAccStreaming(identifier)
        .listen((e) => debugPrint('ACC data received'));
  }
}

```

`doRestart` restarts a supported device without restoring factory defaults and
requires `PolarSdkFeature.deviceControl` to be ready. Its completion only
confirms that the restart command was accepted or caused the expected
disconnection; wait for a new connection and feature readiness before using the
device again. `doRestart` and `doFactoryReset` are separate operations.

The example app uses `flutter_reactive_ble` only to discover and display nearby
devices. Connections, disconnections, feature readiness, and Polar 360 restart
requests are handled exclusively through this plugin and the Polar SDK.

The example persists the identifier accepted by `connectToDevice` together with
the advertised name. On a later launch it sends a new connection request for
that identifier and derives connection state and feature readiness from SDK
callbacks. Persisting an identifier does not imply that the device is connected
or paired.

For Polar 360, the example also provides a separately confirmed destructive
action that calls `doFactoryReset(identifier, false)`. This removes pairing
information so the device can be configured by another phone. It is never used
as the normal disconnect action, and command completion does not mean that the
reset has finished.