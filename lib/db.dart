import 'dart:convert';

import 'package:google_sign_in/google_sign_in.dart';
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
// The Web OAuth client id (Google Cloud). Empty hides the Google button.
const googleWebClientId = String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');

final _log = Logger('sync');

/// The `prefs` row holding Diagnosis CFO's cached advice. It is the user's, so logout drops it.
const diagnosisAdviceKey = 'diagnosis_advice';

late final PowerSyncDatabase db;

SupabaseClient get supabase => Supabase.instance.client;
String? get currentUserId => supabase.auth.currentUser?.id;

// Postgres error classes that retrying can never fix: 22 = bad data, 23 = constraint, 42501 = RLS.
final _fatalCodes = [RegExp(r'^22...$'), RegExp(r'^23...$'), RegExp(r'^42501$')];

// jsonb columns arrive in SQLite as text; decode them before upload or Postgres stores a JSON string.
const _jsonColumns = {'keywords', 'label_ids', 'category_ids', 'account_ids', 'items'};

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

  if (supabase.auth.currentSession != null) _connect();
  supabase.auth.onAuthStateChange.listen((state) async {
    if (state.event == AuthChangeEvent.signedIn) {
      _connect();
    } else if (state.event == AuthChangeEvent.signedOut) {
      // Can also fire when a refresh token expires: disconnect only, keep unsynced data.
      _connector = null;
      await db.disconnect();
    } else if (state.event == AuthChangeEvent.tokenRefreshed) {
      _connector?.prefetchCredentials();
    }
  });
}

SupabaseConnector? _connector;

void _connect() {
  _connector = SupabaseConnector();
  db.connect(connector: _connector!);
}

/// "Coba sinkron sekarang": start the sync connection again instead of waiting for its retry.
Future<void> reconnect() async {
  if (supabase.auth.currentSession == null) return;
  await db.disconnect();
  _connect();
}

/// The nickname the user set, else the first word of the sign-up or Google name (Google sends the
/// full name and rewrites `name` at every sign-in, so a nickname can't live there), else the part
/// of the email before "@".
String userDisplayName() {
  final user = supabase.auth.currentUser;
  return displayNameFrom(user?.userMetadata, user?.email);
}

String displayNameFrom(Map<String, dynamic>? meta, String? email) {
  String? text(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
  final name =
      text(meta?['nickname']) ??
      (text(meta?['name']) ?? text(meta?['full_name']))?.split(RegExp(r'\s+')).first ??
      (email ?? '').split('@').first;
  return name.isEmpty ? 'Kamu' : name[0].toUpperCase() + name.substring(1);
}

/// The Google profile photo (user metadata `avatar_url`, else `picture`); null for an email account.
String? userAvatarUrl() {
  final meta = supabase.auth.currentUser?.userMetadata;
  final url = meta?['avatar_url'] ?? meta?['picture'];
  return url is String && url.startsWith('https://') ? url : null;
}

/// Saves [name] as the account's nickname (auth `user_metadata.nickname`; `name` is left to
/// sign-up and Google). Needs the internet; false when it could not save.
Future<bool> setUserDisplayName(String name) async {
  try {
    await supabase.auth.updateUser(UserAttributes(data: {'nickname': name})).timeout(const Duration(seconds: 15));
    return true;
  } on Exception catch (e) {
    _log.warning('could not save the name', e);
    return false;
  }
}

/// This phone's preferences (the local-only `prefs` table), e.g. 'hide_balance' -> '1'.
Future<String?> getPref(String key) async =>
    (await db.getOptional('SELECT value FROM prefs WHERE id = ?', [key]))?['value'] as String?;

Future<void> setPref(String key, String value) => db.writeTransaction((tx) async {
  await tx.execute('DELETE FROM prefs WHERE id = ?', [key]);
  await tx.execute('INSERT INTO prefs (id, value) VALUES (?, ?)', [key, value]);
});

bool _googleReady = false;

Future<void> _initGoogle() async {
  if (_googleReady) return;
  await GoogleSignIn.instance.initialize(serverClientId: googleWebClientId);
  _googleReady = true;
}

/// Native Google sign-in. Returns the signed-in user, or null when the account picker is canceled.
/// Google may link to the existing user with the same verified email, so check `createdAt` before
/// treating the result as a new account.
Future<User?> signInWithGoogle() async {
  await _initGoogle();
  final GoogleSignInAccount account;
  try {
    account = await GoogleSignIn.instance.authenticate();
  } on GoogleSignInException catch (e) {
    if (e.code == GoogleSignInExceptionCode.canceled) return null;
    rethrow;
  }
  final idToken = account.authentication.idToken;
  if (idToken == null) throw const AuthException('Google tidak mengirim token. Coba lagi.');
  return (await supabase.auth.signInWithIdToken(provider: OAuthProvider.google, idToken: idToken)).user;
}

/// Explicit logout. Refuses while changes are still waiting to upload, because
/// clearing the local database would destroy them. Returns false when refused.
Future<bool> logout() async {
  if (await db.getNextCrudTransaction() != null) return false;
  if (googleWebClientId.isNotEmpty) {
    // Else the picker keeps offering the last account. A Google failure must not block logging out.
    try {
      await _initGoogle();
      await GoogleSignIn.instance.signOut();
    } on Exception catch (e) {
      _log.warning('could not sign out of Google', e);
    }
  }
  await supabase.auth.signOut();
  // The next user on this phone must not see this user's data. clearLocal: false keeps this
  // phone's preferences (theme, haptics, lock, reminder time); what is the user's own goes below.
  await db.disconnectAndClear(clearLocal: false);
  await db.writeTransaction((tx) async {
    await tx.execute('DELETE FROM inbox');
    await tx.execute('DELETE FROM upload_errors');
    await tx.execute('DELETE FROM prefs WHERE id = ?', [diagnosisAdviceKey]);
  });
  return true;
}

/// Inserts a confirmed record and returns its id. In the same transaction, so a crash can't leave
/// one without the other: [inboxId] removes the notification it came from, and paying a planned
/// payment ([plannedPaymentId]) moves that bill on to [nextDue].
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
  String? plannedPaymentId,
  DateTime? nextDue,
  List<String> labelIds = const [],
  String? items,
}) {
  return db.writeTransaction((tx) async {
    final id = (await tx.get('SELECT uuid() AS id'))['id'] as String;
    final now = nowIso();
    await tx.execute(
      '''
      INSERT INTO records (id, user_id, account_id, type, amount, currency, category_id,
        transfer_account_id, transfer_amount, note, occurred_at, status, source, source_ref,
        planned_payment_id, label_ids, items, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'confirmed', ?, ?, ?, ?, ?, ?, ?)''',
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
        plannedPaymentId,
        jsonEncode(labelIds),
        items,
        now,
        now,
      ],
    );
    if (inboxId != null) await tx.execute('DELETE FROM inbox WHERE id = ?', [inboxId]);
    if (plannedPaymentId != null && nextDue != null) {
      await tx.execute('UPDATE planned_payments SET next_due_date = ?, updated_at = ? WHERE id = ?', [
        dateOnly(nextDue),
        now,
        plannedPaymentId,
      ]);
    }
    return id;
  });
}

/// Postgres `date` columns sync as 'YYYY-MM-DD' text.
String dateOnly(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Balance per account (`id`, `balance`), derived from confirmed records and never stored, so two
/// phones syncing at once can't disagree about it. Use as a subquery.
///
/// Records are summed per account first (what left or entered each account, then what each
/// received by transfer), so the cost is two passes over the records however many accounts
/// there are. Joining records to accounts directly reads every record once per account.
const accountBalancesSql = '''
  SELECT a.id, a.initial_balance + COALESCE(m.delta, 0) AS balance
  FROM accounts a
  LEFT JOIN (
    SELECT id, SUM(delta) AS delta FROM (
      SELECT account_id AS id,
        CASE WHEN type = 'income' THEN amount WHEN type IN ('expense', 'transfer') THEN -amount END AS delta
      FROM records WHERE status = 'confirmed'
      UNION ALL
      SELECT transfer_account_id, transfer_amount
      FROM records WHERE status = 'confirmed' AND transfer_account_id != account_id)
    GROUP BY id) m ON m.id = a.id''';

/// Edits a record in place. Where it came from (source, source_ref, a paid bill) stays as it was.
Future<void> updateRecord(
  String id, {
  required String accountId,
  required String type,
  required int amount,
  required String currency,
  required DateTime occurredAt,
  String? categoryId,
  String? transferAccountId,
  int? transferAmount,
  String? note,
  List<String> labelIds = const [],
  String? items,
}) => db.execute(
  '''
  UPDATE records SET account_id = ?, type = ?, amount = ?, currency = ?, category_id = ?,
    transfer_account_id = ?, transfer_amount = ?, note = ?, label_ids = ?, items = ?, occurred_at = ?, updated_at = ?
  WHERE id = ?''',
  [
    accountId,
    type,
    amount,
    currency,
    categoryId,
    transferAccountId,
    transferAmount,
    note,
    jsonEncode(labelIds),
    items,
    occurredAt.toUtc().toIso8601String(),
    nowIso(),
    id,
  ],
);
