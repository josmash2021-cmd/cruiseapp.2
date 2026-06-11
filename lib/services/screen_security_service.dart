import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';

import 'dart:math' as math;

/// Enables/disables Android FLAG_SECURE to prevent screenshots/recording.
/// Uses a reference counter so multiple secure screens can overlap safely.
/// iOS has no public API for this; calls are no-ops on iOS and web.
class ScreenSecurityService {
  static const _channel = MethodChannel('com.cruiseinride.app/screen_security');
  static int _refCount = 0;

  static Future<void> setSecure(bool secure) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    if (secure) {
      _refCount++;
    } else {
      _refCount = math.max(0, _refCount - 1);
    }
    try {
      await _channel.invokeMethod('setSecure', {'secure': _refCount > 0});
    } catch (_) {
      // Ignore native errors gracefully
    }
  }
}

/// Mixin for StatefulWidgets that should block screenshots while visible.
mixin SecureScreenMixin<T extends StatefulWidget> on State<T> {
  @override
  void initState() {
    super.initState();
    ScreenSecurityService.setSecure(true);
  }

  @override
  void dispose() {
    ScreenSecurityService.setSecure(false);
    super.dispose();
  }
}
