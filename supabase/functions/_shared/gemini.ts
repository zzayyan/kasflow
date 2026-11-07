// Shared by the Edge Functions that ask Gemini for JSON. GEMINI_API_KEY is a secret set in the
// Supabase dashboard (Edge Functions > Secrets); it never ships in the app.

const MODEL = "gemini-3.5-flash-lite";

/** A piece of the user's turn: text, or an inline image such as a receipt photo. */
export type Part = { text: string } | { inlineData: { mimeType: string; data: string } };

/** Asks Gemini [model] to answer [input] as JSON matching [schema], and returns the response to send
 * back. With [timeoutMs], a slower answer becomes a 504, so the caller can fall back in time. */
export async function askGemini(
  instruction: string,
  input: string | Part[],
  schema: object,
  model = MODEL,
  timeoutMs?: number,
): Promise<Response> {
  try {
    return await ask(instruction, input, schema, model, timeoutMs);
  } catch (e) {
    console.error("gemini", model, String(e)); // a timeout, or the network failing
    return Response.json({ error: "gemini unavailable" }, { status: 504 });
  }
}

async function ask(
  instruction: string,
  input: string | Part[],
  schema: object,
  model: string,
  timeoutMs?: number,
): Promise<Response> {
  const gemini = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-goog-api-key": Deno.env.get("GEMINI_API_KEY") ?? "" },
    body: JSON.stringify({
      systemInstruction: { parts: [{ text: instruction }] },
      contents: [{ role: "user", parts: typeof input === "string" ? [{ text: input }] : input }],
      generationConfig: { responseMimeType: "application/json", responseJsonSchema: schema },
    }),
    signal: timeoutMs === undefined ? undefined : AbortSignal.timeout(timeoutMs),
  });
  if (!gemini.ok) {
    console.error("gemini", gemini.status, await gemini.text());
    // 429 (free-tier quota) passes through so the app knows to wait; anything else is upstream failing.
    return Response.json({ error: "gemini unavailable" }, { status: gemini.status === 429 ? 429 : 502 });
  }

  const body = await gemini.json();
  const parts: { text?: string; thought?: boolean }[] = body.candidates?.[0]?.content?.parts ?? [];
  const answer = parts.find((p) => typeof p.text === "string" && !p.thought)?.text;
  if (!answer) {
    console.error("gemini returned no answer", JSON.stringify(body));
    return Response.json({ error: "gemini returned no answer" }, { status: 502 });
  }
  return new Response(answer, { headers: { "content-type": "application/json" } });
}
