// lib/env.dart
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';

class Env {
  // Flip at build/run time with: --dart-define=USE_EMU=true or false
  static const bool useEmu = bool.fromEnvironment('USE_EMU', defaultValue: true);

  static const String project = 'shuttlebus-e0cef';
  static const String region  = 'asia-southeast1';

  static String functionsBase() {
    if (useEmu) {
      final host = kIsWeb ? '127.0.0.1' : (Platform.isAndroid ? '10.0.2.2' : '127.0.0.1');
      return 'http://$host:5001/$project/$region';
    } else {
      return 'https://$region-$project.cloudfunctions.net';
    }
  }
}
