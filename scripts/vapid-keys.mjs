import {webcrypto} from 'node:crypto';
const keys=await webcrypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']),jwk=await webcrypto.subtle.exportKey('jwk',keys.privateKey),pub=await webcrypto.subtle.exportKey('raw',keys.publicKey);
console.log('VAPID_PUBLIC_KEY='+Buffer.from(pub).toString('base64url'));console.log('VAPID_PRIVATE_KEY='+jwk.d);console.log('Keep PRIVATE key in Worker secret only. Never commit it or paste it in frontend config.');
