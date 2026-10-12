// Desktop columns use the actual space below their heading, including nested farm tabs.
export function fitWorkspaceColumns(root=document){requestAnimationFrame(()=>{root.querySelectorAll('.workspace').forEach(el=>{if(!el.querySelector(':scope > .zone'))return;el.style.setProperty('--columns-top',Math.max(0,el.getBoundingClientRect().top)+20+'px')})})}
window.addEventListener('resize',()=>fitWorkspaceColumns());
