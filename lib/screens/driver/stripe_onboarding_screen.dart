import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../l10n/app_localizations.dart';
import '../../widgets/neu_style.dart';

/// Stripe's identity check, inside Cruise instead of in the browser.
///
/// The page itself is Stripe's and has to be — Express connected accounts
/// cannot have their KYC submitted through our own fields, so this is the one
/// screen in the payout flow we do not own. What we do own is the frame: the
/// driver keeps our header and our back button, and never watches the app
/// hand them to Safari and lose the thread.
///
/// Pops `true` once Stripe redirects to one of our return URLs, so the caller
/// can go straight on to the bank form instead of asking the driver to start
/// again.
class StripeOnboardingScreen extends StatefulWidget {
  const StripeOnboardingScreen({super.key, required this.url});

  final String url;

  @override
  State<StripeOnboardingScreen> createState() => _StripeOnboardingScreenState();
}

class _StripeOnboardingScreenState extends State<StripeOnboardingScreen> {
  late final WebViewController _controller;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) setState(() => _loading = true);
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _loading = false);
          },
          onNavigationRequest: (req) {
            // The backend builds the AccountLink with return_url and
            // refresh_url on our own domain, so a hop back to either is
            // Stripe saying it is finished with the driver. Close on it
            // rather than rendering a page of ours inside this frame.
            if (req.url.contains('/driver/bank-connected') ||
                req.url.contains('/driver/onboarding')) {
              if (mounted) Navigator.of(context).pop(true);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: neuBase,
      appBar: AppBar(
        backgroundColor: neuBase,
        elevation: 0,
        title: Text(
          S.of(context).verifyYourIdentity,
          style: const TextStyle(
              color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          // false, not true: backing out is not completing it. The caller
          // must not go on to the bank form as though Stripe had finished.
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_loading)
            const Center(
              child: CircularProgressIndicator(color: Color(0xFFE8C547)),
            ),
        ],
      ),
    );
  }
}
