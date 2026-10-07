<?php

declare(strict_types=1);

namespace Drupal\runlight;

/**
 * The AI agents Runlight records, matched on the user agent. Kept in step
 * with packages/sdk/src/data/agents.ts by a test in the SDK.
 */
final class Agents {

  /** Case-insensitive substrings of the user agent. */
  public const TOKENS = [
    'chatgpt-user',
    'oai-searchbot',
    'gptbot',
    'claude-user',
    'claude-searchbot',
    'claudebot',
    'claude-web',
    'anthropic-ai',
    'perplexity-user',
    'perplexitybot',
    'mistralai-user',
    'meta-externalfetcher',
    'meta-externalagent',
    'duckassistbot',
    'amazonbot',
    'bytespider',
    'ccbot',
    'cohere-ai',
    'youbot',
    'diffbot',
    'timpibot',
  ];

  /** Whether a user agent is one of them. */
  public static function isAgent(string $userAgent): bool {
    $lower = strtolower($userAgent);
    foreach (self::TOKENS as $token) {
      if (str_contains($lower, $token)) {
        return TRUE;
      }
    }
    return FALSE;
  }

}
