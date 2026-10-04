import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/power_monitor_service.dart';

void main() {
  group('PowerMonitorService Backoff & Error Suppression Tests', () {
    test('calculateNextPollDelay returns standard interval for 0 errors', () {
      final delay = PowerMonitorService.calculateNextPollDelay(
        consecutiveErrors: 0,
        isAuthError: false,
      );
      expect(delay, const Duration(seconds: 30));
    });

    test(
        'calculateNextPollDelay returns 10 minutes immediately on auth error (HTTP 401/403)',
        () {
      final delay = PowerMonitorService.calculateNextPollDelay(
        consecutiveErrors: 1,
        isAuthError: true,
      );
      expect(delay, const Duration(minutes: 10));

      final delayMultiple = PowerMonitorService.calculateNextPollDelay(
        consecutiveErrors: 5,
        isAuthError: true,
      );
      expect(delayMultiple, const Duration(minutes: 10));
    });

    test(
        'calculateNextPollDelay applies exponential backoff for transient network errors',
        () {
      // 1 error: 30s * 2^0 = 30s
      final d1 = PowerMonitorService.calculateNextPollDelay(
        consecutiveErrors: 1,
        isAuthError: false,
      );
      expect(d1, const Duration(seconds: 30));

      // 2 errors: 30s * 2^1 = 60s
      final d2 = PowerMonitorService.calculateNextPollDelay(
        consecutiveErrors: 2,
        isAuthError: false,
      );
      expect(d2, const Duration(seconds: 60));

      // 3 errors: 30s * 2^2 = 120s
      final d3 = PowerMonitorService.calculateNextPollDelay(
        consecutiveErrors: 3,
        isAuthError: false,
      );
      expect(d3, const Duration(seconds: 120));

      // 4 errors: 30s * 2^3 = 240s
      final d4 = PowerMonitorService.calculateNextPollDelay(
        consecutiveErrors: 4,
        isAuthError: false,
      );
      expect(d4, const Duration(seconds: 240));

      // 5 errors: 30s * 2^4 = 480s -> clamped to max 5 minutes (300s)
      final d5 = PowerMonitorService.calculateNextPollDelay(
        consecutiveErrors: 5,
        isAuthError: false,
      );
      expect(d5, const Duration(seconds: 300));

      // Extreme boundary inputs (64, 100, 1000 errors): Must NEVER overflow integer bitshift
      final d64 = PowerMonitorService.calculateNextPollDelay(
        consecutiveErrors: 64,
        isAuthError: false,
      );
      expect(d64, const Duration(minutes: 5));

      final d1000 = PowerMonitorService.calculateNextPollDelay(
        consecutiveErrors: 1000,
        isAuthError: false,
      );
      expect(d1000, const Duration(minutes: 5));

      // Negative values safety
      final dNeg = PowerMonitorService.calculateNextPollDelay(
        consecutiveErrors: -5,
        isAuthError: false,
      );
      expect(dNeg, const Duration(seconds: 30));
    });

    test(
        'isAuthorizationError correctly classifies 401, 403, and permission denied',
        () {
      expect(PowerMonitorService.isAuthorizationError('Exception: HTTP 401'),
          isTrue);
      expect(PowerMonitorService.isAuthorizationError('HTTP 403 Forbidden'),
          isTrue);
      expect(
          PowerMonitorService.isAuthorizationError(
              'Client error: Permission denied'),
          isTrue);
      expect(
          PowerMonitorService.isAuthorizationError(
              'SocketException: Failed host lookup'),
          isFalse);
      expect(PowerMonitorService.isAuthorizationError('TimeoutException'),
          isFalse);
    });
  });
}

