import 'package:lumen/ui/state/app_update_notifier.dart';

/// Keeps unrelated screen tests independent of release API requests.
class IdleAppUpdateNotifier extends AppUpdateNotifier {
  @override
  Future<void> checkSilently() async {}
}
