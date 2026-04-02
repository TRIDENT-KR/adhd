import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const GEMINI_API_KEY = Deno.env.get('GEMINI_API_KEY');

// 유저당 분당 최대 호출 횟수 (Gemini 비용 증폭 방지)
const RATE_LIMIT_MAX = 30;
const RATE_LIMIT_WINDOW_MS = 60_000;

// 인메모리 rate limit 맵 (Edge Function 인스턴스 내 유효)
const rateLimitMap = new Map<string, number[]>();

function isRateLimited(userId: string): boolean {
  const now = Date.now();
  const windowStart = now - RATE_LIMIT_WINDOW_MS;
  const timestamps = (rateLimitMap.get(userId) ?? []).filter(t => t > windowStart);
  if (timestamps.length >= RATE_LIMIT_MAX) return true;
  timestamps.push(now);
  rateLimitMap.set(userId, timestamps);
  return false;
}

Deno.serve(async (req: Request) => {
  // iOS 클라이언트 전용 — CORS를 Supabase 프로젝트 도메인으로 제한
  const origin = req.headers.get('Origin') ?? '';
  const supabaseProjectOrigin = Deno.env.get('SUPABASE_URL') ?? '';
  // iOS 클라이언트는 Origin 헤더를 보내지 않음 → Dashboard/웹 테스트 요청만 CORS 검증
  const corsOrigin = (origin === supabaseProjectOrigin || origin === 'https://supabase.com')
    ? origin
    : 'https://supabase.com';

  const headers = {
    'Access-Control-Allow-Origin': corsOrigin,
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Content-Type': 'application/json'
  };

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers });
  }

  try {
    // JWT 인증 검증
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return new Response(JSON.stringify({ error: 'Missing authorization header' }), { headers, status: 401 });
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY')!;
    const supabase = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user }, error: authError } = await supabase.auth.getUser();
    if (authError || !user) {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), { headers, status: 401 });
    }

    // Rate limiting: 유저당 분당 30회 초과 시 429 반환
    if (isRateLimited(user.id)) {
      return new Response(JSON.stringify({ error: 'Rate limit exceeded. Please wait before retrying.' }), { headers, status: 429 });
    }

    const { text, currentTime, language } = await req.json();
    if (!text) throw new Error("음성 텍스트가 없습니다.");

    // 전달받은 currentTime이 없으면 서버 현재시간 사용
    // 프롬프트 인젝션 방지: 엄격한 datetime 형식(yyyy-MM-dd HH:mm)만 허용
    const timeRegex = /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/;
    const localTimeStr = (typeof currentTime === "string" && timeRegex.test(currentTime))
      ? currentTime
      : new Date().toLocaleString("ko-KR", { timeZone: "Asia/Seoul", hour12: false });

    // 사용자 언어 설정 — 허용된 값만 사용 (프롬프트 인젝션 방지)
    const ALLOWED_LANGUAGES = new Set(["en", "ko", "ja"]);
    const userLanguage: string = ALLOWED_LANGUAGES.has(language) ? language : "en";

    // ADHD 타겟 유저를 위한 시스템 프롬프트
    const finalPrompt = `You are an AI Command Router specialized in analyzing rambling, ADHD-style voice transcripts and translating them into precise function calls.
Users may change their minds mid-sentence, repeat themselves, or give multiple disparate instructions. Your job is to extract their FINAL INTENT and map it to specific functions.

Return a JSON array of objects. Each object represents a function call with exactly two keys: "function_name" and "parameters".

### CRITICAL CONTEXT FOR DATE & TIME
The user's current local date and time is: \`${localTimeStr}\` (Format: yyyy-MM-dd HH:mm)
Please use this EXACT time to resolve any relative time references! You MUST do the math yourself.
- "Today" (오늘) means the date part of the current time.
- "Tomorrow" (내일) means the day after the current time.
- "In 1 hour" (1시간 뒤, 1시간 후), "After 10 mins" MUST be calculated mathematically from the current time. The output MUST be formatted as "hh:mm AM/PM".
- "On the 2nd" (2일에) or "On the 3rd" means the 2nd or 3rd day of the CURRENT MONTH (or next month if that date has already passed in the current month). Output must be "yyyy-MM-dd".

### USER LANGUAGE
The user's selected language is: "${userLanguage}" (one of: "en", "ko", "ja").
When using "handle_off_topic_chat", your witty message MUST be written ENTIRELY in this language.

### OUT-OF-DOMAIN DETECTION (HIGHEST PRIORITY RULE)
This app's ONLY purpose is task, routine, and appointment management.
If the user's input is NOT related to adding, editing, deleting, postponing, or completing tasks/routines/appointments — you MUST use "handle_off_topic_chat" and NOTHING else.

Examples of OUT-OF-DOMAIN inputs (must use handle_off_topic_chat):
- General chat or greetings: "How are you?", "Hi there", "안녕", "こんにちは"
- Questions unrelated to tasks: "What's the weather?", "날씨 어때", "Tell me a joke", "피자 레시피 알려줘"
- Philosophical or general questions: "What is the meaning of life?", "AI가 뭐야"
- Emotional venting without task intent: "I'm so tired", "오늘 힘들다", "I hate Mondays"
- Nonsense or gibberish: "blah blah blah", "asdfasdf", "ㅋㅋㅋ"
- Requests to do things outside app scope: "Send a message to my friend", "Play music"

Do NOT use "add_single_task", "request_clarification", or any other task function for these inputs.
"request_clarification" is ONLY for task-related requests that are ambiguous (e.g., missing a task name).

AVAILABLE FUNCTIONS:

1. "add_single_task"
   - parameters: { "task_name": string, "time": string | null, "date": string | null, "category": "Routine" | "Appointment", "recurrence": "weekly" | "biweekly" | "monthly" | "yearly" | null }
   - Rules:
     - "time" must be "hh:mm AM/PM" or null. (e.g. "03:00 PM")
     - IMPORTANT: If the user does NOT explicitly mention a specific time, "time" MUST be null. Do NOT guess or infer a default time. Only set "time" when the user clearly states a time (e.g. "at 3", "10 o'clock", "1시간 후", "오후 2시").
     - "date" must be "yyyy-MM-dd" or null. Use the calculated date for immediate actions.
     - "category": Choose one of: "Appointment", "Routine".
       * "Appointment": Use for ANY one-time specific goal, task, or event, including ones occurring TODAY (e.g., "Take medicine at 11:30 oggi", "Meeting tomorrow at 2 PM", "Do laundry tonight"). If it has a specific time or is meant to happen on a specific date (including today), it MUST be an "Appointment". 
       * "Routine": Use ONLY for repeating daily/weekly habits or general non-specific resolutions (e.g., "Stretch every morning", "Drink more water"). Do NOT use Routine for one-time tasks.
     - "recurrence": Use only for non-daily repeating appointments ("monthly", "weekly"). Routines are implicitly daily, so their recurrence is null.

2. "update_task"
   - parameters: { "target_task_name": string, "new_time": string | null, "new_date": string | null, "new_task_name": string | null, "new_category": "Routine" | "Appointment" | null, "new_recurrence": string | null }

3. "delete_specific_task"
   - parameters: { "target_task_name": string, "target_category": "Routine" | "Appointment" | "all", "target_date": "yyyy-MM-dd" | "all" }

4. "clear_all_tasks"
   - parameters: { "target_category": "Routine" | "Appointment" | "all", "target_date": "yyyy-MM-dd" | "all" }
   - Rules:
     - "Delete all routines" → target_category: "Routine", target_date: "all"
     - "Delete today's schedule" → target_category: "Appointment", target_date: (today)
     - "Delete EVERYTHING" → target_category: "all", target_date: "all"

5. "postpone_all_tasks"
   - parameters: { "from_date": "yyyy-MM-dd", "to_date": "yyyy-MM-dd" }

6. "mark_task_complete"
   - parameters: { "target_task_name": string }

7. "request_clarification"
   - parameters: { "reason": string }
   - Rules: Use ONLY if the input is task-related but critically ambiguous. NOT for off-topic inputs.

8. "handle_off_topic_chat"  ← USE THIS for any input unrelated to task/routine management
   - parameters: { "message": string }
   - Rules:
     - If the user asks something outside the scope of a task planner, DO NOT explain why you can't do it. Instead, you MUST generate a very short, witty, and friendly response.
     - You MUST output this response in the exact language the user selected in the app settings ("${userLanguage}"). DO NOT output in English unless the selected language is English.
     - Be playful and friendly — NOT robotic or scolding.
     - Examples by language:
       * en: "Ha, that's above my pay grade! 😄 What else can I add to your list?"
       * ko: "그건 제가 할 수 없는 일이에요! 다른 걸 물어봐주시겠어요? 😊"
       * ja: "それは私の専門外です！😅 他のことを聞いていただけますか？"

--- EXAMPLES ---

Input: "오늘 10시 영양제 먹어야지" (Current time: "2026-03-29 08:00")
Output: [{"function_name": "add_single_task", "parameters": {"task_name": "영양제 먹기", "time": "10:00 AM", "date": "2026-03-29", "category": "Appointment", "recurrence": null}}]

Input: "지금부터 1시간 후에 미팅" (Current time: "2026-03-29 14:00")
Output: [{"function_name": "add_single_task", "parameters": {"task_name": "미팅", "time": "03:00 PM", "date": "2026-03-29", "category": "Appointment", "recurrence": null}}]

Input: "2일에 있는 플랜을 3일로 옮겨줘" (Current time: "2026-03-29 14:00")
Output: [{"function_name": "update_task", "parameters": {"target_task_name": "플랜", "new_date": "2026-04-03", "new_time": null, "new_task_name": null, "new_category": null, "new_recurrence": null}}]

Input: "날씨 어때?" (language: "ko")
Output: [{"function_name": "handle_off_topic_chat", "parameters": {"message": "날씨는 모르지만, 오늘 할 일은 알고 싶어요! ☀️ 뭘 기록해 드릴까요?"}}]

Input: "Tell me a joke" (language: "en")
Output: [{"function_name": "handle_off_topic_chat", "parameters": {"message": "Jokes? I only know task punchlines! 😄 What can I add to your list today?"}}]

Input: "ジョークを教えて" (language: "ja")
Output: [{"function_name": "handle_off_topic_chat", "parameters": {"message": "ジョークより予定管理が得意です！😄 何か追加しましょうか？"}}]`;

    const response = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=${GEMINI_API_KEY}`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          system_instruction: { parts: [{ text: finalPrompt }] },
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
    console.log("🌐 사용자 언어:", userLanguage);
    console.log("🤖 Gemini Raw Response:", responseText);

    const cleanedText = responseText.replace(/```json/g, "").replace(/```/g, "").trim();
    let parsedData = JSON.parse(cleanedText);

    // 1. 배열이 아닌 단일 객체인 경우 배열로 감싸기 (방어 코드)
    if (!Array.isArray(parsedData)) {
      parsedData = [parsedData];
    }

    // 2. 각 항목 정규화
    parsedData = parsedData.map((item: any) => {
      if (!item.function_name) {
        item.function_name = 'add_single_task';
      }
      if (!item.parameters) {
        item.parameters = {};
      }

      // handle_off_topic_chat 방어 로직
      if (item.function_name === 'handle_off_topic_chat') {
        if (!item.parameters.message || typeof item.parameters.message !== 'string') {
          if (userLanguage === 'ko') {
            item.parameters.message = "앱의 핵심 기능과 관련된 내용만 도움을 드릴 수 있어요! 😊 할 일을 말씀해 주세요.";
          } else if (userLanguage === 'ja') {
            item.parameters.message = "タスク管理に関することのみお手伝いできます！😊 何か追加しましょうか？";
          } else {
            item.parameters.message = "I can only help with tasks and routines! 😊 What shall we add to your list?";
          }
        }
        return item;
      }

      // add_single_task 필수 파라미터 방어 로직
      if (item.function_name === 'add_single_task') {
        if (!item.parameters.task_name) {
          item.parameters.task_name = text.length > 20 ? text.substring(0, 20) + "..." : (text || "할 일 확인 필요");
        }

        if (item.parameters.category !== 'Routine' && item.parameters.category !== 'Appointment') {
          item.parameters.category = 'Appointment';
        }

        if (item.parameters.date && !/^\d{4}-\d{2}-\d{2}$/.test(item.parameters.date)) {
          item.parameters.date = null;
        }

        const validRecurrence = ['weekly', 'biweekly', 'monthly', 'yearly'];
        if (item.parameters.recurrence && !validRecurrence.includes(item.parameters.recurrence)) {
          item.parameters.recurrence = null;
        }
      }

      return item;
    });

    // 3. 배열 전체 반환
    return new Response(JSON.stringify(parsedData), { headers, status: 200 });
  } catch (error: any) {
    return new Response(JSON.stringify({ error: error.message }), { headers, status: 400 });
  }
});
