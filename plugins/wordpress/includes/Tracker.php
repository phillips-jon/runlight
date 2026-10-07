<?php
/**
 * The front end: the script tag, and AI agents reported to Runlight.
 *
 * @package Runlight
 */

namespace Runlight\WordPress;

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

final class Tracker {
	public static function boot(): void {
		add_action( 'wp_head', array( self::class, 'script' ), 1 );
		add_action( 'template_redirect', array( self::class, 'observe' ) );
	}

	/** The Runlight script, before any other head output, unless this visit should not count. */
	public static function script(): void {
		$settings = Settings::get();
		if ( '' === $settings['address'] ) {
			return;
		}
		if ( $settings['skip_admins'] && current_user_can( 'manage_options' ) ) {
			return;
		}
		$attributes = array(
			'defer' => true,
			'src'   => $settings['address'] . '/s.js',
		);
		if ( '' !== $settings['site'] ) {
			$attributes['data-site'] = $settings['site'];
		}
		if ( ! $settings['outbound'] ) {
			$attributes['data-outbound'] = 'false';
		}
		if ( ! $settings['downloads'] ) {
			$attributes['data-downloads'] = 'false';
		}
		if ( is_404() ) {
			$attributes['data-404'] = true;
		}
		wp_print_script_tag( $attributes );
	}

	/**
	 * Reports a page served to an AI agent. Agents run no JavaScript, so the
	 * script never sees them. The request does not wait for an answer, so
	 * the page is not slowed down, and it only goes out for known agents.
	 */
	public static function observe(): void {
		$settings = Settings::get();
		if ( '' === $settings['address'] || '' === $settings['observe_key'] ) {
			return;
		}
		$method = isset( $_SERVER['REQUEST_METHOD'] ) ? sanitize_text_field( wp_unslash( $_SERVER['REQUEST_METHOD'] ) ) : 'GET';
		$agent  = isset( $_SERVER['HTTP_USER_AGENT'] ) ? sanitize_text_field( wp_unslash( $_SERVER['HTTP_USER_AGENT'] ) ) : '';
		if ( 'GET' !== $method || ! Agents::is_agent( $agent ) || is_admin() || wp_doing_ajax() || wp_doing_cron() ) {
			return;
		}
		$path = isset( $_SERVER['REQUEST_URI'] ) ? esc_url_raw( wp_unslash( $_SERVER['REQUEST_URI'] ) ) : '/';
		wp_remote_post(
			$settings['address'] . '/api/observe',
			array(
				'blocking' => false,
				'timeout'  => 1,
				'headers'  => array(
					'authorization' => 'Bearer ' . $settings['observe_key'],
					'content-type'  => 'application/json',
				),
				'body'     => wp_json_encode(
					array(
						'url'       => home_url( $path ),
						'userAgent' => $agent,
					)
				),
			)
		);
	}
}
