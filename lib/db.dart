import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:powersync/powersync.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'schema.dart';

// Passed at build time: flutter run --dart-define-from-file=.env
const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const supabasePublishableKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
const powersyncUrl = String.fromEnvironment('POWERSYNC_URL');

final _log = Logger('sync');

late final PowerSyncDatabase db;

SupabaseClient get supabase => Supabase.instance.client;
String? get currentUserId => supabase.auth.currentUser?.id;

// Postgres error classes that retrying can never fix: 22 = bad data, 23 = constraint, 42501 = RLS.
final _fatalCodes = [RegExp(r'^22...$'), RegExp(r'^23...$'), RegExp(r'^42501$')];

// jsonb columns arrive in SQLite as text; decode them before upload or Postgres stores a JSON string.
const _jsonColumns = {'keywords', 'label_ids', 'category_ids', 'account_ids'};

class SupabaseConnector extends PowerSyncBackendConnector {
  Future<void>? _refresh;

  @override
  Future<PowerSyncCredentials?> fetchCredentials() async {
    await _refresh;
    final session = supabase.auth.currentSession;
    if (session == null) return null;
    return PowerSyncCredentials(endpoint: powersyncUrl, token: session.accessToken, userId: session.user.id);
  }

  @override
  void invalidateCredentials() {
    _refresh = supabase.auth
        .refreshSession()
        .timeout(const Duration(seconds: 5))
        .then((_) => null, onError: (_) => null);
  }

  @override
  Future<void> uploadData(PowerSyncDatabase database) async {
    final tx = await database.getNextCrudTransaction();
    if (tx == null) return;
    CrudEntry? op;
    try {
      for (op in tx.crud) {
        final table = supabase.rest.from(op.table);
        final data = {
          for (final e in (op.opData ?? const {}).entries)
            e.key: _jsonColumns.contains(e.key) && e.value is String ? jsonDecode(e.value as String) : e.value,
        };
        switch (op.op) {
          case UpdateType.put:
            await table.upsert({...data, 'id': op.id});
          case UpdateType.patch:
            await table.update(data).eq('id', op.id);
          case UpdateType.delete:
            await table.delete().eq('id', op.id);
        }
      }
      await tx.complete();
    } on PostgrestException catch (e) {
      if (e.code == null || !_fatalCodes.any((re) => re.hasMatch(e.code!))) rethrow; // retried later
      _log.severe('Upload rejected, saved to upload_errors: $op', e);
      await database.execute(
        'INSERT INTO upload_errors (id, table_name, op, row_id, data, error, created_at) '
        'VALUES (uuid(), ?, ?, ?, ?, ?, ?)',
        [op?.table, op?.op.name, op?.id, jsonEncode(op?.opData), '${e.code}: ${e.message}', nowIso()],
      );
      await tx.complete();
    }
  }
}

String nowIso() => DateTime.now().toUtc().toIso8601String();

Future<void> openDatabase() async {
  final dir = await getApplicationSupportDirectory();
  db = PowerSyncDatabase(schema: schema, path: join(dir.path, 'cashflow.db'));
  await db.initialize();

  await Supabase.initialize(url: supabaseUrl, publishableKey: supabasePublishableKey);

  SupabaseConnector? connector;
  void connect() {
    connector = SupabaseConnector();
    db.connect(connector: connector!);
  }

  if (supabase.auth.currentSession != null) connect();
  supabase.auth.onAuthStateChange.listen((state) async {
    if (state.event == AuthChangeEvent.signedIn) {
      connect();
    } else if (state.event == AuthChangeEvent.signedOut) {
      // Can also fire when a refresh token expires: disconnect only, keep unsynced data.
      connector = null;
      await db.disconnect();
    } else if (state.event == AuthChangeEvent.tokenRefreshed) {
      connector?.prefetchCredentials();
    }
  });
}

/// Explicit logout. Refuses while changes are still waiting to upload, because
/// clearing the local database would destroy them. Returns false when refused.
Future<bool> logout() async {
  if (await db.getNextCrudTransaction() != null) return false;
  await supabase.auth.signOut();
  await db.disconnectAndClear(); // the next user on this phone must not see this user's data
  return true;
}

/// Inserts a confirmed record and returns its id. [inboxId] removes the notification
/// it came from in the same transaction, so a crash can't leave both or neither.
Future<String> insertRecord({
  required String accountId,
  required String type,
  required int amount,
  required String currency,
  required DateTime occurredAt,
  String? categoryId,
  String? transferAccountId,
  int? transferAmount,
  String? note,
  String source = 'manual',
  String? sourceRef,
  String? inboxId,
}) {
  return db.writeTransaction((tx) async {
    final id = (await tx.get('SELECT uuid() AS id'))['id'] as String;
    final now = nowIso();
    await tx.execute(
      '''
      INSERT INTO records (id, user_id, account_id, type, amount, currency, category_id,
        transfer_account_id, transfer_amount, note, occurred_at, status, source, source_ref, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'confirmed', ?, ?, ?, ?)''',
      [
        id,
        currentUserId,
        accountId,
        type,
        amount,
        currency,
        categoryId,
        transferAccountId,
        transferAmount,
        note,
        occurredAt.toUtc().toIso8601String(),
        source,
        sourceRef,
        now,
        now,
      ],
    );
    if (inboxId != null) await tx.execute('DELETE FROM inbox WHERE id = ?', [inboxId]);
    return id;
  });
}
