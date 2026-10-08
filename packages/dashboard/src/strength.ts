/**
 * A rough password strength, from 0 (too short) to 4 (strong), with no word
 * list to download: the characters it draws on and its length give an
 * estimate, and repeats, runs, and common choices pull it down.
 */
const COMMON = ["password", "passw0rd", "123456", "qwerty", "azerty", "letmein", "welcome", "admin", "runlight", "iloveyou", "abc123", "monkey", "dragon", "football", "baseball", "sunshine", "princess", "shadow", "master"];

export type Strength = 0 | 1 | 2 | 3 | 4;

export function strength(password: string, avoid: string[] = []): Strength {
  if (password.length < 10) return 0;
  let pool = 0;
  if (/[a-z]/.test(password)) pool += 26;
  if (/[A-Z]/.test(password)) pool += 26;
  if (/[0-9]/.test(password)) pool += 10;
  if (/[^A-Za-z0-9]/.test(password)) pool += 33;
  // Each character only counts once it adds something new: a pattern repeating ("abab", "Aa1!Aa1!",
  // "aaaa") adds nothing, and a doubled letter or a run like "abc" adds little.
  let effective = 0;
  for (let i = 0; i < password.length; i++) {
    const c = password.charCodeAt(i);
    const prev = password.charCodeAt(i - 1);
    let pattern = false;
    for (let k = 1; k <= 4 && !pattern; k++) pattern = i - 1 - k >= 0 && password[i] === password[i - k] && password[i - 1] === password[i - 1 - k];
    const repeat = i > 0 && c === prev;
    const run = i > 1 && c - prev === prev - password.charCodeAt(i - 2) && Math.abs(c - prev) === 1;
    effective += pattern ? 0 : repeat || run ? 0.25 : 1;
  }
  let bits = effective * Math.log2(Math.max(pool, 10));
  const lower = password.toLowerCase();
  for (const word of [...COMMON, ...avoid.map((a) => a.toLowerCase()).filter((a) => a.length >= 3)]) {
    // Every time it appears, so "jonjonjon" costs three times.
    bits -= (lower.split(word).length - 1) * word.length * 3;
  }
  if (bits < 40) return 1;
  if (bits < 60) return 2;
  if (bits < 80) return 3;
  return 4;
}
