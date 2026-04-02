import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

Deno.serve(async (req: Request) => {
  // iOS 클라이언트 전용 — CORS를 Supabase 프로젝트 도메인으로 제한
  const origin = req.headers.get('Origin') ?? '';
  const supabaseProjectOrigin = Deno.env.get('SUPABASE_URL') ?? '';
  // iOS 클라이언트는 Origin 헤더를 보내지 않음 → Dashboard/웹 테스트 요청만 CORS 검증
  const corsOrigin = (origin === supabaseProjectOrigin || origin === 'https://supabase.com')
    ? origin
    : 'https://supabase.com';

  const headers = {
    "Access-Control-Allow-Origin": corsOrigin,
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type",
    "Content-Type": "application/json",
  };

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers });
  }

  try {
    // 1. Verify the user's JWT
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: "Missing authorization header" }),
        { headers, status: 401 }
      );
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    // Client with user's JWT to get their identity
    const userClient = createClient(supabaseUrl, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: { user }, error: userError } = await userClient.auth.getUser();
    if (userError || !user) {
      return new Response(
        JSON.stringify({ error: "Invalid or expired session" }),
        { headers, status: 401 }
      );
    }

    console.log(`🗑️ Deleting account for user: ${user.id} (${user.email})`);

    // 2. Use service role to delete the user (admin privilege required)
    const adminClient = createClient(supabaseUrl, supabaseServiceKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    const { error: deleteError } = await adminClient.auth.admin.deleteUser(user.id);
    if (deleteError) {
      console.error("❌ Failed to delete user:", deleteError);
      return new Response(
        JSON.stringify({ error: `Failed to delete account: ${deleteError.message}` }),
        { headers, status: 500 }
      );
    }

    console.log(`✅ Account deleted successfully: ${user.id}`);
    return new Response(
      JSON.stringify({ success: true, message: "Account deleted" }),
      { headers, status: 200 }
    );
  } catch (error: any) {
    console.error("❌ Unexpected error:", error);
    return new Response(
      JSON.stringify({ error: error.message }),
      { headers, status: 500 }
    );
  }
});
