
const GEMINI_API_KEY = Deno.env.get('GEMINI_API_KEY');

Deno.serve(async (req: Request) => {
  // CORS 허용 (아이폰 클라이언트 통신용)
  const headers = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Content-Type': 'application/json'
  };

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers });
  }

  try {
    const { text } = await req.json();
    if (!text) throw new Error("음성 텍스트가 없습니다.");

    // ADHD 타겟 유저를 위한 시스템 프롬프트
    // 최적화 이력: 20가지 임상 기반 ADHD 발화 패턴 테스트 통과 (feature/llm-prompt-testing)
    const systemInstruction = `You are an AI assistant specialized in analyzing rambling, ADHD-style voice transcripts to extract structured tasks.
Users may change their minds mid-sentence, repeat themselves, or provide multiple instructions at once.

Your task is to extract a list of actions in JSON array format.
Each object must have these 4 keys:

1. "action": One of ["add", "delete", "update"].

2. "task": A concise, action-oriented name. Use the same language as the user. Ignore filler and emotional commentary.

3. "time": Time in "hh:mm AM/PM" format.
   - Use null for vague expressions: "later", "sometime", "tonight", "eventually", "after work", "whenever", "this afternoon".
   - TIME RANGE rule: "from X to Y" → extract ONE item with the START time only. Never split a range into two items.

4. "category": Use "Routine" or "Appointment" — check rules in this exact order:
   RULE 1 — Explicit recurrence → "Routine": user says "every day", "daily", "always", "every morning", "recurring", or calls it a "routine".
   RULE 2 — Explicit one-time anchor → "Appointment": user says "tomorrow", "this Friday", "next week", a specific date, "for now", "just add [it]". A task phrased as a one-time immediate action is always "Appointment".
   RULE 3 — Ambiguous (no explicit signal) → classify by task nature:
     - "Routine": pure personal physical habits — exercise, sleep, hygiene, regular mealtimes.
     - "Appointment": everything else — errands, payments, calls, emails, work tasks, social events, shopping. When in doubt, default to "Appointment".

SPECIAL RULES:
RULE 4 — Return [] (empty array) when:
   a) User reports a completion or status ("I finished X", "I completed Y", "I did Z today") with no add/delete/update request.
   b) User requests a bulk operation on unnamed existing tasks ("move all my routines", "push everything earlier"). You don't have the existing list, so return [].

RULE 5 — Explicit cancellation (last valid instruction wins):
   If a user says "add X — actually no, cancel that — add Y instead", extract ONLY the final confirmed instruction. Drop all explicitly cancelled items.

RULE 6 — Deduplication:
   If the user repeats or re-emphasizes the same task multiple times, extract it exactly ONCE.

--- EXAMPLES ---

Input: "Add a 5 AM jog — actually no, cancel that. Make it a 7 AM walk every day."
Output: [{"action":"add","task":"Morning Walk","time":"07:00 AM","category":"Routine"}]

Input: "Block 'Deep Work' from 6 AM to 10 PM. And add a 9 PM wind-down routine every night."
Output: [
  {"action":"add","task":"Deep Work","time":"06:00 AM","category":"Appointment"},
  {"action":"add","task":"Wind-down","time":"09:00 PM","category":"Routine"}
]

Input: "I need to pay the rent, buy groceries, and start a daily journaling habit. Add all."
Output: [
  {"action":"add","task":"Pay rent","time":null,"category":"Appointment"},
  {"action":"add","task":"Buy groceries","time":null,"category":"Appointment"},
  {"action":"add","task":"Daily journaling","time":null,"category":"Routine"}
]

Input: "Just finished my morning run! Feeling great."
Output: []

Input: "Move all my morning routines to the afternoon."
Output: []`;
    const response = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=${GEMINI_API_KEY}`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          system_instruction: { parts: [{ text: systemInstruction }] },
          contents: [{ role: 'user', parts: [{ text }] }],
          generationConfig: { 
            response_mime_type: 'application/json', 
            temperature: 0.1 
          }
        })
      }
    );

    const data = await response.json();

    if (!response.ok) {
      console.error("🔥 Gemini API Error:", data);
      throw new Error(`Gemini API Error: ${data.error?.message || response.status}`);
    }

    if (!data.candidates || data.candidates.length === 0) {
      console.error("⚠️ No candidates returned:", data);
      throw new Error("Gemini API returned no candidates.");
    }

    const responseText = data.candidates[0].content.parts[0].text;
    console.log("🎤 아이폰에서 들어온 음성 텍스트:", text); 
    console.log("🤖 Gemini Raw Response:", responseText);


    const cleanedText = responseText.replace(/```json/g, "").replace(/```/g, "").trim();
    let parsedData = JSON.parse(cleanedText);

    // 1. AI가 혹시라도 배열이 아닌 단일 객체로 보냈을 경우를 대비해 강제로 배열로 감싸줌 (방어 코드)
    if (!Array.isArray(parsedData)) {
      parsedData = [parsedData];
    }

    // 2. 배열을 순회하며 각 항목(item)마다 누락된 값 채워주기
    parsedData = parsedData.map((item: any) => {
      // Swift에서 task는 non-optional이므로 null이면 안 됨
      if (!item.task) {
        item.task = text.length > 20 ? text.substring(0, 20) + "..." : (text || "할 일 확인 필요");
      }
      
      // category가 Routine이나 Appointment가 아니면 Routine으로 기본값 설정
      if (item.category !== 'Routine' && item.category !== 'Appointment') {
        item.category = 'Routine';
      }

      // action이 누락되었을 경우 기본값 'add'로 설정
      if (!item.action) {
        item.action = 'add';
      }

      return item;
    });

    // 3. 배열 자체를 통째로 반환
    return new Response(JSON.stringify(parsedData), { headers, status: 200 });
  } catch (error: any) {
    return new Response(JSON.stringify({ error: error.message }), { headers, status: 400 });
  }
});
