<?php

declare(strict_types=1);

namespace Runlight\Accounts;

/**
 * scrypt (RFC 7914) in plain PHP, since PHP has none built in and sodium's
 * takes only its own salt length and cost limits. It gives the same bytes as
 * Node's crypto.scrypt, so a password hashed by either implementation checks
 * out in the other.
 *
 * Words are kept as 32-bit values in PHP's 64-bit integers. Inside Salsa20/8
 * the bits above 31 are allowed to hold leftovers, and every sum is cut to 32
 * bits before it is rotated, which saves a mask on each step; the words are
 * cut clean again at the end of each block.
 */
final class Scrypt
{
    /**
     * The derived key for a password and salt.
     *
     * @throws \InvalidArgumentException for a cost that is not a power of two above 1, or r or p below 1
     */
    public static function derive(string $password, string $salt, int $n, int $r, int $p, int $length): string
    {
        if ($n < 2 || ($n & ($n - 1)) !== 0) {
            throw new \InvalidArgumentException('N must be a power of two greater than 1');
        }
        if ($r < 1 || $p < 1 || $length < 1) {
            throw new \InvalidArgumentException('r, p, and the key length must be at least 1');
        }
        $blockBytes = 128 * $r;
        $b = hash_pbkdf2('sha256', $password, $salt, 1, $blockBytes * $p, true);
        $out = '';
        for ($i = 0; $i < $p; $i++) {
            $out .= self::roMix(substr($b, $i * $blockBytes, $blockBytes), $n, $r);
        }
        return hash_pbkdf2('sha256', $password, $out, 1, $length, true);
    }

    /** scryptROMix: fills N blocks, then reads them back in an order that depends on each result. */
    private static function roMix(string $block, int $n, int $r): string
    {
        $x = array_values(unpack('V*', $block));
        $v = [];
        for ($i = 0; $i < $n; $i++) {
            $v[$i] = $block;
            $x = self::blockMix($x, $r);
            $block = pack('V*', ...$x);
        }
        $last = (2 * $r - 1) * 16;
        $mask = $n - 1;
        for ($i = 0; $i < $n; $i++) {
            // Integerify: the first word of the last 64-byte part, which is the low bits of a little-endian number.
            $j = $x[$last] & $mask;
            $x = self::blockMix(array_values(unpack('V*', $block ^ $v[$j])), $r);
            $block = pack('V*', ...$x);
        }
        return $block;
    }

    /**
     * scryptBlockMix with Salsa20/8 written out in place: 2r parts of 16 words, each mixed with the one before,
     * the even results first and the odd ones after.
     *
     * @param list<int> $b
     * @return list<int>
     */
    private static function blockMix(array $b, int $r): array
    {
        $parts = 2 * $r;
        $base = ($parts - 1) * 16;
        $x0 = $b[$base];
        $x1 = $b[$base + 1];
        $x2 = $b[$base + 2];
        $x3 = $b[$base + 3];
        $x4 = $b[$base + 4];
        $x5 = $b[$base + 5];
        $x6 = $b[$base + 6];
        $x7 = $b[$base + 7];
        $x8 = $b[$base + 8];
        $x9 = $b[$base + 9];
        $x10 = $b[$base + 10];
        $x11 = $b[$base + 11];
        $x12 = $b[$base + 12];
        $x13 = $b[$base + 13];
        $x14 = $b[$base + 14];
        $x15 = $b[$base + 15];
        $even = [];
        $odd = [];
        for ($k = 0; $k < $parts; $k++) {
            $o = $k * 16;
            $j0 = $x0 = $x0 ^ $b[$o];
            $j1 = $x1 = $x1 ^ $b[$o + 1];
            $j2 = $x2 = $x2 ^ $b[$o + 2];
            $j3 = $x3 = $x3 ^ $b[$o + 3];
            $j4 = $x4 = $x4 ^ $b[$o + 4];
            $j5 = $x5 = $x5 ^ $b[$o + 5];
            $j6 = $x6 = $x6 ^ $b[$o + 6];
            $j7 = $x7 = $x7 ^ $b[$o + 7];
            $j8 = $x8 = $x8 ^ $b[$o + 8];
            $j9 = $x9 = $x9 ^ $b[$o + 9];
            $j10 = $x10 = $x10 ^ $b[$o + 10];
            $j11 = $x11 = $x11 ^ $b[$o + 11];
            $j12 = $x12 = $x12 ^ $b[$o + 12];
            $j13 = $x13 = $x13 ^ $b[$o + 13];
            $j14 = $x14 = $x14 ^ $b[$o + 14];
            $j15 = $x15 = $x15 ^ $b[$o + 15];
            for ($round = 0; $round < 4; $round++) {
                // Columns.
                $t = ($x0 + $x12) & 0xffffffff; $x4 ^= ($t << 7) | ($t >> 25);
                $t = ($x4 + $x0) & 0xffffffff; $x8 ^= ($t << 9) | ($t >> 23);
                $t = ($x8 + $x4) & 0xffffffff; $x12 ^= ($t << 13) | ($t >> 19);
                $t = ($x12 + $x8) & 0xffffffff; $x0 ^= ($t << 18) | ($t >> 14);
                $t = ($x5 + $x1) & 0xffffffff; $x9 ^= ($t << 7) | ($t >> 25);
                $t = ($x9 + $x5) & 0xffffffff; $x13 ^= ($t << 9) | ($t >> 23);
                $t = ($x13 + $x9) & 0xffffffff; $x1 ^= ($t << 13) | ($t >> 19);
                $t = ($x1 + $x13) & 0xffffffff; $x5 ^= ($t << 18) | ($t >> 14);
                $t = ($x10 + $x6) & 0xffffffff; $x14 ^= ($t << 7) | ($t >> 25);
                $t = ($x14 + $x10) & 0xffffffff; $x2 ^= ($t << 9) | ($t >> 23);
                $t = ($x2 + $x14) & 0xffffffff; $x6 ^= ($t << 13) | ($t >> 19);
                $t = ($x6 + $x2) & 0xffffffff; $x10 ^= ($t << 18) | ($t >> 14);
                $t = ($x15 + $x11) & 0xffffffff; $x3 ^= ($t << 7) | ($t >> 25);
                $t = ($x3 + $x15) & 0xffffffff; $x7 ^= ($t << 9) | ($t >> 23);
                $t = ($x7 + $x3) & 0xffffffff; $x11 ^= ($t << 13) | ($t >> 19);
                $t = ($x11 + $x7) & 0xffffffff; $x15 ^= ($t << 18) | ($t >> 14);
                // Rows.
                $t = ($x0 + $x3) & 0xffffffff; $x1 ^= ($t << 7) | ($t >> 25);
                $t = ($x1 + $x0) & 0xffffffff; $x2 ^= ($t << 9) | ($t >> 23);
                $t = ($x2 + $x1) & 0xffffffff; $x3 ^= ($t << 13) | ($t >> 19);
                $t = ($x3 + $x2) & 0xffffffff; $x0 ^= ($t << 18) | ($t >> 14);
                $t = ($x5 + $x4) & 0xffffffff; $x6 ^= ($t << 7) | ($t >> 25);
                $t = ($x6 + $x5) & 0xffffffff; $x7 ^= ($t << 9) | ($t >> 23);
                $t = ($x7 + $x6) & 0xffffffff; $x4 ^= ($t << 13) | ($t >> 19);
                $t = ($x4 + $x7) & 0xffffffff; $x5 ^= ($t << 18) | ($t >> 14);
                $t = ($x10 + $x9) & 0xffffffff; $x11 ^= ($t << 7) | ($t >> 25);
                $t = ($x11 + $x10) & 0xffffffff; $x8 ^= ($t << 9) | ($t >> 23);
                $t = ($x8 + $x11) & 0xffffffff; $x9 ^= ($t << 13) | ($t >> 19);
                $t = ($x9 + $x8) & 0xffffffff; $x10 ^= ($t << 18) | ($t >> 14);
                $t = ($x15 + $x14) & 0xffffffff; $x12 ^= ($t << 7) | ($t >> 25);
                $t = ($x12 + $x15) & 0xffffffff; $x13 ^= ($t << 9) | ($t >> 23);
                $t = ($x13 + $x12) & 0xffffffff; $x14 ^= ($t << 13) | ($t >> 19);
                $t = ($x14 + $x13) & 0xffffffff; $x15 ^= ($t << 18) | ($t >> 14);
            }
            $x0 = ($x0 + $j0) & 0xffffffff;
            $x1 = ($x1 + $j1) & 0xffffffff;
            $x2 = ($x2 + $j2) & 0xffffffff;
            $x3 = ($x3 + $j3) & 0xffffffff;
            $x4 = ($x4 + $j4) & 0xffffffff;
            $x5 = ($x5 + $j5) & 0xffffffff;
            $x6 = ($x6 + $j6) & 0xffffffff;
            $x7 = ($x7 + $j7) & 0xffffffff;
            $x8 = ($x8 + $j8) & 0xffffffff;
            $x9 = ($x9 + $j9) & 0xffffffff;
            $x10 = ($x10 + $j10) & 0xffffffff;
            $x11 = ($x11 + $j11) & 0xffffffff;
            $x12 = ($x12 + $j12) & 0xffffffff;
            $x13 = ($x13 + $j13) & 0xffffffff;
            $x14 = ($x14 + $j14) & 0xffffffff;
            $x15 = ($x15 + $j15) & 0xffffffff;
            $y = [$x0, $x1, $x2, $x3, $x4, $x5, $x6, $x7, $x8, $x9, $x10, $x11, $x12, $x13, $x14, $x15];
            if ($k & 1) {
                array_push($odd, ...$y);
            } else {
                array_push($even, ...$y);
            }
        }
        return array_merge($even, $odd);
    }
}
