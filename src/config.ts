import 'dotenv/config';
export const config = { port:Number(process.env.PORT||3001), supabaseUrl:process.env.SUPABASE_URL||'', anonKey:process.env.SUPABASE_ANON_KEY||'', serviceKey:process.env.SUPABASE_SERVICE_ROLE_KEY||'', origins:(process.env.CORS_ORIGINS||'http://localhost:5173').split(','), cdseId:process.env.CDSE_CLIENT_ID||'',cdseSecret:process.env.CDSE_CLIENT_SECRET||'',weatherKey:process.env.OPEN_METEO_API_KEY||'', validThreshold:Number(process.env.NDVI_VALID_THRESHOLD||0.7) };
export const satelliteConfigured=()=>Boolean(config.cdseId&&config.cdseSecret&&config.serviceKey);
