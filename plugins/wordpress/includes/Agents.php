<?php
/**
 * The AI agents Runlight records, matched on the user agent. Kept in step
 * with packages/sdk/src/data/agents.ts by a test in the SDK, so a fetch the
 * plugin reports is one the server will record.
 *
 * @package Runlight
 */

namespace Runlight\WordPress;

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

final class Agents {
	/** Case-insensitive substrings of the user agent. */
	public const TOKENS = array(
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
	);

	/** Whether a user agent is one of them. */
	public static function is_agent( string $user_agent ): bool {
		$lower = strtolower( $user_agent );
		foreach ( self::TOKENS as $token ) {
			if ( str_contains( $lower, $token ) ) {
				return true;
			}
		}
		return false;
	}
}
