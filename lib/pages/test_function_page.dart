// lib/pages/test_function_page.dart
import 'package:flutter/material.dart';
import 'package:cloud_functions/cloud_functions.dart';

class TestFunctionPage extends StatelessWidget {
  final FirebaseFunctions functions;
  const TestFunctionPage({super.key, required this.functions});

  Future<void> _testPayment() async {
    try {
      final result = await functions.httpsCallable('createPaymentIntent').call({
        'amount': 500,          // RM 5.00 if currency = MYR
        'currency': 'myr',
        'description': 'Bus Ticket',
      });
      debugPrint('✅ Cloud Function result: ${result.data}');
    } catch (e) {
      debugPrint('❌ Error calling function: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Test Cloud Function')),
      body: Center(
        child: ElevatedButton(
          onPressed: _testPayment,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red,
            foregroundColor: Colors.white,
          ),
          child: const Text('Call createPaymentIntent'),
        ),
      ),
    );
  }
}
