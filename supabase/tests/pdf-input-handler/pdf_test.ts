let handler: (req: Request) => Promise<Response>;
Object.defineProperty(Deno, 'serve', {value: (h: typeof handler) => { handler=h; return {}; }});
Deno.env.set('OPENAI_API_KEY','fixture-not-a-real-key');
const calls: Array<Record<string, unknown>>=[];
globalThis.fetch = async (_url: unknown, init?: RequestInit) => { calls.push(JSON.parse(String(init?.body))); return Response.json({output_text:'synthetic extracted text'}); };
const target=Deno.env.get('PDF_SOURCE') || '../../functions/invoke-llm/index.ts';
await import(new URL(target, import.meta.url).href);
const pdf=(body='%PDF-1.4 synthetic fixture')=>'data:application/pdf;base64,'+btoa(body);
const assert=(v: unknown,m='assertion failed')=>{if(!v)throw Error(m)};
async function invoke(body: unknown, auth=true) { return handler(new Request('http://fixture.invalid',{method:'POST',headers:{'Content-Type':'application/json',...(auth?{Authorization:'Bearer fixture-only'}:{})},body:JSON.stringify(body)})); }
Deno.test('PDF bytes forwarded exactly after authentication',async()=>{calls.length=0;const data=pdf();const r=await invoke({prompt:'Extract',input_file:{filename:'plan.pdf',file_data:data}});assert(r.status===200);const parts=(calls[0].input as any[])[0].content;assert(parts.some((x:any)=>x.type==='input_file'&&x.file_data===data));});
Deno.test('Text and image request contract unchanged',async()=>{calls.length=0;await invoke({prompt:'Text',file_urls:['https://fixture.invalid/image.png'],image_detail:'low',max_output_tokens:500,temperature:0.2,response_json_schema:{type:'object'},schema_name:'fixture'});const b:any=calls[0];assert(b.input[0].content.length===2);assert(b.input[0].content[1].image_url==='https://fixture.invalid/image.png');assert(b.max_output_tokens===500&&b.temperature===0.2&&b.text.format.name==='fixture');});
Deno.test('Missing authentication cannot reach OpenAI',async()=>{calls.length=0;const r=await invoke({input_file:{file_data:pdf()}},false);assert(r.status===401);assert(calls.length===0);});
for(const [name,input] of [['wrong MIME',{file_data:'data:image/png;base64,AAAA'}],['non-PDF bytes',{file_data:pdf('not a PDF')}],['invalid base64',{file_data:'data:application/pdf;base64,!!!!'}],['remote URL',{file_url:'https://fixture.invalid/plan.pdf'}],['array input',[]]]) Deno.test('Reject '+name+' before provider call',async()=>{calls.length=0;const r=await invoke({input_file:input});assert(r.status===400);assert(calls.length===0);});
Deno.test('Eight MB boundary accepted',async()=>{calls.length=0;const r=await invoke({input_file:{file_data:pdf('%PDF-'+ 'x'.repeat(8*1024*1024-5))}});assert(r.status===200);assert(calls.length===1);});
Deno.test('Over eight MB rejected before provider call',async()=>{calls.length=0;const r=await invoke({input_file:{file_data:pdf('%PDF-'+ 'x'.repeat(8*1024*1024-4))}});assert(r.status===400);assert(calls.length===0);});
