import 'package:flutter/widgets.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';

/// What a driver reads when a list fails to load — never the raw exception.
///
/// 2026-10-31 (owner screenshot): with no signal, the scheduled-rides sheet
/// printed "ClientException with SocketException: HTTP connection timed out
/// after 0:00:03.000000, host: cruiseapp2-production…, uri=…". A dead socket,
/// a timeout, a TLS failure or a 5xx during a redeploy all read the same to
/// the driver: the rides could not load, check the signal, try again.
///
/// [pendingOn403]: the marketplace answers 403 to an account that is not
/// approved yet — that one is a real reason, not a failure, and has its own
/// copy. The raw error still goes to the debug log.
String friendlyLoadError(BuildContext context, Object error,
    {bool pendingOn403 = false}) {
  debugPrint('[LoadError] $error');
  final s = S.of(context);
  if (pendingOn403 && error is ApiException && error.statusCode == 403) {
    return s.accountPendingDesc;
  }
  return s.loadRidesFailed;
}
