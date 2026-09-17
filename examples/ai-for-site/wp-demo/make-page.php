<?php
/**
 * Create a WordPress page from an img2elementor template JSON and mark it as
 * built with Elementor, so the front end renders the reconstructed widgets.
 *
 * Run via:  wp eval-file make-page.php <path-to-template.json>
 *
 * The tool emits {"version","title","type":"page","content":[...]}. Elementor
 * stores the element tree in the `_elementor_data` post meta (the `content`
 * array), plus a few flags that tell Elementor this page is its own.
 */

$args = $GLOBALS['argv'] ?? array();
// wp eval-file passes extra positional args after the script path.
$json_path = null;
foreach ( $args as $a ) {
	if ( substr( $a, -5 ) === '.json' ) { $json_path = $a; break; }
}
if ( ! $json_path ) {
	$json_path = getenv( 'TEMPLATE_JSON' );
}
if ( ! $json_path || ! file_exists( $json_path ) ) {
	WP_CLI::error( 'template JSON not found; pass its path as an argument' );
}

$raw = file_get_contents( $json_path );
$doc = json_decode( $raw, true );
if ( ! is_array( $doc ) || empty( $doc['content'] ) ) {
	WP_CLI::error( 'template JSON has no content array' );
}

$title   = isset( $doc['title'] ) ? $doc['title'] : 'Reconstructed page';
$content = $doc['content'];

// ── Side-load images into the media library ──────────────────────────────
// Elementor's image widget renders from an attachment (id + local url), not an
// arbitrary remote URL. Walk the tree, download each referenced image once, and
// rewrite the widget to point at the freshly created attachment. Without this
// the reconstructed page shows empty image boxes.
require_once ABSPATH . 'wp-admin/includes/media.php';
require_once ABSPATH . 'wp-admin/includes/file.php';
require_once ABSPATH . 'wp-admin/includes/image.php';

$GLOBALS['u2e_img_cache'] = array(); // url => array(id,url)
$GLOBALS['u2e_img_ok']    = 0;
$GLOBALS['u2e_img_fail']  = 0;

function u2e_sideload( $url ) {
	if ( ! $url || strpos( $url, 'http' ) !== 0 ) {
		return null;
	}
	if ( isset( $GLOBALS['u2e_img_cache'][ $url ] ) ) {
		return $GLOBALS['u2e_img_cache'][ $url ];
	}
	// Strip a query string for the filename but download the full URL.
	$tmp = download_url( $url, 30 );
	if ( is_wp_error( $tmp ) ) {
		$GLOBALS['u2e_img_fail']++;
		$GLOBALS['u2e_img_cache'][ $url ] = null;
		return null;
	}
	$name = wp_basename( parse_url( $url, PHP_URL_PATH ) );
	if ( ! $name || strpos( $name, '.' ) === false ) {
		// Give it an extension from the mime so WP accepts it.
		$name = 'image-' . substr( md5( $url ), 0, 8 ) . '.png';
	}
	$file_array = array( 'name' => $name, 'tmp_name' => $tmp );
	$id = media_handle_sideload( $file_array, 0 );
	if ( is_wp_error( $id ) ) {
		@unlink( $tmp );
		$GLOBALS['u2e_img_fail']++;
		$GLOBALS['u2e_img_cache'][ $url ] = null;
		return null;
	}
	$local = wp_get_attachment_url( $id );
	$res = array( 'id' => $id, 'url' => $local );
	$GLOBALS['u2e_img_cache'][ $url ] = $res;
	$GLOBALS['u2e_img_ok']++;
	return $res;
}

/**
 * Recursively rewrite every image widget's settings.image to a local
 * attachment. Also handles container background images if present.
 */
function u2e_localize_images( &$elements ) {
	if ( ! is_array( $elements ) ) {
		return;
	}
	foreach ( $elements as &$el ) {
		if ( isset( $el['widgetType'] ) && $el['widgetType'] === 'image'
			&& isset( $el['settings']['image']['url'] ) ) {
			$att = u2e_sideload( $el['settings']['image']['url'] );
			if ( $att ) {
				$el['settings']['image']['url'] = $att['url'];
				$el['settings']['image']['id']  = $att['id'];
			}
		}
		if ( isset( $el['settings']['background_image']['url'] ) ) {
			$att = u2e_sideload( $el['settings']['background_image']['url'] );
			if ( $att ) {
				$el['settings']['background_image']['url'] = $att['url'];
				$el['settings']['background_image']['id']  = $att['id'];
			}
		}
		if ( ! empty( $el['elements'] ) ) {
			u2e_localize_images( $el['elements'] );
		}
	}
	unset( $el );
}

u2e_localize_images( $content );
WP_CLI::log( 'images: ' . $GLOBALS['u2e_img_ok'] . ' side-loaded, ' . $GLOBALS['u2e_img_fail'] . ' failed' );

// Elementor expects the data as a JSON string in _elementor_data.
$elementor_data = wp_slash( wp_json_encode( $content ) );

// Reuse an existing demo page if present (idempotent re-runs).
$existing = get_page_by_path( 'ai-for-site-demo' );
$postarr  = array(
	'post_title'   => $title,
	'post_name'    => 'ai-for-site-demo',
	'post_status'  => 'publish',
	'post_type'    => 'page',
	'post_content' => '', // Elementor renders from meta, not post_content.
);
if ( $existing ) {
	$postarr['ID'] = $existing->ID;
	$post_id = wp_update_post( $postarr, true );
} else {
	$post_id = wp_insert_post( $postarr, true );
}
if ( is_wp_error( $post_id ) ) {
	WP_CLI::error( 'failed to create page: ' . $post_id->get_error_message() );
}

// Mark the page as Elementor-built and store its element tree.
update_post_meta( $post_id, '_elementor_edit_mode', 'builder' );
update_post_meta( $post_id, '_elementor_template_type', 'wp-page' );
update_post_meta( $post_id, '_wp_page_template', 'elementor_canvas' );
if ( defined( 'ELEMENTOR_VERSION' ) ) {
	update_post_meta( $post_id, '_elementor_version', ELEMENTOR_VERSION );
}
update_post_meta( $post_id, '_elementor_data', $elementor_data );

// Ask Elementor to (re)generate the page CSS so the front end is styled.
if ( class_exists( '\Elementor\Plugin' ) ) {
	try {
		\Elementor\Plugin::$instance->files_manager->clear_cache();
	} catch ( \Throwable $e ) {
		// non-fatal: CSS regenerates on first view
	}
}

$url = get_permalink( $post_id );
WP_CLI::success( 'page ' . $post_id . ' created: ' . $url );
