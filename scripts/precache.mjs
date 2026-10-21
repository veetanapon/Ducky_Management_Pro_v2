import fs from 'node:fs';
const assets=fs.readdirSync('dist/assets').map(x=>'./assets/'+x),files=['./','./index.html','./config.js','./manifest.webmanifest','./icon-192.png','./icon-512.png','./farm-logo.png',...assets];
function walk(dir){return fs.readdirSync(dir,{withFileTypes:true}).flatMap(e=>e.isDirectory()?walk(dir+'/'+e.name):['./'+dir.slice(5)+'/'+e.name]);}if(fs.existsSync('dist/twin'))files.push(...walk('dist/twin'));
const file='dist/sw.js';fs.writeFileSync(file,fs.readFileSync(file,'utf8').replace(/\/\*__PRECACHE__\*\/\[[^;]+/,JSON.stringify(files)));
console.log('Precache:',files.length,'resources');
