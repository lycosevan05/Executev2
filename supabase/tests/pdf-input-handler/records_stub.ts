export async function getUser(req: Request) { if(req.headers.get("authorization")!=="Bearer fixture-only") throw new Response("Unauthorized",{status:401}); return {id:"fixture"}; }
