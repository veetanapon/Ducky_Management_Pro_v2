// Quantity is measured in the policy's unit. The separate baht valuation always allows satang.
export const benefitStep=type=>type==='money'?0.01:type==='leave'?0.5:1;
export const quantityHint=type=>type==='money'?'ระบุจำนวนเงินไม่เกิน 2 ตำแหน่งทศนิยม':type==='leave'?'ระบุจำนวนวันลาครั้งละ 0.5 วัน':'ระบุจำนวนเต็มตั้งแต่ 1 ขึ้นไป';
export function validBenefitQuantity(type,value){
 const n=Number(value),scale=1/benefitStep(type),units=Math.round(n*scale);
 return n>0&&Number.isSafeInteger(units)&&units/scale===n;
}
export function setBenefitStep(input,type){
 const step=benefitStep(type);input.min=input.step=String(step);input.inputMode=step===1?'numeric':'decimal';input.title=quantityHint(type);
}
