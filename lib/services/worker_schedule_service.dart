import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/schedule_snapshot.dart';
import '../models/schedule_status.dart';
import 'app_logger.dart';
import 'schedule_ingestion_service.dart';

class WorkerScheduleService {
  static const defaultEndpoint =
      'https://lumen-schedule-monitor.maksim0.workers.dev';
  final Uri endpoint;
  final ScheduleIngestionService ingestion;
  final Future<Object?> Function(Uri)? request;
  WorkerScheduleService(
      {Uri? endpoint, ScheduleIngestionService? ingestion, this.request})
      : endpoint = endpoint ?? Uri.parse(defaultEndpoint),
        ingestion = ingestion ?? ScheduleIngestionService();

  Future<Object?> _get(Uri uri) async {
    if (request != null) return request!(uri);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      return await (() async {
        final req = await client.getUrl(uri);
        req.followRedirects = false;
        req.headers.set(HttpHeaders.acceptHeader, 'application/json');
        final response = await req.close();
        if (response.statusCode != 200) {
          throw HttpException('Schedule API HTTP ${response.statusCode}');
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 128 * 1024) {
            throw const FormatException('Schedule API response exceeds limit');
          }
          bytes.addAll(chunk);
        }
        return jsonDecode(utf8.decode(bytes));
      })()
          .timeout(const Duration(seconds: 8));
    } finally {
      client.close(force: true);
    }
  }

  /// Latest state is independent of history recovery; a backfill failure never
  /// prevents a valid current graph from being used.
  Future<Map<String, FullSchedule>> fetch() async {
    final raw = await _get(endpoint.resolve('/api/v1/snapshot'));
    if (raw is! Map) {
      throw const FormatException('Invalid schedule API response');
    }
    final checked = raw['lastCheckedAt'];
    if (checked is! int ||
        checked > ingestion.now().millisecondsSinceEpoch + 60000 ||
        ingestion.now().millisecondsSinceEpoch - checked >
            const Duration(minutes: 15).inMilliseconds) {
      throw const FormatException(
          'Worker source has not been checked recently');
    }
    final snapshot =
        ScheduleSnapshot.parse(raw['snapshot'], now: ingestion.now());
    if (!snapshot.isCurrent(ingestion.now())) {
      throw const FormatException(
          'Worker schedule is for an older calendar day');
    }
    try {
      await ingestion.ingest(snapshot);
    } on FormatException catch (error) {
      AppLogger.w('Worker publication rejected; retaining local source state',
          tag: 'ScheduleSync', error: error);
    }
    final schedules = await ingestion.history.getLastKnownSchedules();
    if (schedules.isEmpty) {
      throw const FormatException('No usable Worker schedules');
    }
    try {
      await syncHistory();
    } catch (error) {
      AppLogger.w('Schedule history recovery deferred',
          tag: 'ScheduleSync', error: error.runtimeType);
    }
    return schedules;
  }

  Future<void> syncHistory() async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    final db = await ingestion.history.database;
    await ScheduleIngestionService.createCursorSchema(db);
    final rows = await db.query('schedule_journal_cursor',
        where: 'endpoint=?', whereArgs: [endpoint.toString()]);
    var after = rows.isEmpty ? 0 : rows.single['sequence'] as int;
    String? journal = rows.isEmpty ? null : rows.single['journal_id'] as String;
    // Bound each invocation; subsequent periodic runs continue from committed pages.
    for (var page = 0; page < 4; page++) {
      if (DateTime.now().isAfter(deadline)) return;
      final uri =
          endpoint.resolve('/api/v1/publications').replace(queryParameters: {
        'after': '$after',
        'limit': '32',
        if (journal != null) 'journalId': journal,
      });
      final raw = await _get(uri);
      if (raw is! Map ||
          raw['publications'] is! List ||
          (raw['publications'] as List).length > 32 ||
          raw['journalId'] is! String ||
          raw['nextAfter'] is! int ||
          raw['hasMore'] is! bool ||
          raw['gap'] is! bool ||
          raw['reset'] is! bool ||
          raw['oldestSequence'] is! int ||
          raw['latestSequence'] is! int) {
        throw const FormatException('Invalid journal page');
      }
      final values = (raw['publications'] as List)
          .map((v) => ScheduleSnapshot.parse(v, now: ingestion.now()))
          .toList();
      final next = raw['nextAfter'] as int;
      final newJournal = raw['journalId'] as String;
      final reset = raw['reset'] as bool;
      final oldest = raw['oldestSequence'] as int;
      final latest = raw['latestSequence'] as int;
      if (!RegExp(r'^[a-zA-Z0-9-]{1,64}$').hasMatch(newJournal) ||
          oldest < 1 ||
          latest < oldest ||
          latest > 9007199254740991 ||
          next < 0 ||
          (!reset && journal != null && newJournal != journal) ||
          (!reset && raw['gap'] == true && oldest <= after + 1) ||
          raw['hasMore'] != (next < latest)) {
        throw const FormatException('Inconsistent journal metadata');
      }
      var expected = reset || raw['gap'] == true ? oldest : after + 1;
      for (final value in values) {
        if (value.journalId != newJournal || value.sequence != expected++) {
          throw const FormatException('Non-contiguous journal page');
        }
      }
      if (values.length > 32 ||
          (values.isNotEmpty && next != values.last.sequence) ||
          (values.isEmpty &&
              (raw['hasMore'] == true || next != (reset ? 0 : after))) ||
          next > latest) {
        throw const FormatException('Invalid journal cursor');
      }
      await ingestion.archivePage(values,
          endpoint: endpoint.toString(),
          journalId: newJournal,
          previous: after,
          next: next,
          expectedJournalId: journal);
      if (raw['gap'] == true) {
        AppLogger.w('Schedule journal retention gap detected',
            tag: 'ScheduleSync', persistToHistory: true);
      }
      after = next;
      journal = newJournal;
      if (raw['hasMore'] != true) return;
    }
  }
}
