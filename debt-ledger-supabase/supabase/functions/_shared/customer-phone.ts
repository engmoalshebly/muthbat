// Customer contact contract. Keep aligned with core/validation/customer_phone.dart.
export function normalizeCustomerPhone(input: string): string {
  let value = input.trim().replace(/[٠-٩۰-۹]/g, (digit) => {
    const code = digit.charCodeAt(0);
    return String(code - (code >= 0x6f0 ? 0x6f0 : 0x660));
  }).replace(/[\s().\-]/g, "");
  if (value.startsWith("00")) value = `+${value.slice(2)}`;
  if (!value.startsWith("+")) {
    if (value.startsWith("0")) value = value.slice(1);
    value = value.startsWith("967") || value.length > 9 ? `+${value}` : `+967${value}`;
  }
  if (!/^\+[1-9][0-9]{7,14}$/.test(value)) throw new Error("invalid_phone");
  return value;
}
