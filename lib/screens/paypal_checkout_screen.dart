import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:webview_flutter/webview_flutter.dart';
import '../config/env.dart';

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
      final baseUrl = Env.paypalSandbox
          ? 'https://api-m.sandbox.paypal.com'
          : 'https://api-m.paypal.com';

      // 1 — get access token
      final tokenRes = await http.post(
        Uri.parse('$baseUrl/v1/oauth2/token'),
        headers: {
          'Authorization':
              'Basic ${base64Encode(utf8.encode('${Env.paypalClientId}:${Env.paypalSecret}'))}',
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: 'grant_type=client_credentials',
      );
      if (tokenRes.statusCode != 200) {
        throw Exception('PayPal auth failed (${tokenRes.statusCode})');
      }
      final accessToken = jsonDecode(tokenRes.body)['access_token'] as String;

      // 2 — create payment / order
      final payRes = await http.post(
        Uri.parse('$baseUrl/v1/payments/payment'),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'intent': 'sale',
          'payer': {'payment_method': 'paypal'},
          'transactions': [
            {
              'amount': {'total': widget.amount, 'currency': widget.currency},
              'description': widget.description,
            },
          ],
          'redirect_urls': {'return_url': _returnUrl, 'cancel_url': _cancelUrl},
        }),
      );
      if (payRes.statusCode != 201) {
        throw Exception('PayPal order failed (${payRes.statusCode})');
      }
      final body = jsonDecode(payRes.body) as Map<String, dynamic>;
      final links = body['links'] as List<dynamic>;
      final approvalUrl =
          links.firstWhere((l) => l['rel'] == 'approval_url')['href'] as String;

      // 3 — load approval URL in WebView
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
        title: const Text(
          'PayPal',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
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
                      'Could not connect to PayPal.\n\n'
                      'Make sure your PayPal credentials are set in env.dart.',
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
                      child: const Text('Retry'),
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
