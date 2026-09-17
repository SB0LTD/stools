<?php
/**
 * Minimal router for PHP's built-in server so WordPress pretty permalinks work.
 * Serves real files directly; routes everything else to WordPress index.php.
 */
$uri  = urldecode( parse_url( $_SERVER['REQUEST_URI'], PHP_URL_PATH ) );
$root = __DIR__ . '/wp';
$file = $root . $uri;

// Serve an existing static file as-is.
if ( $uri !== '/' && file_exists( $file ) && ! is_dir( $file ) ) {
	return false; // let the built-in server handle it
}

// Directory index (e.g. /wp-admin/).
if ( is_dir( $file ) && file_exists( rtrim( $file, '/' ) . '/index.php' ) ) {
	$_SERVER['SCRIPT_NAME'] = rtrim( $uri, '/' ) . '/index.php';
	require rtrim( $file, '/' ) . '/index.php';
	return true;
}

// Everything else -> front controller.
$_SERVER['SCRIPT_NAME'] = '/index.php';
require $root . '/index.php';
