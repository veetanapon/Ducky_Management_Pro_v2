const key='ducky-display-v1';
export const displayDefaults={nav:'auto',autoSide:'right',ratio:58,version:2};
export function normalizeDisplay(p){return {version:2,nav:p?.version===2&&['auto','bottom','left','right'].includes(p.nav)?p.nav:'auto',autoSide:p?.autoSide==='left'||p?.version!==2&&p?.nav==='left'?'left':'right',ratio:Number.isFinite(p?.ratio)?Math.min(70,Math.max(30,p.ratio)):58}}
export function readDisplay(){try{return normalizeDisplay(JSON.parse(localStorage.getItem(key)))}catch{return {...displayDefaults}}}
export function applyDisplay(p=readDisplay()){const side=p.nav==='auto'?matchMedia('(orientation:landscape)').matches:p.nav!=='bottom';document.documentElement.dataset.navLayout=side?'side':'bottom';document.documentElement.dataset.navSide=['left','right'].includes(p.nav)?p.nav:p.autoSide;document.documentElement.style.setProperty('--left-share',p.ratio+'fr');document.documentElement.style.setProperty('--right-share',(100-p.ratio)+'fr');return p}
export function saveDisplay(p){const value=normalizeDisplay({...readDisplay(),...p,version:2,ratio:Number(p.ratio??readDisplay().ratio)});localStorage.setItem(key,JSON.stringify(value));return applyDisplay(value)}
export function resetDisplay(){localStorage.removeItem(key);return applyDisplay({...displayDefaults})}
if(typeof matchMedia==='function')matchMedia('(orientation:landscape)').addEventListener('change',()=>applyDisplay());
