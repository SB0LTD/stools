# Example: reconstructing ai-for-site.surge.sh into Elementor

This folder holds the reconstructed Elementor templates for
[`https://ai-for-site.surge.sh/`](https://ai-for-site.surge.sh/), produced by
`url2elementor`, plus a slim local WordPress + Elementor harness to import and
view them.

## Templates (tracked)

| File | Mode | What it is |
| --- | --- | --- |
| `ai-for-site-clone.json` | `--clone` (default) | Pixel-perfect: the live page captured (CSS + JS + animations) into one full-width Elementor **HTML widget** (an `<iframe srcdoc>`). Renders and behaves like the source. |
| `ai-for-site-dom.json`   | `--widgets` | Editable: the DOM decomposed into Elementor widgets (headings, text, buttons, images). Editable in Elementor, but an approximation — no original CSS/JS. |

Regenerate either with:

```sh
url2elementor https://ai-for-site.surge.sh/ ai-for-site-clone.json            # pixel-perfect
url2elementor https://ai-for-site.surge.sh/ ai-for-site-dom.json --widgets    # editable
```

## Local WordPress + Elementor harness (`wp-demo/`, mostly generated)

A slim, Docker-free way to import and view a template. Uses the machine's PHP
with a local `php.ini`, WordPress on SQLite (no MySQL), WP-CLI, and PHP's
built-in server. Only the small scripts are tracked; the WordPress install
itself (`wp/`), `wp-cli.phar`, screenshots, and browser profiles are generated
and git-ignored.

Tracked scripts:

- `wp-demo/make-page.php` — creates/updates a page from a template JSON, marks
  it Elementor-built, side-loads images into the media library, sets it as the
  front page.
- `wp-demo/php.ini` — enables the extensions WordPress + the SQLite drop-in +
  Elementor need, without touching the global PHP config.
- `wp-demo/router.php` — front-controller router for PHP's built-in server so
  WordPress pretty permalinks resolve.
- `wp-demo/wp.ps1` — thin WP-CLI wrapper (runs the phar with the local ini and
  the `wp/` docroot).

Setup outline (from `wp-demo/`): download WP-CLI, `wp core download`, drop in
the SQLite integration (`wp-content/db.php`), `wp core install`, install +
activate Elementor, then `wp eval-file make-page.php template/<name>.json`, and
serve with `php -c php.ini -S localhost:8091 -t wp router.php`.
