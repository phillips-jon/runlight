<?php

declare(strict_types=1);

namespace Runlight\Tests;

use PHPUnit\Framework\TestCase;
use Runlight\Accounts\Crypto;
use Runlight\Accounts\Scrypt;

/** Accounts' cryptography against tests/fixtures/crypto.json, written by the TypeScript SDK and Node's own crypto. */
final class CryptoTest extends TestCase
{
    private static function fixture(): array
    {
        return Fixtures::load('crypto', true);
    }

    public function testScryptGivesNodesBytes(): void
    {
        foreach (self::fixture()['scrypt'] as $case) {
            $key = Scrypt::derive($case['password'], Crypto::fromBase64url($case['salt']), $case['N'], $case['r'], $case['p'], $case['length']);
            $this->assertSame($case['key'], bin2hex($key), json_encode([$case['password'], $case['N'], $case['r'], $case['p'], $case['length']]));
        }
    }

    public function testScryptTestVectorsFromRfc7914(): void
    {
        $this->assertSame(
            '77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906',
            bin2hex(Scrypt::derive('', '', 16, 1, 1, 64)),
        );
        $this->assertSame(
            'fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b3731622eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640',
            bin2hex(Scrypt::derive('password', 'NaCl', 1024, 8, 16, 64)),
        );
    }

    public function testScryptRefusesABadCost(): void
    {
        $this->expectException(\InvalidArgumentException::class);
        Scrypt::derive('x', 'y', 1000, 8, 1, 32);
    }

    public function testPasswordsHashedByTypeScriptCheckHere(): void
    {
        foreach (self::fixture()['hashes'] as $i => $case) {
            $this->assertTrue(Crypto::checkPassword($case['password'], $case['hash']), $case['hash']);
            if ($i === 0) {
                $this->assertFalse(Crypto::checkPassword("{$case['password']}!", $case['hash']));
            }
        }
    }

    public function testNewHashesUseScryptAndCheck(): void
    {
        $hash = Crypto::hashPassword('a long password');
        $this->assertMatchesRegularExpression('/^scrypt\$[A-Za-z0-9_-]{22}\$[A-Za-z0-9_-]{43}$/', $hash);
        $this->assertTrue(Crypto::checkPassword('a long password', $hash));
        $this->assertNotSame($hash, Crypto::hashPassword('a long password'), 'a new salt each time');
    }

    public function testCheckPasswordAnswersAsTypeScriptDoes(): void
    {
        foreach (self::fixture()['checks'] as $case) {
            $label = "{$case['password']} against {$case['stored']}";
            if (isset($case['throws'])) {
                try {
                    Crypto::checkPassword($case['password'], $case['stored']);
                    $this->fail("$label should throw");
                } catch (\InvalidArgumentException) {
                    $this->addToAssertionCount(1);
                }
                continue;
            }
            $this->assertSame($case['value'], Crypto::checkPassword($case['password'], $case['stored']), $label);
        }
    }

    public function testSealedTextOpensBothWays(): void
    {
        foreach (self::fixture()['sealedByTs'] as $case) {
            $this->assertSame($case['text'], Crypto::unsealText($case['sealed'], $case['secret']));
            $this->assertSame($case['text'], Crypto::unsealText(Crypto::sealText($case['text'], $case['secret']), $case['secret']));
        }
        foreach (self::fixture()['sealedWithIv'] as $case) {
            $this->assertSame($case['sealed'], Crypto::sealText($case['text'], $case['secret'], Crypto::fromBase64url($case['iv'])));
        }
    }

    public function testUnsealAnswersAsTypeScriptDoes(): void
    {
        foreach (self::fixture()['unseal'] as $case) {
            $this->assertSame($case['result'], Crypto::unsealText($case['sealed'], $case['secret']), $case['sealed']);
        }
    }

    public function testBase64AndBase32(): void
    {
        foreach (self::fixture()['base64'] as $case) {
            if (isset($case['throws'])) {
                try {
                    Crypto::fromBase64url($case['text']);
                    $this->fail("{$case['text']} should throw");
                } catch (\InvalidArgumentException) {
                    $this->addToAssertionCount(1);
                }
                continue;
            }
            $this->assertSame($case['value'], bin2hex(Crypto::fromBase64url($case['text'])), $case['text']);
        }
        foreach (self::fixture()['encode'] as $case) {
            $bytes = (string) hex2bin($case['hex']);
            $this->assertSame($case['base64url'], Crypto::base64url($bytes));
            $this->assertSame($case['base32'], Crypto::base32($bytes));
            $this->assertSame($case['hex'], bin2hex(Crypto::fromBase64url($case['base64url'])));
            $this->assertSame($case['hex'], bin2hex(Crypto::unbase32($case['base32'])));
        }
    }

    public function testTotpCodes(): void
    {
        foreach (self::fixture()['totp'] as $case) {
            $label = "{$case['secret']} at {$case['step']}";
            if (isset($case['throws'])) {
                try {
                    Crypto::totp($case['secret'], (int) $case['step']);
                    $this->fail("$label should throw");
                } catch (\InvalidArgumentException) {
                    $this->addToAssertionCount(1);
                }
                continue;
            }
            $this->assertSame($case['value'], Crypto::totp($case['secret'], (int) $case['step']), $label);
        }
    }

    public function testRfc6238Vector(): void
    {
        // RFC 6238's SHA-1 secret "12345678901234567890" at 59 seconds: 94287082, of which authenticator apps show the last six.
        $this->assertSame('287082', Crypto::totp(Crypto::base32('12345678901234567890'), 1));
        $this->assertSame('005924', Crypto::totp(Crypto::base32('12345678901234567890'), intdiv(1234567890, 30)));
    }

    public function testMatchStepAllowsOneStepEitherSideAndNeverAnOldOne(): void
    {
        $secret = 'JBSWY3DPEHPK3PXP';
        $now = 1_759_900_000_000;
        $step = intdiv($now, Crypto::STEP_MS);
        $this->assertSame($step, Crypto::matchStep($secret, Crypto::totp($secret, $step), $now, 0));
        $this->assertSame($step - 1, Crypto::matchStep($secret, Crypto::totp($secret, $step - 1), $now, 0));
        $this->assertSame($step + 1, Crypto::matchStep($secret, Crypto::totp($secret, $step + 1), $now, 0));
        $this->assertNull(Crypto::matchStep($secret, Crypto::totp($secret, $step + 2), $now, 0));
        $this->assertNull(Crypto::matchStep($secret, Crypto::totp($secret, $step), $now, $step), 'a code used once is not taken again');
    }

    public function testOtpauthSignaturesRecoveryAndSameText(): void
    {
        foreach (self::fixture()['uris'] as $case) {
            $this->assertSame($case['uri'], Crypto::otpauthUri($case['secret'], $case['email'], $case['host']));
        }
        foreach (self::fixture()['signatures'] as $case) {
            $this->assertSame($case['signature'], Crypto::signature($case['secret'], $case['body'], $case['hash']));
        }
        foreach (self::fixture()['recovery'] as $case) {
            $this->assertSame($case['hash'], Crypto::recoveryHash($case['code']), $case['code']);
        }
        foreach (self::fixture()['same'] as $case) {
            $this->assertSame($case['same'], Crypto::sameText($case['a'], $case['b']));
        }
        $codes = Crypto::recoveryCodes();
        $this->assertCount(10, $codes);
        foreach ($codes as $code) {
            $this->assertMatchesRegularExpression('/^[a-z2-7]{4}-[a-z2-7]{4}$/', $code);
        }
    }
}
