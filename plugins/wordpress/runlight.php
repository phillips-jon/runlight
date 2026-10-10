<?php
/**
 * Plugin Name:       Runlight
 * Plugin URI:        https://runlight.sh/
 * Description:       Counts your site's visitors with Runlight: privacy friendly analytics with no cookies, kept in your own database. Adds the script, reports AI agents that read your pages, and shows your dashboard in wp-admin.
 * Version:           0.0.0
 * Requires at least: 6.3
 * Requires PHP:      8.1
 * Author:            Jon C. Phillips
 * Author URI:        https://joncphillips.com/
 * License:           GPLv2 or later
 * License URI:       https://www.gnu.org/licenses/gpl-2.0.html
 * Text Domain:       runlight
 *
 * @package Runlight
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

define( 'RUNLIGHT_PLUGIN_FILE', __FILE__ );
define( 'RUNLIGHT_PLUGIN_VERSION', '0.0.0' );

require_once __DIR__ . '/includes/Agents.php';
require_once __DIR__ . '/includes/Settings.php';
require_once __DIR__ . '/includes/Tracker.php';
require_once __DIR__ . '/includes/Admin.php';
require_once __DIR__ . '/includes/Dashboard.php';

\Runlight\WordPress\Tracker::boot();
if ( is_admin() ) {
	\Runlight\WordPress\Admin::boot();
}
