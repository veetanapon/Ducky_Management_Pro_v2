// Reopen an enrolled browser. Bootstrap tokens are only for the original setup dialog.
export function deviceLink(base,device){
 if(device.status!=='approved'||!['kiosk','employee'].includes(device.kind))return null;
 const url=new URL(base);url.search='';url.hash='attendance/'+device.kind;return url.href;
}
export async function copyLink(url,clipboard,manual){
 try{await clipboard.writeText(url);return true}catch{manual(url);return false}
}
