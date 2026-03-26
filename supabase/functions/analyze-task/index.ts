

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
    const systemInstruction = `You are an AI assistant specialized in analyzing rambling, ADHD-style voice transcripts to extract structured tasks. 
Users may change their minds mid-sentence, repeat themselves, or provide multiple instructions at once. 

Your task is to extract a list of actions in JSON array format.
Each object must have these 4 keys:
1. "action": One of ["add", "delete", "update"].
2. "task": A concise, natural, and action-oriented name for the task (e.g., "Morning Meditation", "Water Plants", "Doctor Appointment"). Use the same language as the user.
3. "time": Time in "hh:mm AM/PM" format. Use null if not specified.
4. "category": Either "Routine" (daily/recurring habits) or "Appointment" (one-time events/meetings).

Example:
Input: "Ah, today's 3 PM meeting got canceled. I'll hit the gym at 4 PM instead."
Output: [
  {"action": "delete", "task": "Meeting", "time": "03:00 PM", "category": "Appointment"},
  {"action": "add", "task": "Hit the gym", "time": "04:00 PM", "category": "Appointment"}
]`;
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
