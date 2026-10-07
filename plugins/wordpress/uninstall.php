<?php
/**
 * Removes the plugin's one option. Nothing else is stored in WordPress: the
 * numbers live in your Runlight.
 *
 * @package Runlight
 */

if ( ! defined( 'WP_UNINSTALL_PLUGIN' ) ) {
	exit;
}

delete_option( 'runlight_settings' );
