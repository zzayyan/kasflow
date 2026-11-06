// Reads a photo of a receipt into one expense, using Gemini. The app (the camera button of the
// record form's quick field, lib/screens/record_form.dart) sends the photo with the user's accounts
// and categories, so the answer can only name ids that exist, and the form shows the result for a
// check before anything is saved. The platform's default verify_jwt check turns away callers
// without a session.

import { askGemini } from "../_shared/gemini.ts";

type Account = { id: string; name: string; provider?: string | null };
type Category = { id: string; name: string; type: string; keywords?: string | null };

const NONE = "none";
const MAX_IMAGE = 3_000_000; // base64 characters; the app sends a JPEG of at most 1600 px, about 300 kB

Deno.serve(async (req) => {
  const { image, today, accounts, categories } = await req.json().catch(() => ({}));
  if (
    typeof image !== "string" || !image || image.length > MAX_IMAGE ||
    typeof today !== "string" || today.length > 40 ||
    !Array.isArray(accounts) || accounts.length === 0 || accounts.length > 100 ||
    !Array.isArray(categories) || categories.length > 200
  ) {
    return Response.json({ error: "expected image (base64 JPEG), today, accounts and categories" }, { status: 400 });
  }

  const ids = (rows: { id: string }[]) => [...rows.map((r) => String(r.id)), NONE];
  const expenses = (categories as Category[]).filter((c) => c.type === "expense");
  const schema = {
    type: "object",
    properties: {
      amount: { type: "integer" },
      note: { type: "string" },
      account_id: { type: "string", enum: ids(accounts) },
      category_id: { type: "string", enum: ids(expenses) },
      days_ago: { type: "integer" },
      time: { type: "string" },
    },
    required: ["amount", "note", "account_id", "category_id", "days_ago", "time"],
  };

  const instruction = `You read a photo of a shopping receipt or bill for an Indonesian money tracker and turn it into one expense.
Today is ${today}.

The user's accounts (id: name, provider):
${(accounts as Account[]).map((a) => `- ${a.id}: ${a.name}${a.provider ? `, ${a.provider}` : ""}`).join("\n")}

The user's expense categories (id: name, words the user filed under it):
${expenses.map((c) => `- ${c.id}: ${c.name}${c.keywords ? `, ${c.keywords}` : ""}`).join("\n")}

- amount: the total the customer paid, in whole rupiah, after discounts, tax and service: the line labelled TOTAL, GRAND TOTAL, TOTAL BAYAR or similar, never the cash handed over (TUNAI, CASH) or the change (KEMBALI). Receipts write "25.000" or "25,000" for 25000. 0 when the photo is not a receipt or the total can't be read.
- note: the shop or merchant name as printed, in plain case, such as "Indomaret" or "Kopi Kenangan". Empty when there is none.
- account_id: the account that paid, when the receipt shows the payment method by provider (GoPay, OVO, DANA, ShopeePay, BCA, BRI, QRIS from a named bank); a provider means the account with that provider, never one whose name merely contains the word. "${NONE}" for cash or when not shown.
- category_id: the expense category the shop and items clearly point to, preferring one whose words match; "${NONE}" when unsure or instead of a catch-all category such as "Lainnya".
- days_ago: from the date printed on the receipt, 0 for today. 0 when no date is printed. Never a date in the future.
- time: the time printed on the receipt as 24-hour "HH:mm", such as "14:05" (convert "2:05 PM"). Empty when no time is printed.`;

  return askGemini(instruction, [
    { inlineData: { mimeType: "image/jpeg", data: image } },
    { text: "Read this receipt." },
  ], schema);
});
