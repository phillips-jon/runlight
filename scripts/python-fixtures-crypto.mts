// Seals bytes with Web Crypto's AES-GCM, as Node runs it, and writes the results to
// packages/python/tests/fixtures/aesgcm.json, so the Python port's plain AES-GCM can be held to the same bytes.
// The inputs come from SHA-256 of a counter, so a rerun writes the same file.
// Run with: node --import tsx scripts/python-fixtures-crypto.mts
import { createHash } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";

const hex = (bytes: Uint8Array) => Buffer.from(bytes).toString("hex");
let counter = 0;
function bytes(length: number): Uint8Array<ArrayBuffer> {
  const out = new Uint8Array(length);
  let at = 0;
  while (at < length) {
    const block = createHash("sha256").update(String(counter++)).digest();
    out.set(block.subarray(0, Math.min(32, length - at)), at);
    at += 32;
  }
  return out;
}

async function seal(key: Uint8Array<ArrayBuffer>, iv: Uint8Array<ArrayBuffer>, plain: Uint8Array<ArrayBuffer>, aad?: Uint8Array<ArrayBuffer>) {
  const k = await crypto.subtle.importKey("raw", key, "AES-GCM", false, ["encrypt"]);
  const sealed = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv, ...(aad ? { additionalData: aad } : {}) }, k, plain));
  return { key: hex(key), iv: hex(iv), plain: hex(plain), ...(aad ? { aad: hex(aad) } : {}), sealed: hex(sealed) };
}

const cases = [];
// The GCM specification's AES-256 test cases 13 to 16.
const zero = new Uint8Array(32);
const feff = Buffer.from("feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308", "hex");
const cafe = Buffer.from("cafebabefacedbaddecaf888", "hex");
const p16 = Buffer.from("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39", "hex");
const aad16 = Buffer.from("feedfacedeadbeeffeedfacedeadbeefabaddad2", "hex");
cases.push(await seal(zero, new Uint8Array(12), new Uint8Array(0)));
cases.push(await seal(zero, new Uint8Array(12), new Uint8Array(16)));
cases.push(await seal(new Uint8Array(feff), new Uint8Array(cafe), new Uint8Array(Buffer.concat([p16, Buffer.from("1aafd255", "hex")]))));
cases.push(await seal(new Uint8Array(feff), new Uint8Array(cafe), new Uint8Array(p16), new Uint8Array(aad16)));
// Every length of plaintext up to three blocks and a bit, with 16 and 32 byte keys, and IVs of other lengths.
for (let length = 0; length <= 50; length++) cases.push(await seal(bytes(32), bytes(12), bytes(length)));
for (const ivLength of [13, 16, 32, 60, 64]) cases.push(await seal(bytes(32), bytes(ivLength), bytes(40)));
// Web Crypto in Node refuses an IV under 12 bytes, so the port does too.
const refused = [];
for (const ivLength of [1, 8, 11]) {
  const key = await crypto.subtle.importKey("raw", bytes(32), "AES-GCM", false, ["encrypt"]);
  const iv = bytes(ivLength);
  const ok = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, new Uint8Array(4)).then(() => true, () => false);
  refused.push({ iv: hex(iv), ok });
}
for (const length of [0, 1, 17, 1000]) cases.push(await seal(bytes(16), bytes(12), bytes(length), bytes(length % 23)));

mkdirSync("packages/python/tests/fixtures", { recursive: true });
writeFileSync(
  "packages/python/tests/fixtures/aesgcm.json",
  `${JSON.stringify({ note: "Written by scripts/python-fixtures-crypto.mts from Node's Web Crypto. Do not edit.", cases, refused }, null, 1)}\n`,
);
console.log(`${cases.length} cases`);
