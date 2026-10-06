const key='ducky-display-v1';
export const displayDefaults={nav:'right',ratio:58};
export function readDisplay(){try{const p=JSON.parse(localStorage.getItem(key));return{nav:p?.nav==='left'?'left':'right',ratio:Number.isFinite(p?.ratio)?Math.min(70,Math.max(30,p.ratio)):58}}catch{return{...displayDefaults}}}
export function applyDisplay(p=readDisplay()){document.documentElement.dataset.navSide=p.nav;document.documentElement.style.setProperty('--left-share',p.ratio+'fr');document.documentElement.style.setProperty('--right-share',(100-p.ratio)+'fr');return p}
export function saveDisplay(p){const value={nav:p.nav==='left'?'left':'right',ratio:Math.min(70,Math.max(30,Number(p.ratio)||58))};localStorage.setItem(key,JSON.stringify(value));return applyDisplay(value)}
export function resetDisplay(){localStorage.removeItem(key);return applyDisplay({...displayDefaults})}
