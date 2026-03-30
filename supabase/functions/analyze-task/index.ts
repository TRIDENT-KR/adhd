import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

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
    // JWT 인증 검증 (#30)
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

    const { text, currentTime } = await req.json();
    if (!text) throw new Error("음성 텍스트가 없습니다.");

    // 전달받은 currentTime(예: "2026-03-29 21:15")이 없으면 서버 현재시간 사용
    const localTimeStr = currentTime || new Date().toLocaleString("ko-KR", { timeZone: "Asia/Seoul", hour12: false });

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

AVAILABLE FUNCTIONS:

1. "add_single_task"
   - parameters: { "task_name": string, "time": string | null, "date": string | null, "category": "Routine" | "Appointment", "recurrence": "weekly" | "biweekly" | "monthly" | "yearly" | null }
   - Rules: 
     - "time" must be "hh:mm AM/PM" or null. (e.g. "03:00 PM")
     - "date" must be "yyyy-MM-dd" or null. Use the calculated date for immediate actions.
     - "category": Choose one of: "Appointment", "Routine".
       * "Appointment": Use for ANY one-time specific goal, task, or event, including ones occurring TODAY (e.g., "Take medicine at 11:30 oggi", "Meeting tomorrow at 2 PM", "Do laundry tonight"). If it has a specific time or is meant to happen on a specific date (including today), it MUST be an "Appointment". 
       * "Routine": Use ONLY for repeating daily/weekly habits or general non-specific resolutions (e.g., "Stretch every morning", "Drink more water"). Do NOT use Routine for one-time tasks.
     - "recurrence": Use only for non-daily repeating appointments ("monthly", "weekly"). Routines are implicitly daily, so their recurrence is null.

2. "update_task"
   - parameters: { "target_task_name": string, "new_time": string | null, "new_date": string | null, "new_task_name": string | null, "new_category": "Routine" | "Appointment" | null, "new_recurrence": string | null }
   - Rules: Target the task using its semantic name. e.g. "2일에 있는 플랜 3일로 옮겨" -> target_task_name: "플랜", new_date: (calculated 3rd date).

3. "delete_specific_task"
   - parameters: { "target_task_name": string, "target_category": "Routine" | "Appointment" | "all", "target_date": "yyyy-MM-dd" | "all" }
   - Rules: Target the specific task to delete. Identify if the user means to delete a "Routine" or an "Appointment". If unspecified, use "all". If the user mentions a date (like "today"), set target_date accordingly.

4. "clear_all_tasks"
   - parameters: { "target_category": "Routine" | "Appointment" | "all", "target_date": "yyyy-MM-dd" | "all" }
   - Rules: 
     - If user says "Delete all routines" (루틴 다 지워), set target_category: "Routine", target_date: "all".
     - If user says "Delete today's schedule" (오늘 일정 지워/오늘 거 지워/3월 30일 지워), set target_category: "Appointment", target_date: (today's date).
     - ONLY use target_category: "all" if the user says "Delete EVERYTHING" (전부 다 삭제해 / 모든 거 다 지워).
     - If the user specifies a date but doesn't mention "Routine" (루틴), default target_category to "Appointment".

5. "postpone_all_tasks"
   - parameters: { "from_date": "yyyy-MM-dd", "to_date": "yyyy-MM-dd" }
   - Rules: Use when user wants to move ALL tasks from one date to another. If they mentioned a SPECIFIC task to move, use \`update_task\` instead.

6. "mark_task_complete"
   - parameters: { "target_task_name": string }

7. "request_clarification"
   - parameters: { "reason": string }
   - Rules: Use ONLY if the user's request is completely incomprehensible without a final decision.

--- EXAMPLES ---

Input: "오늘 10시 영양제 먹어야지" (Current time: "2026-03-29 08:00")
Output: [{"function_name": "add_single_task", "parameters": {"task_name": "영양제 먹기", "time": "10:00 AM", "date": "2026-03-29", "category": "Appointment", "recurrence": null}}]

Input: "지금부터 1시간 후에 미팅" (Current time: "2026-03-29 14:00")
Output: [{"function_name": "add_single_task", "parameters": {"task_name": "미팅", "time": "03:00 PM", "date": "2026-03-29", "category": "Appointment", "recurrence": null}}]

Input: "2일에 있는 플랜을 3일로 옮겨줘" (Current time: "2026-03-29 14:00")
Output: [{"function_name": "update_task", "parameters": {"target_task_name": "플랜", "new_date": "2026-04-03", "new_time": null, "new_task_name": null, "new_category": null, "new_recurrence": null}}]`;

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
    console.log("🤖 Gemini Raw Response:", responseText);


    const cleanedText = responseText.replace(/```json/g, "").replace(/```/g, "").trim();
    let parsedData = JSON.parse(cleanedText);

    // 1. AI가 혹시라도 배열이 아닌 단일 객체로 보냈을 경우를 대비해 강제로 배열로 감싸줌 (방어 코드)
    if (!Array.isArray(parsedData)) {
      parsedData = [parsedData];
    }

    // 2. 배열을 순회하며 각 항목(item)마다 누락된 값 채워주기
    parsedData = parsedData.map((item: any) => {
      if (!item.function_name) {
        item.function_name = 'add_single_task';
      }
      if (!item.parameters) {
        item.parameters = {};
      }

      // add_single_task 에 대한 필수 파라미터 방어 로직
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

    // 3. 배열 자체를 통째로 반환
    return new Response(JSON.stringify(parsedData), { headers, status: 200 });
  } catch (error: any) {
    return new Response(JSON.stringify({ error: error.message }), { headers, status: 400 });
  }
});
