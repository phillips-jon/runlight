<?php
/**
 * The plugin's one option, and what it means.
 *
 * @package Runlight
 */

namespace Runlight\WordPress;

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

final class Settings {
	public const OPTION = 'runlight_settings';

	/** @return array{address:string,site:string,observe_key:string,dashboard_key:string,skip_admins:bool,outbound:bool,downloads:bool} */
	public static function get(): array {
		$saved = get_option( self::OPTION, array() );
		$saved = is_array( $saved ) ? $saved : array();
		return array(
			'address'     => isset( $saved['address'] ) ? (string) $saved['address'] : '',
			'site'        => isset( $saved['site'] ) ? (string) $saved['site'] : '',
			'observe_key' => isset( $saved['observe_key'] ) ? (string) $saved['observe_key'] : '',
			'dashboard_key' => isset( $saved['dashboard_key'] ) ? (string) $saved['dashboard_key'] : '',
			'skip_admins' => ! isset( $saved['skip_admins'] ) || (bool) $saved['skip_admins'],
			'outbound'    => ! isset( $saved['outbound'] ) || (bool) $saved['outbound'],
			'downloads'   => ! isset( $saved['downloads'] ) || (bool) $saved['downloads'],
		);
	}

	/**
	 * Where Runlight is mounted, as typed in the settings, tidied: the full
	 * address of its routes, such as https://example.com/runlight in an app
	 * or https://stats.example.com for the standalone server.
	 */
	public static function sanitize_address( string $value ): string {
		$value = trim( $value );
		if ( '' === $value ) {
			return '';
		}
		// The script's own address works too.
		$value = preg_replace( '#/s\.js$#', '', $value );
		$url   = esc_url_raw( untrailingslashit( (string) $value ), array( 'https', 'http' ) );
		return $url ? $url : '';
	}

	/**
	 * Cleans what the settings form sent.
	 *
	 * @param mixed $input The submitted fields.
	 * @return array<string,mixed>
	 */
	public static function sanitize( $input ): array {
		$input  = is_array( $input ) ? $input : array();
		$before = self::get();
		$key       = isset( $input['observe_key'] ) ? trim( sanitize_text_field( wp_unslash( (string) $input['observe_key'] ) ) ) : '';
		$dashboard = isset( $input['dashboard_key'] ) ? trim( sanitize_text_field( wp_unslash( (string) $input['dashboard_key'] ) ) ) : '';
		$address   = self::sanitize_address( isset( $input['address'] ) ? sanitize_text_field( wp_unslash( (string) $input['address'] ) ) : '' );
		$same      = $address === $before['address'];
		return array(
			'address'     => $address,
			'site'        => isset( $input['site'] ) ? preg_replace( '/[^a-z0-9._-]/i', '', (string) $input['site'] ) : '',
			// Left blank, a saved key stays, so it never has to be shown again, but only for the same
			// address: pointed somewhere else, the plugin must never send that Runlight's key there.
			'observe_key' => '' === $key ? ( $same ? $before['observe_key'] : '' ) : $key,
			'dashboard_key' => '' === $dashboard ? ( $same ? $before['dashboard_key'] : '' ) : $dashboard,
			'skip_admins' => ! empty( $input['skip_admins'] ),
			'outbound'    => ! empty( $input['outbound'] ),
			'downloads'   => ! empty( $input['downloads'] ),
		);
	}
}
