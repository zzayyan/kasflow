// Turns one line typed into "Catat cepat" ("makan 25rb parkir 5rb pakai dana") into transactions,
// using Gemini. The app (submitQuickInput in lib/screens/records_tab.dart) sends the line with the
// user's accounts and categories, so the answer can only name ids that exist; the platform's
// default verify_jwt check turns away callers without a session.

import { askGemini } from "../_shared/gemini.ts";

type Account = { id: string; name: string; provider?: string | null };
type Category = { id: string; name: string; type: string; keywords?: string | null };

const NONE = "none";

Deno.serve(async (req) => {
  const { text, today, accounts, categories } = await req.json().catch(() => ({}));
  if (
    typeof text !== "string" || !text.trim() || text.length > 500 ||
    typeof today !== "string" || today.length > 40 ||
    !Array.isArray(accounts) || accounts.length === 0 || accounts.length > 100 ||
    !Array.isArray(categories) || categories.length > 200
  ) {
    return Response.json({ error: "expected text (at most 500 characters), today, accounts and categories" }, {
      status: 400,
    });
  }

  const ids = (rows: { id: string }[]) => [...rows.map((r) => String(r.id)), NONE];
  const schema = {
    type: "object",
    properties: {
      transactions: {
        type: "array",
        items: {
          type: "object",
          properties: {
            amount: { type: "integer" },
            type: { type: "string", enum: ["expense", "income", "transfer"] },
            note: { type: "string" },
            account_id: { type: "string", enum: ids(accounts) },
            transfer_account_id: { type: "string", enum: ids(accounts) },
            category_id: { type: "string", enum: ids(categories) },
            days_ago: { type: "integer" },
          },
          required: ["amount", "type", "note", "account_id", "transfer_account_id", "category_id", "days_ago"],
        },
      },
    },
    required: ["transactions"],
  };

  const instruction = `You turn one line that a user typed into an Indonesian money tracker into transactions. Lines are short and casual, such as "bakso 25rb pakai dana", "gaji masuk bca 5jt" or "makan 25rb parkir 5rb kemarin".
Today is ${today}.

The user's accounts (id: name, provider):
${(accounts as Account[]).map((a) => `- ${a.id}: ${a.name}${a.provider ? `, ${a.provider}` : ""}`).join("\n")}

The user's categories (id: name, type, words the user filed under it):
${(categories as Category[]).map((c) => `- ${c.id}: ${c.name}, ${c.type}${c.keywords ? `, ${c.keywords}` : ""}`).join("\n")}

For each amount the user spent, received or moved, give one transaction. Most lines hold one; a line with no amount holds none.
- amount: whole rupiah. "rb", "ribu" and "k" mean thousand, "jt" and "juta" mean million: "25rb" is 25000, "1,5jt" is 1500000, "25.000" is 25000.
- type: "income" for money received (gaji, bonus, dapat, terima, cashback, jual), "transfer" for moving money between the user's own accounts (top up, tarik tunai, pindah ke), otherwise "expense".
- account_id: the account the money left or entered, when the line names it by name, provider, "cash" or "tunai"; else "${NONE}". A provider word (dana, gopay, ovo, bca, bri) means the account with that provider, never an account whose name merely contains the word, such as "Dana darurat" for "dana".
- transfer_account_id: for a transfer, the account the money went to; else "${NONE}".
- category_id: the category of the same type that the line clearly points to, preferring one whose words appear in the line. "${NONE}" when unsure, for transfers, and instead of a catch-all category such as "Lainnya": the user then picks one, which teaches the app.
- note: the words that describe this transaction, as the user wrote them, without its amount, account, date words or hashtags.
- days_ago: 0 for today, 1 for "kemarin", 2 for "kemarin lusa"; work out weekdays and dates such as "senin" or "tgl 3" from today. Never a date in the future.`;

  return askGemini(instruction, text, schema);
});
