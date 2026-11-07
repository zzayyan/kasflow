// Words the monthly Diagnosis CFO: a short summary and three steps, using Gemini. The app
// (lib/diagnosis.dart, diagnosisPayload) has already scored every pillar; it sends only statuses,
// the numbers behind them and category and goal names, never payees, notes or account names.
// The platform's default verify_jwt check turns away callers without a session.

import { askGemini } from "../_shared/gemini.ts";

const MAX_PAYLOAD = 20_000; // characters of JSON; a real month is about 3,000

const INSTRUCTION = `You are a blunt, practical personal CFO for one person in Indonesia. You receive their finances for one full month as JSON, already scored by the app. Write in Indonesian, addressing the user as "kamu". Be direct and never preachy.

The JSON:
- month: the month scored, YYYY-MM.
- pillars: each has pillar, status (good, warn, bad, unknown) and value, plus the amounts behind it, in whole rupiah.
  - emergency: value = months of must + need spending covered by liquid (cash, bank, e-wallet, savings) balances. Bad under 3, good from 6.
  - savings: value = share of income kept, 3-month average. Bad under 0.10, good from 0.20.
  - spending: value = share of spending on wants. Good up to 0.30, bad over 0.40.
  - fixedCosts: value = recurring bills as a share of monthly income. Good under 0.30, bad over 0.50.
  - debt: value = loan installments as a share of income. Good under 0.30, bad over 0.40. note may say a credit card balance is piling up.
  - budgets: value = budgets that went over. goals: value = dated goals behind schedule.
  - netWorth: value = assets minus debts at month end; three_months_ago to compare.
  - Balances (liquid, owed, netWorth) are taken at the end of the scored month, not today. Name that date when you cite one, such as "saldo akhir Oktober".
  - note explains a status that has no value. unknown means the app could not measure it; never guess it.
- categories: expense categories this month and the month before, with level must, need, want or null.
- goals: dated goals not reached yet, with what each needs per month and what was saved per month lately.

Answer:
- summary: two or three sentences on the overall picture, naming the most urgent problem first. Mention a strength only if it matters.
- steps: exactly three concrete actions for next month, most urgent first, taken from bad and warn pillars. When nothing is bad or warn, give steps that keep or improve the strongest areas. Each step:
  - title: an imperative of at most 9 words with a rupiah amount, such as "Sisihkan Rp 1,5 jt per bulan ke dana darurat".
  - why: one or two sentences citing numbers from the JSON (category names, amounts, changes from last month) that justify it.
Only use numbers that are in the JSON or simple sums and differences of them. Write amounts the Indonesian way: "Rp 1,5 jt", "Rp 900 rb", "Rp 16,8 jt"; months with one decimal ("5,5 bulan"); shares as whole percentages ("31%").`;

const SCHEMA = {
  type: "object",
  properties: {
    summary: { type: "string" },
    steps: {
      type: "array",
      minItems: 3,
      maxItems: 3,
      items: {
        type: "object",
        properties: { title: { type: "string" }, why: { type: "string" } },
        required: ["title", "why"],
      },
    },
  },
  required: ["summary", "steps"],
};

Deno.serve(async (req) => {
  const payload = await req.json().catch(() => null);
  const text = payload === null ? "" : JSON.stringify(payload);
  if (typeof payload !== "object" || !Array.isArray(payload?.pillars) || text.length > MAX_PAYLOAD) {
    return Response.json(
      { error: `expected the diagnosis payload as a JSON object of at most ${MAX_PAYLOAD} characters` },
      { status: 400 },
    );
  }
  // The lite model, like the other functions: gemini-3.8-flash took over 60 s, longer than the
  // app waits, for no better advice.
  return askGemini(INSTRUCTION, text, SCHEMA);
});
