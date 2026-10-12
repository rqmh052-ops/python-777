import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

// Load the exact worker.js source without relying on a package.json module setting.
const workerSource = await readFile(new URL('../worker.js', import.meta.url), 'utf8');
const { default: worker } = await import(`data:text/javascript;base64,${Buffer.from(workerSource).toString('base64')}`);

const { publicKey, privateKey } = await crypto.subtle.generateKey(
  { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1,0,1]), hash: 'SHA-256' },
  true, ['sign', 'verify']);
const jwk = await crypto.subtle.exportKey('jwk', publicKey);
jwk.kid = 'unit-test-key'; jwk.alg = 'RS256'; jwk.use = 'sig';
globalThis.fetch = async () => new Response(JSON.stringify({keys:[jwk]}), {
  status:200, headers:{'content-type':'application/json','cache-control':'public, max-age=3600'}
});
function b64u(value) { return Buffer.from(value).toString('base64url'); }
async function token(sub, email) {
  const h=b64u(JSON.stringify({alg:'RS256',kid:'unit-test-key',typ:'JWT'}));
  const p=b64u(JSON.stringify({iss:'https://accounts.google.com',aud:'web-client-id',sub,email,email_verified:true,iat:Math.floor(Date.now()/1000),exp:Math.floor(Date.now()/1000)+3600}));
  const inp=new TextEncoder().encode(`${h}.${p}`);
  const sig=await crypto.subtle.sign({name:'RSASSA-PKCS1-v1_5'},privateKey,inp);
  return `${h}.${p}.${b64u(new Uint8Array(sig))}`;
}
class MockR2 {
  objects=new Map();
  async get(key) {
    const o=this.objects.get(key); if(!o) return null;
    return {key,size:o.bytes.length,uploaded:o.uploaded,customMetadata:o.customMetadata,
      body:new Blob([o.bytes]).stream(),
      async json(){return JSON.parse(new TextDecoder().decode(o.bytes));},
      writeHttpMetadata(headers){headers.set('content-type',o.contentType || 'application/octet-stream');}
    };
  }
  async delete(key) { this.objects.delete(key); }
  async head(key) { const o=this.objects.get(key); return o ? {size:o.bytes.length} : null; }
  async put(key,value,opts={}) {
    const bytes=typeof value==='string' ? new TextEncoder().encode(value) : new Uint8Array(value);
    this.objects.set(key,{bytes,uploaded:new Date(),customMetadata:opts.customMetadata || {},contentType:opts.httpMetadata?.contentType});
    return {};
  }
  async list({prefix,limit=1000}) {
    const objects=[...this.objects.entries()].filter(([k])=>k.startsWith(prefix)).slice(0,limit).map(([key,o])=>({key,size:o.bytes.length,uploaded:o.uploaded,customMetadata:o.customMetadata}));
    return {objects,truncated:false,cursor:undefined};
  }
}
const env={FILES:new MockR2(),GOOGLE_CLIENT_ID:'web-client-id'};
let r=await worker.fetch(new Request('https://bynux.test/v1/health'),env);
assert.equal(r.status,200); assert.equal((await r.json()).auth_configured,true);
r=await worker.fetch(new Request('https://bynux.test/v1/files'),env);
assert.equal(r.status,401,'missing token rejected');
const t1=await token('user_1','one@example.com');
const h1={authorization:`Bearer ${t1}`};
r=await worker.fetch(new Request('https://bynux.test/v1/profile',{headers:h1}),env);
assert.equal(r.status,200); const p=await r.json(); assert.equal(p.email,'one@example.com'); assert.ok(p.createdAt);
const originalCreatedAt = p.createdAt;
r=await worker.fetch(new Request('https://bynux.test/v1/profile',{headers:h1}),env);
assert.equal((await r.json()).createdAt, originalCreatedAt, 'join date remains stable');
r=await worker.fetch(new Request('https://bynux.test/v1/files/demo.py',{method:'PUT',headers:{...h1,'content-type':'text/x-python','content-length':'10'},body:'print(123)'}),env);
assert.equal(r.status,200); assert.equal((await r.json()).name,'demo.py');
r=await worker.fetch(new Request('https://bynux.test/v1/files/demo.txt',{method:'PUT',headers:{...h1,'content-length':'3'},body:'abc'}),env);
assert.equal(r.status,400,'only Python files can be uploaded');
r=await worker.fetch(new Request('https://bynux.test/v1/files/large.py',{method:'PUT',headers:{...h1,'content-length':String(1024*1024+1)},body:'x'}),env);
assert.equal(r.status,413,'file size cap is enforced');
r=await worker.fetch(new Request('https://bynux.test/v1/files',{headers:h1}),env);
assert.equal((await r.json()).files.length,1);
r=await worker.fetch(new Request('https://bynux.test/v1/files/demo.py',{headers:h1}),env);
assert.equal(r.status,200); assert.equal(await r.text(),'print(123)');
r=await worker.fetch(new Request('https://bynux.test/v1/files/demo.py',{method:'DELETE',headers:h1}),env);
assert.equal(r.status,405,'delete is disabled');
const t2=await token('user_2','two@example.com');
r=await worker.fetch(new Request('https://bynux.test/v1/files',{headers:{authorization:`Bearer ${t2}`}}),env);
assert.equal((await r.json()).files.length,0,'users are isolated');

// ── long-lived Bynux sessions (remember me) ──
r=await worker.fetch(new Request('https://bynux.test/v1/health'),env);
assert.equal((await r.json()).sessions,true,'health reports session support');
r=await worker.fetch(new Request('https://bynux.test/v1/session',{method:'POST',headers:h1,body:'{}'}),env);
assert.equal(r.status,200); const grant=await r.json();
assert.match(grant.sessionToken,/^bxs_[A-Za-z0-9_-]{43}$/); assert.ok(Date.parse(grant.expiresAt)>Date.now()+100*24*3600*1000,'session lasts months');
const hs={authorization:`Bearer ${grant.sessionToken}`};
assert.ok(![...env.FILES.objects.keys()].some((k)=>k.includes(grant.sessionToken)),'raw session token is never stored');
r=await worker.fetch(new Request('https://bynux.test/v1/profile',{headers:hs}),env);
assert.equal(r.status,200); assert.equal((await r.json()).email,'one@example.com','session maps to the same account');
r=await worker.fetch(new Request('https://bynux.test/v1/files',{headers:hs}),env);
assert.equal((await r.json()).files.length,1,'session sees the same files as the Google token');
r=await worker.fetch(new Request('https://bynux.test/v1/files/via_session.py',{method:'PUT',headers:{...hs,'content-length':'8'},body:'print(1)\n'.slice(0,8)}),env);
assert.equal(r.status,200,'upload works with a session token');
r=await worker.fetch(new Request('https://bynux.test/v1/session',{method:'POST',headers:hs,body:'{}'}),env);
assert.equal(r.status,403,'a session cannot mint another session');
r=await worker.fetch(new Request('https://bynux.test/v1/session',{headers:h1}),env);
assert.equal(r.status,405,'session endpoint is POST only');
r=await worker.fetch(new Request('https://bynux.test/v1/files',{headers:{authorization:'Bearer bxs_'+'A'.repeat(43)}}),env);
assert.equal(r.status,401,'unknown session rejected');
r=await worker.fetch(new Request('https://bynux.test/v1/files',{headers:{authorization:'Bearer bxs_short'}}),env);
assert.equal(r.status,401,'malformed session rejected');
// expiry: an expired session is rejected and removed
r=await worker.fetch(new Request('https://bynux.test/v1/session',{method:'POST',headers:{authorization:`Bearer ${await token('user_1','one@example.com')}`},body:'{}'}),env);
const old=(await r.json()).sessionToken;
const oldKey=[...env.FILES.objects.keys()].filter((k)=>k.startsWith('sessions/')).pop();
const oldData=JSON.parse(new TextDecoder().decode(env.FILES.objects.get(oldKey).bytes)); oldData.expiresAt=Date.now()-1000;
env.FILES.objects.get(oldKey).bytes=new TextEncoder().encode(JSON.stringify(oldData));
r=await worker.fetch(new Request('https://bynux.test/v1/files',{headers:{authorization:`Bearer ${old}`}}),env);
assert.equal(r.status,401,'expired session rejected'); assert.ok(!env.FILES.objects.has(oldKey),'expired session is deleted');
// another account's session never reaches this account's files
r=await worker.fetch(new Request('https://bynux.test/v1/session',{method:'POST',headers:{authorization:`Bearer ${t2}`},body:'{}'}),env);
const s2=(await r.json()).sessionToken;
r=await worker.fetch(new Request('https://bynux.test/v1/files',{headers:{authorization:`Bearer ${s2}`}}),env);
assert.equal((await r.json()).files.length,0,'sessions are isolated per account');
// revoke
r=await worker.fetch(new Request('https://bynux.test/v1/session/revoke',{method:'POST',headers:hs,body:'{}'}),env);
assert.equal(r.status,200);
r=await worker.fetch(new Request('https://bynux.test/v1/files',{headers:hs}),env);
assert.equal(r.status,401,'revoked session no longer works');
r=await worker.fetch(new Request('https://bynux.test/v1/files',{headers:h1}),env);
assert.equal(r.status,200,'Google token still works after revoking a session');
console.log('Worker mocked integration tests: PASS (health, auth, profile, upload, list, download, no-delete, account isolation, sessions)');
