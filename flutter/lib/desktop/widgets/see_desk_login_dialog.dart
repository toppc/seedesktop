import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_hbb/utils/license_manager.dart';

Future<void> showSeeDeskLoginDialog(BuildContext context) async {
  final formKey = GlobalKey<FormState>();
  final controller = TextEditingController();
  bool loading = false;
  String? errorText;

  await showDialog<void>(
    context: context,
    barrierDismissible: !loading,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setState) {
          Future<void> onSubmit() async {
            if (!formKey.currentState!.validate()) {
              return;
            }

            final license = controller.text.trim();
            setState(() {
              loading = true;
              errorText = null;
            });

            try {
              final response = await http
                  .post(
                    Uri.parse('$kLicenseServerBaseUrl/verify_license'),
                    headers: const {'Content-Type': 'application/json'},
                    body: jsonEncode({'license_key': license}),
                  )
                  .timeout(const Duration(seconds: 10));

              Map<String, dynamic> payload = {};
              try {
                payload = jsonDecode(response.body) as Map<String, dynamic>;
              } catch (_) {
                payload = {};
              }

              final message = payload['message']?.toString() ??
                  'License verification failed (${response.statusCode}).';

              final approved = response.statusCode == 200 &&
                  payload['status']?.toString() == 'success';
              if (!approved) {
                setState(() {
                  errorText = message;
                  loading = false;
                });
                if (dialogContext.mounted) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                    SnackBar(content: Text(message)),
                  );
                }
                return;
              }

              final maxConnections =
                  int.tryParse(payload['max_connections']?.toString() ?? '');
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString('saved_license', license);
              await prefs.setString('masked_license', maskLicense(license));
              if (maxConnections != null) {
                await prefs.setInt('max_connections', maxConnections);
              }

              if (dialogContext.mounted) {
                Navigator.of(dialogContext).pop();
              }
            } on TimeoutException catch (_) {
              setState(() {
                errorText = kLicenseCommunicationErrorMessage;
                loading = false;
              });
              if (dialogContext.mounted) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(content: Text(kLicenseCommunicationErrorMessage)),
                );
              }
            } catch (_) {
              setState(() {
                errorText = kLicenseCommunicationErrorMessage;
                loading = false;
              });
              if (dialogContext.mounted) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(content: Text(kLicenseCommunicationErrorMessage)),
                );
              }
            }
          }

          return AlertDialog(
            title: const Text('See-Desktop License Login'),
            content: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: controller,
                    autofocus: true,
                    enabled: !loading,
                    decoration: const InputDecoration(
                      labelText: 'License Key',
                      hintText: 'Enter your license key',
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'License key is required';
                      }
                      return null;
                    },
                    onFieldSubmitted: (_) => onSubmit(),
                  ),
                  if (errorText != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      errorText!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ],
                  if (loading) ...[
                    const SizedBox(height: 12),
                    const LinearProgressIndicator(),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: loading ? null : () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: loading ? null : onSubmit,
                child: const Text('Verify & Login'),
              ),
            ],
          );
        },
      );
    },
  );

  controller.dispose();
}
