import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';

/// PayPal checkout screen.
///
/// Creates a PayPal order via REST API and shows the approval page in a
/// WebView. Detects the success/cancel redirect URL and closes accordingly.
///
/// Usage:
/// ```dart
/// final result = await Navigator.of(context).push<bool>(
///   MaterialPageRoute(
///     builder: (_) => PayPalCheckoutScreen(
///       amount: '1.00',
///       currency: 'USD',
///       description: 'Account verification',
///     ),
///   ),
/// );
/// if (result == true) { /* payment approved */ }
/// ```
class PayPalCheckoutScreen extends StatefulWidget {
  final String amount;
  final String currency;
  final String description;

  const PayPalCheckoutScreen({
    super.key,
    required this.amount,
    required this.currency,
    this.description = 'Cruise ride payment',
  });

  @override
  State<PayPalCheckoutScreen> createState() => _PayPalCheckoutScreenState();
}

class _PayPalCheckoutScreenState extends State<PayPalCheckoutScreen> {
  static const _returnUrl = 'https://cruise-app.com/paypal/success';
  static const _cancelUrl = 'https://cruise-app.com/paypal/cancel';
  static const _gold = Color(0xFFE8C547);

  late final WebViewController _controller;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final url = request.url;
            if (url.startsWith(_returnUrl)) {
              Navigator.of(context).pop(true);
              return NavigationDecision.prevent;
            }
            if (url.startsWith(_cancelUrl)) {
              Navigator.of(context).pop(false);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _loading = false);
          },
        ),
      );
    _createOrder();
  }

  Future<void> _createOrder() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Use backend proxy to create PayPal order (secrets stay server-side)
      final response = await ApiService.createPayPalOrder(
        amount: widget.amount,
        currency: widget.currency,
      );

      if (response == null ||
          response['approval_url'] == null ||
          (response['approval_url'] as String).isEmpty) {
        throw Exception('PayPal order creation failed');
      }

      final approvalUrl = response['approval_url'] as String;

      // Load approval URL in WebView
      await _controller.loadRequest(Uri.parse(approvalUrl));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          S.of(context).paypal,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ),
      body: Stack(
        children: [
          if (_error != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      color: Colors.red,
                      size: 48,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '${S.of(context).couldNotConnectPaypal}\n\n${S.of(context).checkPaypalCredentials}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton(
                      onPressed: _createOrder,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _gold,
                        foregroundColor: Colors.black,
                      ),
                      child: Text(S.of(context).retry),
                    ),
                  ],
                ),
              ),
            )
          else
            WebViewWidget(controller: _controller),
          if (_loading && _error == null)
            const Center(child: CircularProgressIndicator(color: _gold)),
        ],
      ),
    );
  }
}
