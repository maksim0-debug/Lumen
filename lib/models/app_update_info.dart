import 'package:flutter/foundation.dart';

/// Information about the available application update from GitHub Releases.
@immutable
class AppUpdateInfo {
  final String currentVersion;
  final String latestVersion;
  final String releaseTitle;
  final String releaseNotes;
  final String releaseUrl;
  final DateTime? publishedAt;
  final bool hasUpdate;

  const AppUpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.releaseTitle,
    required this.releaseNotes,
    required this.releaseUrl,
    required this.hasUpdate,
    this.publishedAt,
  });

  Map<String, dynamic> toJson() => {
        'currentVersion': currentVersion,
        'latestVersion': latestVersion,
        'releaseTitle': releaseTitle,
        'releaseNotes': releaseNotes,
        'releaseUrl': releaseUrl,
        'publishedAt': publishedAt?.toIso8601String(),
        'hasUpdate': hasUpdate,
      };

  factory AppUpdateInfo.fromJson(Map<String, dynamic> json) {
    return AppUpdateInfo(
      currentVersion: json['currentVersion'] as String? ?? '0.0.0',
      latestVersion: json['latestVersion'] as String? ?? '0.0.0',
      releaseTitle: json['releaseTitle'] as String? ?? '',
      releaseNotes: json['releaseNotes'] as String? ?? '',
      releaseUrl: json['releaseUrl'] as String? ?? '',
      publishedAt: json['publishedAt'] != null
          ? DateTime.tryParse(json['publishedAt'].toString())
          : null,
      hasUpdate: json['hasUpdate'] as bool? ?? false,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppUpdateInfo &&
          runtimeType == other.runtimeType &&
          currentVersion == other.currentVersion &&
          latestVersion == other.latestVersion &&
          releaseTitle == other.releaseTitle &&
          releaseNotes == other.releaseNotes &&
          releaseUrl == other.releaseUrl &&
          publishedAt == other.publishedAt &&
          hasUpdate == other.hasUpdate;

  @override
  int get hashCode => Object.hash(
        currentVersion,
        latestVersion,
        releaseTitle,
        releaseNotes,
        releaseUrl,
        publishedAt,
        hasUpdate,
      );
}
