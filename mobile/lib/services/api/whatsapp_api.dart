import '../../models/whatsapp.dart';
import 'api_client.dart';

/// Profile → WhatsApp: its state, linking with a pairing code, unlinking.
abstract interface class WhatsAppApi {
  Future<WhatsAppStatus> getWhatsApp();

  /// The code to type in WhatsApp → Linked devices → Link with phone number instead.
  Future<String> linkWhatsApp(String phone);
  Future<void> unlinkWhatsApp();
}

mixin WhatsAppEndpoints on ApiClient implements WhatsAppApi {
  @override
  Future<WhatsAppStatus> getWhatsApp() async {
    final response = await get('/api/whatsapp');
    return parse(response.data, (data) => WhatsAppStatus.fromJson(data as Map<String, dynamic>));
  }

  @override
  Future<String> linkWhatsApp(String phone) async {
    // WhatsApp may take a while to be ready for a code
    final response = await post(
      '/api/whatsapp/link',
      body: {'phone': phone},
      timeout: const Duration(seconds: 45),
    );
    return parse(response.data, (data) => (data as Map<String, dynamic>)['code'] as String);
  }

  @override
  Future<void> unlinkWhatsApp() => delete('/api/whatsapp');
}
