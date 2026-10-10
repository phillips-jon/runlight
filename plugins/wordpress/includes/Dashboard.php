<?php
/**
 * The Runlight page in wp-admin: this site's dashboard, framed from your
 * Runlight with a ticket the plugin asks for on every visit to the page.
 *
 * @package Runlight
 */

namespace Runlight\WordPress;

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

final class Dashboard {
	public const PAGE = 'runlight-dashboard';

	/**
	 * The scheme, host, and port wp-admin is served from, which alone may frame
	 * the dashboard.
	 */
	public static function admin_origin(): string {
		return self::origin_of( admin_url() );
	}

	/** The scheme, host, and port of an address, such as the Runlight's. */
	private static function origin_of( string $address ): string {
		$parts = wp_parse_url( $address );
		if ( ! is_array( $parts ) || empty( $parts['scheme'] ) || empty( $parts['host'] ) ) {
			return '';
		}
		$scheme = strtolower( $parts['scheme'] );
		$port   = isset( $parts['port'] ) ? (int) $parts['port'] : 0;
		// A browser leaves out the port its scheme uses anyway, and so does the origin Runlight checks.
		$default = ( 'https' === $scheme && 443 === $port ) || ( 'http' === $scheme && 80 === $port );
		return $scheme . '://' . strtolower( $parts['host'] ) . ( $port && ! $default ? ':' . $port : '' );
	}

	/**
	 * Asks the Runlight for a ticket that opens the dashboard once, framed by
	 * this admin. Each ticket works for a few minutes and only once, so one is
	 * asked for on every visit to the page and never kept.
	 *
	 * @param array{address:string,dashboard_key:string} $settings The plugin's settings.
	 * @return array{url:string,site:string}|string The page to frame and its site, or why there is none.
	 */
	private static function ticket( array $settings ) {
		$response = wp_remote_post(
			$settings['address'] . '/api/embed',
			array(
				'timeout'     => 5,
				'redirection' => 0,
				'headers'     => array(
					'Authorization' => 'Bearer ' . $settings['dashboard_key'],
					'Content-Type'  => 'application/json',
				),
				'body'        => (string) wp_json_encode( array( 'origin' => self::admin_origin() ) ),
			)
		);
		if ( is_wp_error( $response ) ) {
			/* translators: %s: the error */
			return sprintf( __( 'Could not reach your Runlight: %s', 'runlight' ), $response->get_error_message() );
		}
		$body = json_decode( (string) wp_remote_retrieve_body( $response ), true );
		$code = (int) wp_remote_retrieve_response_code( $response );
		if ( 201 !== $code || ! is_array( $body ) || ! is_string( $body['ticket'] ?? null ) ) {
			if ( 401 === $code ) {
				return __( 'Your Runlight does not know this dashboard key. Make a new one in Runlight’s Settings, Install, and enter it in the settings.', 'runlight' );
			}
			$reason = is_array( $body ) && is_string( $body['error'] ?? null ) ? $body['error'] : sprintf( /* translators: %d: the HTTP status */ __( 'It answered %d.', 'runlight' ), $code );
			/* translators: %s: what the Runlight said */
			return sprintf( __( 'Your Runlight would not open the dashboard here: %s', 'runlight' ), $reason );
		}
		return array(
			'url'  => $settings['address'] . '/embed?ticket=' . rawurlencode( $body['ticket'] ) . '&theme=light',
			'site' => is_string( $body['site'] ?? null ) ? $body['site'] : '',
		);
	}

	public static function page(): void {
		if ( ! current_user_can( 'manage_options' ) ) {
			return;
		}
		$settings = Settings::get();
		$setup    = admin_url( 'options-general.php?page=runlight' );
		$ticket   = '' !== $settings['address'] && '' !== $settings['dashboard_key'] ? self::ticket( $settings ) : null;
		$site     = is_array( $ticket ) && '' !== $ticket['site'] ? $ticket['site'] : $settings['site'];
		$full     = '' !== $settings['address'] ? $settings['address'] . '/' . ( '' !== $site ? '?site=' . rawurlencode( $site ) : '' ) : '';
		?>
		<div class="wrap runlight-dashboard">
			<h1 class="wp-heading-inline"><?php esc_html_e( 'Runlight', 'runlight' ); ?></h1>
			<?php if ( '' !== $full ) : ?>
				<a class="page-title-action" href="<?php echo esc_url( $full ); ?>" target="_blank" rel="noopener"><?php esc_html_e( 'Open in Runlight', 'runlight' ); ?></a>
			<?php endif; ?>
			<hr class="wp-header-end">
			<?php if ( '' === $settings['address'] ) : ?>
				<div class="notice notice-info inline"><p>
					<?php
					printf(
						/* translators: %s: link to the settings page */
						esc_html__( 'Enter your Runlight’s address and a dashboard key on the %s to see this site’s numbers here.', 'runlight' ),
						'<a href="' . esc_url( $setup ) . '">' . esc_html__( 'settings page', 'runlight' ) . '</a>'
					);
					?>
				</p></div>
			<?php elseif ( null === $ticket ) : ?>
				<div class="notice notice-info inline"><p>
					<?php
					printf(
						/* translators: %s: link to the settings page */
						esc_html__( 'To see this site’s numbers here, make a dashboard key in your Runlight under Settings, Install, Key for the dashboard in your CMS, and enter it on the %s.', 'runlight' ),
						'<a href="' . esc_url( $setup ) . '">' . esc_html__( 'settings page', 'runlight' ) . '</a>'
					);
					?>
				</p></div>
			<?php elseif ( is_string( $ticket ) ) : ?>
				<div class="notice notice-error inline"><p>
					<?php echo esc_html( $ticket ); ?>
					<a href="<?php echo esc_url( $setup ); ?>"><?php esc_html_e( 'Check the settings', 'runlight' ); ?></a>
				</p></div>
			<?php else : ?>
				<iframe id="runlight-embed" src="<?php echo esc_url( $ticket['url'] ); ?>" data-runlight-origin="<?php echo esc_attr( self::origin_of( $settings['address'] ) ); ?>" title="<?php esc_attr_e( 'Runlight dashboard', 'runlight' ); ?>" referrerpolicy="no-referrer" sandbox="allow-scripts allow-same-origin allow-popups allow-popups-to-escape-sandbox allow-downloads" style="display:block;width:100%;height:calc(100vh - 140px);min-height:600px;margin-top:12px;border:0;border-radius:8px;background:transparent"></iframe>
			<?php endif; ?>
		</div>
		<?php
	}

	/**
	 * Fits the frame to the window below it, and reloads the page when the
	 * dashboard asks, which it does once its session has run out.
	 */
	public static function scripts( string $hook ): void {
		if ( 'toplevel_page_' . self::PAGE !== $hook ) {
			return;
		}
		wp_register_script( 'runlight-dashboard', false, array(), RUNLIGHT_PLUGIN_VERSION, true );
		wp_enqueue_script( 'runlight-dashboard' );
		wp_add_inline_script( 'runlight-dashboard', self::SCRIPT );
	}

	/** The frame's few lines of script, the same in every CMS plugin. */
	private const SCRIPT = <<<'JS'
(function () {
  var frame = document.getElementById("runlight-embed");
  if (!frame) return;
  var origin = frame.getAttribute("data-runlight-origin");
  function fit() {
    var top = frame.getBoundingClientRect().top + window.scrollY;
    frame.style.height = Math.max(600, window.innerHeight - top - 24) + "px";
  }
  fit();
  window.addEventListener("resize", fit);
  window.addEventListener("message", function (event) {
    if (event.origin === origin && event.source === frame.contentWindow && event.data && event.data.type === "runlight:reload") location.reload();
  });
})();
JS;
}
