import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/driver_rest_service.dart';

mixin DriverRestGate<T extends StatefulWidget> on State<T> {
  Timer? _driverRestTimer;
  int _driverRestSyncTicks = 0;

  Duration get driverRestRemaining => DriverRestService.remaining;
  bool get driverIsResting => driverRestRemaining > Duration.zero;

  String get driverRestLabel =>
      '${S.of(context).restTitle} ${DriverRestService.format(driverRestRemaining)}';

  void initDriverRestGate() {
    DriverRestService.restUntil.addListener(_syncDriverRestTimer);
    unawaited(DriverRestService.restore().then((_) async {
      await DriverRestService.refresh();
    }));
    _syncDriverRestTimer();
  }

  void disposeDriverRestGate() {
    DriverRestService.restUntil.removeListener(_syncDriverRestTimer);
    _driverRestTimer?.cancel();
  }

  void _syncDriverRestTimer() {
    if (!mounted) return;
    if (driverIsResting) {
      _driverRestTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        _driverRestSyncTicks++;
        if (_driverRestSyncTicks >= 15) {
          _driverRestSyncTicks = 0;
          unawaited(DriverRestService.refresh());
        }
        if (!driverIsResting) {
          unawaited(DriverRestService.set(null));
          return;
        }
        setState(() {});
      });
    } else {
      _driverRestTimer?.cancel();
      _driverRestTimer = null;
    }
    setState(() {});
  }

  void showDriverRestRemaining() {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(S
          .of(context)
          .restRemainingLabel(DriverRestService.format(driverRestRemaining))),
      behavior: SnackBarBehavior.floating,
    ));
  }

  void syncDriverRestRefusal() {
    unawaited(DriverRestService.refresh());
    showDriverRestRemaining();
  }
}
