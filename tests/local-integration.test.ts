import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync, spawn, type ChildProcess} from 'node:child_process';
import {createClient} from '@supabase/supabase-js';

test('local API creates a parcel, records a labor and processes NDVI', {skip: process.env.TEST_LOCAL_SUPABASE !== '1', timeout:120000}, async () => {
  const status = execFileSync('npx', ['supabase', 'status', '-o', 'env'], {encoding: 'utf8'});
  const values = Object.fromEntries(status.split('\n').filter(x => x.includes('=')).map(line => {
    const pos = line.indexOf('=');
    return [line.slice(0, pos), line.slice(pos + 1).replace(/^"|"$/g, '')];
  }));
  process.env.SUPABASE_URL = values.API_URL;
  process.env.SUPABASE_ANON_KEY = values.ANON_KEY;
  process.env.SUPABASE_SERVICE_ROLE_KEY = values.SERVICE_ROLE_KEY;
  const {buildApp} = await import('../src/app.js');
  const app = await buildApp();
  const admin = createClient(values.API_URL, values.SERVICE_ROLE_KEY, {auth:{persistSession:false}});
  const email = `test-${crypto.randomUUID()}@example.invalid`;
  const password = crypto.randomUUID();
  const {data: created, error: createError} = await admin.auth.admin.createUser({email,password,email_confirm:true});
  assert.ifError(createError);
  const userId = created.user!.id;
  let orgId = '';
  let worker: ChildProcess | undefined;
  try {
    const client = createClient(values.API_URL, values.ANON_KEY, {auth:{persistSession:false}});
    const login = await client.auth.signInWithPassword({email,password});
    assert.ifError(login.error);
    const headers = {authorization:`Bearer ${login.data.session!.access_token}`};
    async function call(method: 'GET'|'POST', url: string, payload?: unknown) {
      const response = await app.inject({method,url,headers,payload});
      assert.ok(response.statusCode < 300, `${method} ${url}: ${response.statusCode} ${response.body}`);
      return response.json();
    }
    const me = await call('GET','/api/v1/me');
    assert.equal(me.organizations.length,1);
    const org = me.organizations[0]; orgId=org.id;
    assert.equal(org.name,'Mi explotación');
    const farm = await call('POST','/api/v1/farms',{organization_id:org.id,name:'Finca local'});
    assert.equal(farm.latitude,null);
    assert.equal(farm.longitude,null);
    const geometry={type:'Polygon',coordinates:[[[-58.295,-31.087],[-58.294,-31.087],[-58.294,-31.086],[-58.295,-31.086],[-58.295,-31.087]]]};
    const parcel = await call('POST','/api/v1/parcels',{organization_id:org.id,farm_id:farm.id,name:'Parcela local',geometry});
    assert.ok(Math.abs(parcel.latitude + 31.0865)<0.0001);
    assert.ok(Math.abs(parcel.longitude + 58.2945)<0.0001);
    await call('POST','/api/v1/events',{organization_id:org.id,parcel_id:parcel.id,type:'inspection',event_date:'2025-10-04',notes:'Revisión local',dose:20,unit:'mm',cost_usd:10});
    const selected=await call('GET',`/api/v1/events?parcel_id=${parcel.id}&type=inspection`);
    const filtered=await call('GET',`/api/v1/events?parcel_id=${parcel.id}&type=harvest`);
    assert.equal(selected.data.length,1);
    assert.equal(selected.data[0].dose,20);
    assert.equal(filtered.data.length,0);
    const forecast=await call('GET',`/api/v1/parcels/${parcel.id}/weather?past_days=15`);
    assert.equal(forecast.status,'fresh');
    assert.ok(forecast.data.payload.daily.time.length>=22);
    const job=await call('POST',`/api/v1/parcels/${parcel.id}/ndvi/refresh`,{from_date:'2025-10-04',to_date:'2025-10-04'});
    worker=spawn(process.execPath,['dist/worker.js'],{env:{...process.env,NDVI_DISABLE_SCHEDULER:'1'},stdio:'ignore'});
    let status='';
    for(let i=0;i<90;i++){
      const current=await call('GET',`/api/v1/jobs/${job.id}`);
      status=current.status;
      if(status==='completed'||status==='failed') break;
      await new Promise(resolve=>setTimeout(resolve,1000));
    }
    assert.equal(status,'completed',`NDVI job ended as ${status}`);
    const result=await call('GET',`/api/v1/parcels/${parcel.id}/ndvi`);
    assert.ok(result.data.length>0,'no satellite observation returned');
    assert.equal(result.data[0].processing_version,'rgb-ndvi-v2');
    assert.equal(result.data[0].ndvi_histogram?.length,10);
    assert.ok(result.data[0].ndvi_raster_url,'missing NDVI raster');
  } finally {
    if(worker && worker.exitCode===null){worker.kill('SIGTERM'); await new Promise(resolve=>worker!.once('exit',resolve));}
    if (orgId) {
      for (const table of ['attachments','field_events','satellite_observations','processing_jobs','weather_snapshots','seasons','parcels','farms','audit_events','memberships','organizations']) {
        const column=table==='organizations'?'id':'organization_id';
        const {error}=await admin.from(table).delete().eq(column,orgId);
        if (error) throw new Error(`No se pudo limpiar ${table}: ${error.message}`);
      }
    }
    const {error} = await admin.auth.admin.deleteUser(userId);
    if (error) throw error;
    await app.close();
  }
});
