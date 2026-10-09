<?php

declare(strict_types=1);

namespace Runlight;

use Runlight\Http\BodyTooLong;
use Runlight\Http\Response;

/**
 * Capped reads of an answer's body. In PHP the cap belongs on the request:
 * pass `maxBytes` to the Fetcher, which stops reading past it and throws
 * BodyTooLong, so an install or a page that answers without end never fills
 * memory. These check the same limit again on an answer already read, for a
 * Fetcher that does not take the option, and decode the text as TextDecoder
 * does.
 */
final class Body
{
    /** The body as text, up to maxBytes; past that, BodyTooLong. */
    public static function readTextCapped(Response $response, int $maxBytes): string
    {
        $declared = $response->headers->get('content-length');
        if ($declared !== null && is_numeric(trim($declared)) && (float) trim($declared) > $maxBytes) {
            throw new BodyTooLong("Body over $maxBytes bytes");
        }
        $text = $response->text();
        if (strlen($text) > $maxBytes) {
            throw new BodyTooLong("Body over $maxBytes bytes");
        }
        return self::utf8($text);
    }

    /** The body as JSON, up to maxBytes, as readTextCapped reads it. Objects come back as stdClass unless `$assoc`. */
    public static function readJsonCapped(Response $response, int $maxBytes, bool $assoc = false): mixed
    {
        return Json::decode(self::readTextCapped($response, $maxBytes), $assoc);
    }

    /** Text as TextDecoder gives it: U+FFFD where the bytes are not UTF-8, and no byte order mark. */
    public static function utf8(string $bytes): string
    {
        if (str_starts_with($bytes, "\xEF\xBB\xBF")) {
            $bytes = substr($bytes, 3);
        }
        if (mb_check_encoding($bytes, 'UTF-8')) {
            return $bytes;
        }
        $was = mb_substitute_character();
        mb_substitute_character(0xFFFD);
        try {
            return mb_convert_encoding($bytes, 'UTF-8', 'UTF-8');
        } finally {
            mb_substitute_character($was);
        }
    }
}
