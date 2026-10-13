import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:polar/polar.dart';
import 'package:recase/recase.dart';

/// Read a value from a JSON object keyed based on the platform
Object? readPlatformValue(Map json, Map<TargetPlatform, String> keys) {
  final key = keys[defaultTargetPlatform];
  if (key == null) {
    throw UnsupportedError('Unsupported platform: $defaultTargetPlatform');
  }
  return json[key];
}

/// Write a value to a JSON object keyed based on the platform
Map<String, dynamic> writePlatformValue(
  Map<TargetPlatform, String> keys,
  Object? value,
) {
  final key = keys[defaultTargetPlatform];
  if (key == null) {
    throw UnsupportedError('Unsupported platform: $defaultTargetPlatform');
  }
  return {key: value};
}

/// Converts platform values to booleans
/// - The iOS SDK uses `0` and `1` for booleans
/// - The Android SDK uses `true` and `false` for booleans
class PlatformBooleanConverter extends JsonConverter<bool, dynamic> {
  /// Constructor
  const PlatformBooleanConverter();

  @override
  bool fromJson(dynamic json) {
    if (Platform.isIOS) {
      return json != 0;
    } else {
      return json;
    }
  }

  @override
  dynamic toJson(bool object) {
    if (Platform.isIOS) {
      return object ? 1 : 0;
    } else {
      return object;
    }
  }
}

/// Converter for [PpgDataType]
class PpgDataTypeConverter extends JsonConverter<PpgDataType, dynamic> {
  /// Constructor
  const PpgDataTypeConverter();

  @override
  PpgDataType fromJson(dynamic json) {
    if (Platform.isIOS) {
      switch (json as int) {
        case 4:
          return PpgDataType.ppg3_ambient1;
        default: // 18
          return PpgDataType.unknown;
      }
    } else {
      // This is android
      return PpgDataType.values.byName((json as String).toLowerCase());
    }
  }

  @override
  dynamic toJson(PpgDataType object) {
    if (Platform.isIOS) {
      switch (object) {
        case PpgDataType.ppg3_ambient1:
          return 4;
        default: // PpgDataType.unknown
          return 18;
      }
    } else {
      // This is android
      return object.name.snakeCase.toUpperCase();
    }
  }
}

/// Converter for unix time
class UnixTimeConverter extends JsonConverter<DateTime, int> {
  /// Constructor
  const UnixTimeConverter();

  @override
  DateTime fromJson(int json) => DateTime.fromMillisecondsSinceEpoch(json);

  @override
  int toJson(DateTime object) => object.millisecondsSinceEpoch;
}

/// Converter for FTU birth dates.
///
/// iOS expects unix milliseconds while Android expects a local date object.
class FtuBirthDateConverter extends JsonConverter<DateTime, Object> {
  /// Constructor
  const FtuBirthDateConverter();

  @override
  DateTime fromJson(Object json) {
    if (json is int) {
      return DateTime.fromMillisecondsSinceEpoch(json);
    }

    if (json is Map) {
      final year = json['year'] as int?;
      final month = json['month'] as int?;
      final day = json['day'] as int?;

      if (year == null || month == null || day == null) {
        throw const FormatException('Invalid FTU birthDate payload');
      }

      return DateTime(year, month, day);
    }

    throw FormatException('Unsupported FTU birthDate payload: $json');
  }

  @override
  Object toJson(DateTime object) {
    if (Platform.isIOS) {
      return object.millisecondsSinceEpoch;
    }

    return <String, int>{
      'year': object.year,
      'month': object.month,
      'day': object.day,
    };
  }
}

/// Converter for FTU device time.
///
/// Both platforms accept ISO 8601 strings when the native bridge parses them.
class IsoDateTimeConverter extends JsonConverter<DateTime, String> {
  /// Constructor
  const IsoDateTimeConverter();

  @override
  DateTime fromJson(String json) => DateTime.parse(json);

  @override
  String toJson(DateTime object) {
    final iso = object.toUtc().toIso8601String();
    // Polar SDK parses deviceTime at second precision only; strip sub-seconds.
    final dot = iso.indexOf('.');
    return dot != -1 ? '${iso.substring(0, dot)}Z' : iso;
  }
}

/// Converter for [PolarSettingType]
class PolarSettingTypeConverter
    extends JsonConverter<PolarSettingType, String> {
  /// Constructor
  const PolarSettingTypeConverter();

  @override
  PolarSettingType fromJson(String json) {
    if (Platform.isIOS) {
      return PolarSettingType.values[int.parse(json)];
    } else {
      // This is android
      return PolarSettingType.values.byName(json.camelCase);
    }
  }

  @override
  String toJson(PolarSettingType object) {
    if (Platform.isIOS) {
      return object.index.toString();
    } else {
      // This is android
      return object.name.snakeCase.toUpperCase();
    }
  }
}

final _polarEpoch = DateTime(2000).microsecondsSinceEpoch;

/// Convert polar sample timestamps to [DateTime]
///
/// Moment sample is taken in nanoseconds. The epoch of timestamp is 1.1.2000
class PolarSampleTimestampConverter extends JsonConverter<DateTime, int> {
  /// Constructor
  const PolarSampleTimestampConverter();

  @override
  DateTime fromJson(int json) {
    final millis = json ~/ 1000;
    return DateTime.fromMicrosecondsSinceEpoch(_polarEpoch + millis);
  }

  @override
  int toJson(DateTime object) {
    final millis = object.microsecondsSinceEpoch - _polarEpoch;
    return millis * 1000;
  }
}
