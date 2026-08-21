#!/usr/bin/env bash
# Release-tag resolution and source download for install_leechblock.sh.
# Sourced by the installer; inherits its strict mode and its info/warn/err
# helpers. Reads REPO_OWNER/REPO_NAME/FORCE, writes VERSION/TAG and the
# INSTALL_ROOT layout globals the later phases consume.

get_latest_tag() {
	local repo="$1"
	local tag
	if command -v jq >/dev/null 2>&1; then
		tag=$(curl -fsSL "https://api.github.com/repos/${REPO_OWNER}/${repo}/releases/latest" | jq -r '.tag_name // empty' || true)
		if [[ -n $tag && $tag != "null" ]]; then
			echo "$tag"
			return 0
		fi
		# Fallback: try tags endpoint
		tag=$(curl -fsSL "https://api.github.com/repos/${REPO_OWNER}/${repo}/tags?per_page=1" | jq -r '.[0].name // empty' || true)
		if [[ -n $tag && $tag != "null" ]]; then
			echo "$tag"
			return 0
		fi
	fi
	# Fallback: follow redirect for /releases/latest to extract tag
	tag=$(curl -fsSLI "https://github.com/${REPO_OWNER}/${repo}/releases/latest" | awk -F'/tag/' '/^location:/I {print $2}' | tr -d '\r\n' || true)
	if [[ -n $tag ]]; then
		echo "$tag"
		return 0
	fi
	return 1
}

resolve_version() {
	if [[ -z $VERSION ]]; then
		info "Resolving latest release tag from GitHub…"
		if ! VERSION=$(get_latest_tag "$REPO_NAME"); then
			err "Failed to determine latest version tag"
			exit 1
		fi
	fi

	if [[ ! $VERSION =~ ^v?[0-9]+(\.[0-9]+)*$ ]]; then
		warn "Version tag '$VERSION' doesn't look like vX[.Y[.Z]] — continuing anyway."
	fi

	VERSION=${VERSION#v} # strip leading v for folder names
	TAG="v${VERSION}"

	XDG_DATA_HOME=${XDG_DATA_HOME:-"$HOME/.local/share"}
	INSTALL_ROOT="$XDG_DATA_HOME/leechblockng"
	VERSION_DIR="$INSTALL_ROOT/$VERSION"
	CURRENT_LINK="$INSTALL_ROOT/current"
}

download_extension() {
	if [[ -d $VERSION_DIR && $FORCE -ne 1 ]]; then
		info "LeechBlockNG $VERSION already present at $VERSION_DIR (use --force to reinstall)."
	else
		info "Downloading LeechBlockNG $TAG source from GitHub…"
		tmpdir=$(mktemp -d)
		trap 'rm -rf "$tmpdir"' EXIT
		ARCHIVE_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/refs/tags/${TAG}.tar.gz"
		ARCHIVE_FILE="$tmpdir/${REPO_NAME}-${TAG}.tar.gz"
		curl -fL --retry 3 -o "$ARCHIVE_FILE" "$ARCHIVE_URL"
		info "Extracting…"
		mkdir -p "$tmpdir/extract"
		tar -xzf "$ARCHIVE_FILE" -C "$tmpdir/extract"
		# The archive usually extracts to REPO_NAME-TAG/ …
		src_root=$(find "$tmpdir/extract" -maxdepth 1 -type d -name "${REPO_NAME}-*" | head -n1 || true)
		[[ -z $src_root ]] && {
			err "Could not locate extracted source root"
			exit 1
		}

		# Find the extension manifest (support a couple of common layouts)
		manifest_path=$(find "$src_root" -maxdepth 5 -type f -name manifest.json | head -n1 || true)
		if [[ -z $manifest_path ]]; then
			err "manifest.json not found in the extracted archive. The project layout may have changed."
			exit 1
		fi
		ext_dir=$(dirname "$manifest_path")

		mkdir -p "$INSTALL_ROOT"
		rm -rf "$VERSION_DIR"
		info "Installing to $VERSION_DIR…"
		mkdir -p "$VERSION_DIR"
		# Copy the extension directory as-is (avoid bringing tests or build scripts)
		rsync -a --delete "$ext_dir/" "$VERSION_DIR/" 2>/dev/null || cp -a "$ext_dir/." "$VERSION_DIR/"

		# Download jQuery UI (not included in repo — listed in .gitignore)
		# The extension's options.html expects:
		#   jquery-ui/jquery-ui.min.css
		#   jquery-ui/external/jquery/jquery.js
		#   jquery-ui/jquery-ui.min.js
		info "Downloading jQuery UI…"
		jqui_version="1.14.1"
		jqui_url="https://jqueryui.com/resources/download/jquery-ui-${jqui_version}.zip"
		jqui_zip="$tmpdir/jquery-ui.zip"
		curl -fL --retry 3 -o "$jqui_zip" "$jqui_url"
		mkdir -p "$tmpdir/jqui-extract"
		unzip -q "$jqui_zip" -d "$tmpdir/jqui-extract"
		jqui_src=$(find "$tmpdir/jqui-extract" -maxdepth 1 -type d -name "jquery-ui-*" | head -n1 || true)
		if [[ -n $jqui_src ]]; then
			mkdir -p "$VERSION_DIR/jquery-ui/external/jquery"
			cp "$jqui_src/jquery-ui.min.css" "$VERSION_DIR/jquery-ui/" 2>/dev/null || true
			cp "$jqui_src/jquery-ui.min.js" "$VERSION_DIR/jquery-ui/" 2>/dev/null || true
			cp "$jqui_src/external/jquery/jquery.js" "$VERSION_DIR/jquery-ui/external/jquery/" 2>/dev/null || true
			info "✓ jQuery UI ${jqui_version} installed into extension"
		else
			warn "Could not extract jQuery UI — options page may not work correctly"
		fi

		ln -sfn "$VERSION_DIR" "$CURRENT_LINK"
	fi
}
