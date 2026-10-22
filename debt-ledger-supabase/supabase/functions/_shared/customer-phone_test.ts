import { normalizeCustomerPhone } from './customer-phone.ts';
import { decryptPhone, encryptPhone } from './crypto.ts';

const cases = JSON.parse(await Deno.readTextFile(new URL('../../../../test-fixtures/customer-phones.json',import.meta.url)));
for (const value of cases) {
  Deno.test(`customer phone contract: ${value.input}`, () => {
    try {
      const actual = normalizeCustomerPhone(value.input);
      if (actual !== value.expected) throw new Error('Normalization mismatch');
    } catch (error) {
      if (value.expected !== null || !(error instanceof Error) || error.message !== 'invalid_phone') throw error;
    }
  });
}
Deno.test('phone encryption roundtrip, authentication, and key version', async () => {
  Deno.env.set('PHONE_ENCRYPTION_KEY', btoa('a'.repeat(32)));
  Deno.env.set('PHONE_KEY_VERSION','1');
  try {
    const encrypted = await encryptPhone('+967777123456');
    if (await decryptPhone(encrypted,1) !== '+967777123456') throw new Error('Roundtrip failed');
    const legacyBytes = new TextEncoder().encode(encrypted);
    const legacyCiphertext = '\\x' + Array.from(legacyBytes,b=>b.toString(16).padStart(2,'0')).join('');
    if (await decryptPhone(legacyCiphertext,1) !== '+967777123456') throw new Error('Legacy bytea roundtrip failed');
    Deno.env.set('PHONE_ENCRYPTION_KEY_V1', btoa('a'.repeat(32)));
    Deno.env.set('PHONE_KEY_VERSION','2');
    Deno.env.set('PHONE_ENCRYPTION_KEY', btoa('b'.repeat(32)));
    if (await decryptPhone(encrypted,1) !== '+967777123456') throw new Error('Old key not selected');
    let rejected = false;
    try { await decryptPhone(encrypted.slice(0,-2)+'ff',1); } catch { rejected=true; }
    if (!rejected) throw new Error('Tampered ciphertext accepted');
  } finally {
    Deno.env.delete('PHONE_ENCRYPTION_KEY'); Deno.env.delete('PHONE_ENCRYPTION_KEY_V1'); Deno.env.delete('PHONE_KEY_VERSION');
  }
});
