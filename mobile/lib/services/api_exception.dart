final class ApiException implements Exception {
  const ApiException({
    required this.statusCode,
    required this.code,
    required this.message,
    required this.retryable,
  });

  final int? statusCode;
  final String code;
  final String message;
  final bool retryable;

  @override
  String toString() {
    final status = statusCode == null ? '' : ', statusCode: $statusCode';
    return 'ApiException(code: $code$status, retryable: $retryable): $message';
  }
}
/// A message to show for [error]: the server's own for API errors, otherwise
/// the error text, or [fallback] when there is none.
String userMessage(Object error, String fallback) {
  if (error is ApiException) return error.message;
  final message = error.toString().replaceFirst('Exception: ', '').trim();
  return message.isEmpty ? fallback : message;
}
