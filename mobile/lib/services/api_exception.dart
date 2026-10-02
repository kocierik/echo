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