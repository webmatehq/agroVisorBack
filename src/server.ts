import {buildApp} from './app.js';
import {config} from './config.js';
const app=await buildApp();await app.listen({port:config.port,host:'0.0.0.0'});
for(const signal of ['SIGINT','SIGTERM'])process.on(signal,async()=>{await app.close();process.exit(0);});
