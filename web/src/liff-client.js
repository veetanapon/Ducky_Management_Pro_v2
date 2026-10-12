// Tokens for Messaging API stay in GAS; this SDK only supplies an optional display name.
let initialized='';
export async function initWorkerLiff(id){if(!id)return null;if(!window.liff){await new Promise((resolve,reject)=>{const s=document.createElement('script');s.src='https://static.line-scdn.net/liff/edge/versions/2.27.2/sdk.js';s.onload=resolve;s.onerror=()=>reject(Error('โหลด LINE SDK ไม่สำเร็จ'));document.head.append(s)})}if(initialized!==id){await window.liff.init({liffId:id});initialized=id}if(window.liff.isLoggedIn())return window.liff.getProfile();return null}
export function closeWorkerLiff(){if(window.liff?.isInClient?.())window.liff.closeWindow()}
