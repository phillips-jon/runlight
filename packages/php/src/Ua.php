<?php

declare(strict_types=1);

namespace Runlight;

use Runlight\Data\Agents;

/**
 * Browser, OS, and device from a user agent, plus the AI agent and bot tests.
 *
 * A client is an array{browser: string, browserVersion: string, os: string, osVersion: string,
 * device: 'desktop'|'mobile'|'tablet'}. Client hints are the low entropy ones Chromium browsers send on
 * every request: array{brands?: ?string, mobile?: ?string, platform?: ?string}.
 *
 * The patterns keep JavaScript's meaning: `.` stops at any line terminator and \S at any JavaScript white
 * space (both spelled out under /u), and case-insensitive ones run on bytes so folding stays ASCII.
 */
final class Ua
{
    /** Any character JavaScript's `.` matches. */
    private const DOT = '[^\n\r\x{2028}\x{2029}]';

    private const BROWSERS = [
        ['Edge', '/(?:Edg|EdgA|EdgiOS|Edge)\/(\d+)/'],
        ['Opera', '/(?:OPR|OPiOS|Opera)\/(\d+)/'],
        ['Samsung Internet', '/SamsungBrowser\/(\d+)/'],
        ['Yandex Browser', '/YaBrowser\/(\d+)/'],
        ['Vivaldi', '/Vivaldi\/(\d+)/'],
        ['UC Browser', '/UCBrowser\/(\d+)/'],
        ['DuckDuckGo', '/(?:Ddg|DuckDuckGo)\/(\d+)/'],
        ['Facebook', '/FB(?:AV|_IAB)\/(\d+)/'],
        ['Instagram', '/Instagram (\d+)/'],
        ['Firefox', '/(?:Firefox|FxiOS)\/(\d+)/'],
        ['Chrome', '/(?:CriOS|Chrome)\/(\d+)/'],
        ['Safari', '/Version\/(\d+)[\d.]* (?:Mobile\/[^' . Js::SPACE . ']+ )?Safari\//u'],
        ['Internet Explorer', '/(?:MSIE |Trident\/' . self::DOT . '*rv:)(\d+)/u'],
    ];

    private const WINDOWS = [
        '10.0' => '10',
        '6.3' => '8.1',
        '6.2' => '8',
        '6.1' => '7',
        '6.0' => 'Vista',
        '5.1' => 'XP',
    ];

    /** @return array{name: string, company: string, kind: string, token: string}|null */
    public static function aiAgent(string $ua): ?array
    {
        $lower = Js::lower($ua);
        foreach (Agents::AI_AGENTS as $agent) {
            if (str_contains($lower, $agent['token'])) {
                return $agent;
            }
        }
        return null;
    }

    public static function isBot(string $ua): bool
    {
        if (Js::length($ua) < 20 || !preg_match('/mozilla|opera/i', $ua)) {
            return true;
        }
        return (bool) preg_match(Agents::BOT_PATTERN, $ua);
    }

    private static function unquote(?string $value): string
    {
        return Js::trim(str_replace('"', '', $value ?? ''));
    }

    /**
     * @param array{brands?: ?string, mobile?: ?string, platform?: ?string} $hints
     * @return array{browser: string, browserVersion: string, os: string, osVersion: string, device: string}
     */
    public static function parseClient(string $ua, array $hints = [], int|float|null $screenWidth = null): array
    {
        $ua = Js::scrub($ua);
        $browser = 'Other';
        $browserVersion = '';
        foreach (self::BROWSERS as [$name, $pattern]) {
            if (preg_match($pattern, $ua, $match)) {
                $browser = $name;
                $browserVersion = $match[1] ?? '';
                break;
            }
        }
        if ($browser === 'Chrome' && str_contains($ua, '; wv)')) {
            $browser = 'Android WebView';
        }
        // Brave looks like Chrome in the user agent but names itself in the hints.
        if ($browser === 'Chrome' && str_contains($hints['brands'] ?? '', '"Brave"')) {
            $browser = 'Brave';
        }

        $os = 'Other';
        $osVersion = '';
        if (preg_match('/Windows NT (\d+\.\d+)/', $ua, $match)) {
            $os = 'Windows';
            $osVersion = self::WINDOWS[$match[1]] ?? '';
        } elseif (preg_match('/(?:iPhone|iPad|iPod)' . self::DOT . '*? OS (\d+)/u', $ua, $match)) {
            $os = 'iOS';
            $osVersion = $match[1];
        } elseif (preg_match('/Android (\d+)/', $ua, $match)) {
            $os = 'Android';
            $osVersion = $match[1];
        } elseif (str_contains($ua, 'Android')) {
            $os = 'Android';
        } elseif (str_contains($ua, 'CrOS')) {
            $os = 'Chrome OS';
        } elseif (preg_match('/Mac OS X|Macintosh/', $ua)) {
            // macOS froze its version in the user agent at 10.15, so it says nothing.
            $os = 'macOS';
        } elseif (preg_match('/Linux|X11/', $ua)) {
            $os = 'Linux';
        }
        $platform = self::unquote($hints['platform'] ?? null);
        if ($os === 'Other' && $platform !== '') {
            $os = $platform === 'macOS' ? 'macOS' : $platform;
        }

        $device = 'desktop';
        if (preg_match('/iPad|Tablet|PlayBook|Silk/', $ua) || ($os === 'Android' && !str_contains($ua, 'Mobile'))) {
            $device = 'tablet';
        } elseif (preg_match('/Mobi|iPhone|iPod|Opera Mini|IEMobile/', $ua) || self::unquote($hints['mobile'] ?? null) === '?1') {
            $device = 'mobile';
        } elseif ($os === 'macOS' && $screenWidth !== null && in_array($screenWidth, [768, 810, 820, 834, 1024])) {
            // iPadOS asks for desktop sites with a Mac user agent; the screen gives it away.
            $device = 'tablet';
            $os = 'iOS';
        }

        return ['browser' => $browser, 'browserVersion' => $browserVersion, 'os' => $os, 'osVersion' => $osVersion, 'device' => $device];
    }
}
