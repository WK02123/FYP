import 'package:flutter/material.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:cloud_functions/cloud_functions.dart';


class CheckoutDemoPage extends StatefulWidget {
  const CheckoutDemoPage({super.key});

  @override
  State<CheckoutDemoPage> createState() => _CheckoutDemoPageState();
}

class _CheckoutDemoPageState extends State<CheckoutDemoPage> {
  bool _loading = false;
  String? _lastError;

  Future<void> _pay({required int amountSen}) async {
    setState(() {
      _loading = true;
      _lastError = null;
    });

    try {
      // 1️⃣ Call your Cloud Function to create a PaymentIntent
      final fun = FirebaseFunctions.instanceFor(region: 'asia-southeast1')
          .httpsCallable('createPaymentIntent');

      final resp = await fun.call({
        'amount': amountSen, // e.g. RM 5.00 -> 500 sen
        'currency': 'myr',
        'description': 'Shuttle Ticket Payment',
      });

      final data = Map<String, dynamic>.from(resp.data);
      final clientSecret = data['clientSecret'] as String?;

      if (clientSecret == null || clientSecret.isEmpty) {
        throw Exception('No clientSecret returned from server');
      }

      // 2️⃣ Initialize the payment sheet
      await Stripe.instance.initPaymentSheet(
        paymentSheetParameters: SetupPaymentSheetParameters(
          paymentIntentClientSecret: clientSecret,
          merchantDisplayName: 'Ridemate Shuttle',
          style: ThemeMode.system,
          allowsDelayedPaymentMethods: false,
        ),
      );

      // 3️⃣ Present the sheet
      await Stripe.instance.presentPaymentSheet();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ Payment successful!')),
      );
    } on StripeException catch (e) {
      setState(() => _lastError = e.error.localizedMessage);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Stripe error: ${e.error.localizedMessage}')),
      );
    } catch (e) {
      setState(() => _lastError = e.toString());
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Payment failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Stripe Payment Test'),
        backgroundColor: const Color(0xFFD32F2F),
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: _loading
            ? const CircularProgressIndicator()
            : Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFD32F2F),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                    horizontal: 24, vertical: 14),
              ),
              onPressed: () => _pay(amountSen: 500), // RM 5.00
              child: const Text('Pay RM 5.00'),
            ),
            const SizedBox(height: 20),
            if (_lastError != null)
              Text(
                _lastError!,
                style: const TextStyle(color: Colors.red),
                textAlign: TextAlign.center,
              ),
          ],
        ),
      ),
    );
  }
}
