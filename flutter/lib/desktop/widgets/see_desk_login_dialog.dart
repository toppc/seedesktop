import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const String _verifyUrl = 'http://187.124.13.191/verify';

String _maskLicense(String license) {
  if (license.length <= 4) {
    return license;
  }
  return '****${license.substring(license.length - 4)}';
}

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
              final response = await http.post(
                Uri.parse(_verifyUrl),
                headers: const {'Content-Type': 'application/json'},
                body: jsonEncode({'license_key': license}),
              );

              if (response.statusCode < 200 || response.statusCode >= 300) {
                setState(() {
                  errorText = 'License verification failed (${response.statusCode}).';
                  loading = false;
                });
                return;
              }

              final Map<String, dynamic> payload =
                  jsonDecode(response.body) as Map<String, dynamic>;

              final bool approved = payload['success'] == true ||
                  payload['valid'] == true ||
                  payload['status'] == 'ok';
              final String? sessionId = payload['session_id']?.toString();
              final int maxConnections =
                  int.tryParse(payload['max_connections']?.toString() ?? '1') ?? 1;

              if (!approved || sessionId == null || sessionId.isEmpty) {
                setState(() {
                  errorText = payload['message']?.toString() ??
                      'License was rejected by server.';
                  loading = false;
                });
                return;
              }

              final prefs = await SharedPreferences.getInstance();
              await prefs.setString('saved_license', license);
              await prefs.setString('masked_license', _maskLicense(license));
              await prefs.setString('session_id', sessionId);
              await prefs.setInt('max_connections', maxConnections);

              if (dialogContext.mounted) {
                Navigator.of(dialogContext).pop();
              }
            } catch (_) {
              setState(() {
                errorText = 'Network error while verifying license.';
                loading = false;
              });
            }
          }

          return AlertDialog(
            title: const Text('See-Desk License Login'),
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
