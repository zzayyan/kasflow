// Reads one bank or e-wallet notification and returns the transaction it reports, using Gemini.
// The app (lib/notifications.dart) calls it with the user's session; the platform's default
// verify_jwt check turns away anyone else. The app redacts names and long numbers first, because
// Gemini's free tier may use requests to improve Google's products.

import { askGemini } from "../_shared/gemini.ts";

const MAX_TEXT = 6000; // a BRImo email as Gmail shows it is about 1,500 characters

const INSTRUCTION = `You read one notification or email from an Indonesian bank or e-wallet app and report the transaction in it.
- is_transaction: true only when money actually moved: a payment, purchase, transfer, top-up, withdrawal or money received, completed successfully. False for promotions, vouchers, OTP codes, login or security alerts, bills not yet paid, failed or pending transactions, statements and balance reminders.
- amount: the whole rupiah that left or entered the account, admin fee included (use the total when the text shows one). 0 when is_transaction is false.
- type: "income" for money received, "transfer" for an e-wallet top-up or a move between the user's own accounts, otherwise "expense".
- payee: the merchant, recipient, sender or product, exactly as written. Empty when none is named.
- note: the note the user typed for the transaction (Catatan, Berita, Keterangan), else empty. "-" counts as empty.
- summary: the kind of transaction in at most four Indonesian words, such as "Pembelian QRIS", "Transfer BI-FAST", "Top Up DANA", "Transfer masuk".
Text in square brackets such as [nama], [nomor] or [email] was removed for privacy. Never guess it.`;

const SCHEMA = {
  type: "object",
  properties: {
    is_transaction: { type: "boolean" },
    amount: { type: "integer" },
    type: { type: "string", enum: ["expense", "income", "transfer"] },
    payee: { type: "string" },
    note: { type: "string" },
    summary: { type: "string" },
  },
  required: ["is_transaction", "amount", "type", "payee", "note", "summary"],
};

Deno.serve(async (req) => {
  const { text } = await req.json().catch(() => ({}));
  if (typeof text !== "string" || !text.trim() || text.length > MAX_TEXT) {
    return Response.json({ error: `text must be a non-empty string of at most ${MAX_TEXT} characters` }, { status: 400 });
  }
  return askGemini(INSTRUCTION, text, SCHEMA);
});
