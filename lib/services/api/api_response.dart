import 'dart:convert';
import 'dart:io';

/// Standard response envelope and serialization helper for Local REST API.
class ApiResponse {
  final int statusCode;
  final bool success;
  final dynamic data;
  final Map<String, dynamic>? meta;
  final ApiError? error;
  final List<String>? allowedMethods;
  final bool isRaw;

  ApiResponse._({
    required this.statusCode,
    required this.success,
    this.data,
    this.meta,
    this.error,
    this.allowedMethods,
    this.isRaw = false,
  });

  /// Raw response factory (e.g. for OpenAPI JSON specification)
  factory ApiResponse.raw(dynamic data, {int statusCode = HttpStatus.ok}) {
    return ApiResponse._(
      statusCode: statusCode,
      success: true,
      data: data,
      isRaw: true,
    );
  }

  /// Successful response factory
  factory ApiResponse.ok(dynamic data, {Map<String, dynamic>? meta}) {
    return ApiResponse._(
      statusCode: HttpStatus.ok,
      success: true,
      data: data,
      meta: meta,
    );
  }

  /// Accepted response factory (async trigger)
  factory ApiResponse.accepted(dynamic data, {Map<String, dynamic>? meta}) {
    return ApiResponse._(
      statusCode: HttpStatus.accepted,
      success: true,
      data: data,
      meta: meta,
    );
  }

  /// Bad Request (400) factory
  factory ApiResponse.badRequest(String message,
      {String code = 'BAD_REQUEST', Map<String, dynamic>? details}) {
    return ApiResponse._(
      statusCode: HttpStatus.badRequest,
      success: false,
      error: ApiError(code: code, message: message, details: details),
    );
  }

  /// Not Found (404) factory
  factory ApiResponse.notFound(String message, {String code = 'NOT_FOUND'}) {
    return ApiResponse._(
      statusCode: HttpStatus.notFound,
      success: false,
      error: ApiError(code: code, message: message),
    );
  }

  /// Method Not Allowed (405) factory
  factory ApiResponse.methodNotAllowed(String message,
      {List<String>? allowedMethods, String code = 'METHOD_NOT_ALLOWED'}) {
    return ApiResponse._(
      statusCode: HttpStatus.methodNotAllowed,
      success: false,
      allowedMethods: allowedMethods,
      error: ApiError(code: code, message: message),
    );
  }

  /// Internal Server Error (500) factory
  factory ApiResponse.internalError(String message,
      {String code = 'INTERNAL_ERROR', Object? exception}) {
    return ApiResponse._(
      statusCode: HttpStatus.internalServerError,
      success: false,
      error: ApiError(
        code: code,
        message: message,
        details: exception != null ? {'exception': exception.toString()} : null,
      ),
    );
  }

  /// Service Unavailable (503) factory
  factory ApiResponse.serviceUnavailable(String message,
      {String code = 'SERVICE_UNAVAILABLE'}) {
    return ApiResponse._(
      statusCode: HttpStatus.serviceUnavailable,
      success: false,
      error: ApiError(code: code, message: message),
    );
  }

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'success': success,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    };

    if (success) {
      map['data'] = data;
      if (meta != null && meta!.isNotEmpty) {
        map['meta'] = meta;
      }
    } else if (error != null) {
      map['error'] = error!.toMap();
    }

    return map;
  }

  String toJson() => isRaw ? jsonEncode(data) : jsonEncode(toMap());

  /// Writes this response to the client with CORS headers, charset, and proper content-type.
  Future<void> sendTo(HttpRequest request) async {
    final response = request.response;
    response.statusCode = statusCode;
    response.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');

    // Apply CORS and Private Network Access headers
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    response.headers.set('Access-Control-Allow-Headers',
        'Origin, X-Requested-With, Content-Type, Accept, Authorization');
    response.headers.set('Access-Control-Allow-Private-Network', 'true');

    if (allowedMethods != null && allowedMethods!.isNotEmpty) {
      response.headers.set('Allow', allowedMethods!.join(', '));
    }

    final bodyBytes = utf8.encode(toJson());
    response.headers.contentLength = bodyBytes.length;
    try {
      response.add(bodyBytes);
      await response.close();
    } catch (_) {
      // Ignored: client closed the TCP connection prematurely
    }
  }
}

/// Standardized error object
class ApiError {
  final String code;
  final String message;
  final Map<String, dynamic>? details;

  const ApiError({
    required this.code,
    required this.message,
    this.details,
  });

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'code': code,
      'message': message,
    };
    if (details != null && details!.isNotEmpty) {
      map['details'] = details;
    }
    return map;
  }
}
