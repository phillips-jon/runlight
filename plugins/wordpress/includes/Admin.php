<?php
/**
 * wp-admin: the settings page, the menu link to the dashboard, and a check
 * that the address answers.
 *
 * @package Runlight
 */

namespace Runlight\WordPress;

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

final class Admin {
	private const PAGE = 'runlight';

	public static function boot(): void {
		add_action( 'admin_menu', array( self::class, 'menu' ) );
		add_action( 'admin_init', array( self::class, 'register' ) );
		add_filter( 'plugin_action_links_' . plugin_basename( RUNLIGHT_PLUGIN_FILE ), array( self::class, 'action_links' ) );
	}

	public static function menu(): void {
		add_options_page( __( 'Runlight', 'runlight' ), __( 'Runlight', 'runlight' ), 'manage_options', self::PAGE, array( self::class, 'page' ) );
		$settings = Settings::get();
		if ( '' !== $settings['address'] ) {
			// A top-level item that opens the dashboard, where the numbers are.
			add_menu_page( __( 'Runlight', 'runlight' ), __( 'Runlight', 'runlight' ), 'manage_options', 'runlight-dashboard', '__return_null', self::icon(), 3 );
			global $menu;
			foreach ( (array) $menu as $i => $item ) {
				if ( isset( $item[2] ) && 'runlight-dashboard' === $item[2] ) {
					$menu[ $i ][2] = $settings['address'] . '/'; // phpcs:ignore WordPress.WP.GlobalVariablesOverride.Prohibited
				}
			}
		}
	}

	/** The R mark, as wp-admin's menu wants it: a data URI it can tint. */
	private static function icon(): string {
		$svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><path fill="black" fill-rule="evenodd" d="M9.5 2.5h13a7 7 0 0 1 7 7v13a7 7 0 0 1-7 7h-13a7 7 0 0 1-7-7v-13a7 7 0 0 1 7-7zM11 9v14h2.8v-4.6h2.2l3.9 4.6h3.5l-4.3-5a4.3 4.3 0 0 0-1.9-9zm2.8 2.6h3.4a1.7 1.7 0 0 1 0 3.4h-3.4z"/></svg>';
		return 'data:image/svg+xml;base64,' . base64_encode( $svg ); // phpcs:ignore WordPress.PHP.DiscouragedPHPFunctions.obfuscation_base64_encode
	}

	/**
	 * Settings and Dashboard links on the Plugins screen.
	 *
	 * @param array<int|string,string> $links The links WordPress shows.
	 * @return array<int|string,string>
	 */
	public static function action_links( array $links ): array {
		array_unshift( $links, '<a href="' . esc_url( admin_url( 'options-general.php?page=' . self::PAGE ) ) . '">' . esc_html__( 'Settings', 'runlight' ) . '</a>' );
		return $links;
	}

	public static function register(): void {
		register_setting(
			'runlight',
			Settings::OPTION,
			array(
				'type'              => 'array',
				'sanitize_callback' => array( Settings::class, 'sanitize' ),
			)
		);
	}

	/** Whether the address answers as a Runlight, and what to say about it. */
	private static function check( string $address ): array {
		$response = wp_remote_get( $address . '/api', array( 'timeout' => 5 ) );
		if ( is_wp_error( $response ) ) {
			return array( false, sprintf( /* translators: %s: the error */ __( 'Could not reach it: %s', 'runlight' ), $response->get_error_message() ) );
		}
		$body = json_decode( (string) wp_remote_retrieve_body( $response ), true );
		if ( 200 !== wp_remote_retrieve_response_code( $response ) || ! is_array( $body ) || 'runlight' !== ( $body['name'] ?? '' ) ) {
			return array( false, __( 'Something answered, but not Runlight. Check the address ends where Runlight is mounted, such as /runlight.', 'runlight' ) );
		}
		return array( true, sprintf( /* translators: %s: the version */ __( 'Connected to Runlight %s.', 'runlight' ), (string) ( $body['version'] ?? '' ) ) );
	}

	public static function page(): void {
		if ( ! current_user_can( 'manage_options' ) ) {
			return;
		}
		$settings = Settings::get();
		$status   = '' !== $settings['address'] ? self::check( $settings['address'] ) : null;
		?>
		<div class="wrap">
			<h1><?php esc_html_e( 'Runlight', 'runlight' ); ?></h1>
			<p><?php esc_html_e( 'Runlight counts visitors without cookies and keeps the numbers in your own database. This plugin adds its script to every page and reports AI agents that read your pages. The numbers live in your Runlight, wherever you run it.', 'runlight' ); ?></p>
			<?php if ( $status ) : ?>
				<div class="notice <?php echo $status[0] ? 'notice-success' : 'notice-error'; ?> inline"><p><?php echo esc_html( $status[1] ); ?>
				<?php if ( $status[0] ) : ?>
					<a href="<?php echo esc_url( $settings['address'] . '/' ); ?>" target="_blank" rel="noopener"><?php esc_html_e( 'Open the dashboard', 'runlight' ); ?></a>
				<?php endif; ?>
				</p></div>
			<?php endif; ?>
			<form method="post" action="options.php">
				<?php settings_fields( 'runlight' ); ?>
				<table class="form-table" role="presentation">
					<tr>
						<th scope="row"><label for="runlight-address"><?php esc_html_e( 'Runlight address', 'runlight' ); ?></label></th>
						<td>
							<input id="runlight-address" class="regular-text code" type="url" name="<?php echo esc_attr( Settings::OPTION ); ?>[address]" value="<?php echo esc_attr( $settings['address'] ); ?>" placeholder="https://stats.example.com/runlight">
							<p class="description"><?php esc_html_e( 'Where Runlight is mounted: the address its dashboard opens at. Add this site’s hostname to that Runlight’s sites, or its visits are ignored.', 'runlight' ); ?></p>
						</td>
					</tr>
					<tr>
						<th scope="row"><label for="runlight-site"><?php esc_html_e( 'Site id', 'runlight' ); ?></label></th>
						<td>
							<input id="runlight-site" class="regular-text code" type="text" name="<?php echo esc_attr( Settings::OPTION ); ?>[site]" value="<?php echo esc_attr( $settings['site'] ); ?>">
							<p class="description"><?php esc_html_e( 'Optional. Only needed when that Runlight counts several sites and cannot tell this one by its hostname.', 'runlight' ); ?></p>
						</td>
					</tr>
					<tr>
						<th scope="row"><label for="runlight-key"><?php esc_html_e( 'Observe key', 'runlight' ); ?></label></th>
						<td>
							<input id="runlight-key" class="regular-text code" type="password" autocomplete="off" name="<?php echo esc_attr( Settings::OPTION ); ?>[observe_key]" value="" placeholder="<?php echo '' !== $settings['observe_key'] ? esc_attr__( 'Saved. Leave blank to keep it for this address.', 'runlight' ) : ''; ?>">
							<p class="description"><?php esc_html_e( 'Optional. With your Runlight’s RUNLIGHT_OBSERVE_KEY, the plugin reports AI agents such as ChatGPT and Claude reading your pages. They run no JavaScript, so the script cannot see them. The key can report fetches and nothing else.', 'runlight' ); ?></p>
						</td>
					</tr>
					<tr>
						<th scope="row"><?php esc_html_e( 'Counting', 'runlight' ); ?></th>
						<td>
							<fieldset>
								<label><input type="checkbox" name="<?php echo esc_attr( Settings::OPTION ); ?>[skip_admins]" value="1" <?php checked( $settings['skip_admins'] ); ?>> <?php esc_html_e( 'Leave out administrators’ visits', 'runlight' ); ?></label><br>
								<label><input type="checkbox" name="<?php echo esc_attr( Settings::OPTION ); ?>[outbound]" value="1" <?php checked( $settings['outbound'] ); ?>> <?php esc_html_e( 'Count clicks on links to other sites', 'runlight' ); ?></label><br>
								<label><input type="checkbox" name="<?php echo esc_attr( Settings::OPTION ); ?>[downloads]" value="1" <?php checked( $settings['downloads'] ); ?>> <?php esc_html_e( 'Count file downloads', 'runlight' ); ?></label>
							</fieldset>
						</td>
					</tr>
				</table>
				<?php submit_button(); ?>
			</form>
			<p><?php printf( /* translators: %s: link to the docs */ esc_html__( 'New to Runlight? %s', 'runlight' ), '<a href="https://runlight.sh/docs/wordpress/" target="_blank" rel="noopener">' . esc_html__( 'Set it up in a few minutes.', 'runlight' ) . '</a>' ); ?></p>
		</div>
		<?php
	}
}
