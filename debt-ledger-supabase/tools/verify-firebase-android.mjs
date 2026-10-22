// validate_only performs no delivery and sends no message to the device.
import {readFile} from 'node:fs/promises';
import {createSign} from 'node:crypto';
import {execFileSync} from 'node:child_process';
const [accountPath,projectRef]=process.argv.slice(2);
if(!accountPath || !/^[a-z]{20}$/.test(projectRef ?? ''))throw new Error('Usage: node tools/verify-firebase-android.mjs <service-account-path> <supabase-project-ref>');
const sa=JSON.parse(await readFile(accountPath,'utf8'));
if(sa.project_id!=='muthbat-6de17')throw new Error('Firebase project mismatch');
const encoded=value=>Buffer.from(JSON.stringify(value)).toString('base64url');
const now=Math.floor(Date.now()/1000);
const unsigned=`${encoded({alg:'RS256',typ:'JWT'})}.${encoded({iss:sa.client_email,scope:'https://www.googleapis.com/auth/firebase.messaging',aud:'https://oauth2.googleapis.com/token',iat:now,exp:now+3600})}`;
const signature=createSign('RSA-SHA256').update(unsigned).sign(sa.private_key).toString('base64url');
const auth=await fetch('https://oauth2.googleapis.com/token',{method:'POST',body:new URLSearchParams({grant_type:'urn:ietf:params:oauth:grant-type:jwt-bearer',assertion:`${unsigned}.${signature}`}),signal:AbortSignal.timeout(15000)});
if(!auth.ok)throw new Error(`Firebase OAuth rejected (${auth.status})`);
const {access_token}=await auth.json();
const result=JSON.parse(execFileSync('supabase.exe',['db','query','--linked','--project-ref',projectRef,
 "select push_token from public.device_push_tokens where platform='android' and is_active order by last_seen_at desc limit 1;"],{encoding:'utf8',timeout:30000}));
const token=result.rows?.[0]?.push_token;
if(!token)throw new Error('No active Android token; open the new Android app after login');
const response=await fetch(`https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`,{
 method:'POST',headers:{Authorization:`Bearer ${access_token}`,'Content-Type':'application/json'},signal:AbortSignal.timeout(15000),
 body:JSON.stringify({validate_only:true,message:{token,notification:{title:'Muthbat validation',body:'Validation only'},android:{notification:{channel_id:'muthbat_updates',icon:'ic_stat_notification',visibility:'PRIVATE'}}}})});
const body=await response.json();
if(!response.ok){console.error(JSON.stringify({validation:'failed',status:response.status,code:body.error?.status,details:body.error?.details?.map(item=>item.errorCode).filter(Boolean)}));process.exit(1);}
console.log(JSON.stringify({validation:'passed',delivery:false,project:sa.project_id,oauth:true,fcm_http_v1:true}));
