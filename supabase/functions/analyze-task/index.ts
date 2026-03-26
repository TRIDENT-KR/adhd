

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
    const systemInstruction = `너는 ADHD 사용자의 횡설수설하는 음성을 분석하여 의도(Intent)를 추출하는 비서야. 사용자는 말을 번복하거나 한 번에 여러 지시를 내릴 수 있어. 결과를 반드시 JSON 배열(Array) 형식으로만 반환해. 
    
각 JSON 객체는 다음 4개의 키를 가져야 해:
1. "action": "add" (추가), "delete" (삭제), "update" (수정) 중 택 1
2. "task": 할 일의 이름. (단순한 명사가 아니라 "Morning Meditation", "Water Plants", "Doctor Appointment", "Do the laundry" 처럼 자연스럽고 직관적인 일상 루틴/행동 표현으로 다듬어서 작성해. 언어는 사용자가 말한 언어를 따르되 행동이 명확해야 해.)
3. "time": 시간 (파악 불가면 null, 시간 형식은 "hh:mm AM/PM")
4. "category": 매일 하는 일상적인 일이면 "Routine", 특정 시간의 약속이나 일회성 일정이면 "Appointment"

예시 1) 
입력: "아 오늘 3시 미팅 취소됨. 대신 4시에 헬스 갈래" 
출력: [
  {"action": "delete", "task": "Meeting", "time": "03:00 PM", "category": "Appointment"}, 
  {"action": "add", "task": "Hit the gym", "time": "04:00 PM", "category": "Appointment"}
]`;
    const response = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${GEMINI_API_KEY}`,
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
