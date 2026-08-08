#!/usr/bin/env bash
# Default: sign unsigned packages, rebuild pearos.db, rclone push (no TUI).
# ./sign.sh --ui  -> interactive menu (dialog).
# Or: ./sign (symlink to sign.sh)

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

shopt -s nullglob

REMOTE_RCLONE="r2-pearos:package-repo/main/x86_64"
LOCAL_DIR="."

# Non-interactive GPG signing. Priority:
#  1) GPG_PASSPHRASE_FILE env var (file with 600 perms, contains passphrase only)
#  2) $SCRIPT_DIR/.gpg-passphrase (same format, not committed to the repo)
#  3) fall back to --use-agent (gpg-agent cache / pinentry prompt)
GPG_PASSPHRASE_FILE="${GPG_PASSPHRASE_FILE:-$SCRIPT_DIR/.gpg-passphrase}"
[[ -f "$GPG_PASSPHRASE_FILE" ]] || GPG_PASSPHRASE_FILE=""

RCLONE_PUSH_LOG="$SCRIPT_DIR/rclone-push.log"
RCLONE_PULL_LOG="$SCRIPT_DIR/rclone-pull.log"

# Stats after sign_unsigned_work
_SU_N=0
_SU_OK=0
_SU_FAIL=0

require_dialog() {
	if ! command -v dialog >/dev/null 2>&1; then
		echo "Missing \`dialog\`. Install: sudo pacman -S dialog" >&2
		exit 1
	fi
}

refresh_stats() {
	total=0
	signed=0
	unsigned=0
	for pkg in *.pkg.tar.zst; do
		[[ -f "$pkg" ]] || continue
		total=$((total + 1))
		if [[ -f "$pkg.sig" ]]; then
			signed=$((signed + 1))
		else
			unsigned=$((unsigned + 1))
		fi
	done
}

summary_text() {
	printf ".pkg.tar.zst packages: %s  |  Signed: %s  |  Missing .sig: %s" "$total" "$signed" "$unsigned"
}

gpg_sign_pkg() {
	local pkg=$1
	if [[ -n "$GPG_PASSPHRASE_FILE" ]]; then
		gpg --batch --yes --pinentry-mode loopback \
			--passphrase-file "$GPG_PASSPHRASE_FILE" \
			--detach-sign "$pkg"
	else
		gpg --detach-sign --use-agent "$pkg"
	fi
}

sign_unsigned_work() {
	local pkg
	_SU_N=0
	_SU_OK=0
	_SU_FAIL=0
	for pkg in *.pkg.tar.zst; do
		[[ -f "$pkg" ]] || continue
		if [[ -f "$pkg.sig" ]]; then
			continue
		fi
		_SU_N=$((_SU_N + 1))
		if gpg_sign_pkg "$pkg" 2>/tmp/pearos-sign-err.$$; then
			_SU_OK=$((_SU_OK + 1))
		else
			_SU_FAIL=$((_SU_FAIL + 1))
		fi
	done
	rm -f /tmp/pearos-sign-err.$$
	((_SU_FAIL == 0))
}

do_sign_unsigned() {
	local pkg statfile
	statfile=$(mktemp)
	{
		_SU_N=0
		_SU_OK=0
		_SU_FAIL=0
		for pkg in *.pkg.tar.zst; do
			[[ -f "$pkg" ]] || continue
			[[ -f "$pkg.sig" ]] && continue
			_SU_N=$((_SU_N + 1))
			echo "==> Signing: $pkg"
			if gpg_sign_pkg "$pkg" 2>&1; then
				_SU_OK=$((_SU_OK + 1))
			else
				_SU_FAIL=$((_SU_FAIL + 1))
				echo "    FAILED"
			fi
		done
		echo "$_SU_N $_SU_OK $_SU_FAIL" >"$statfile"
	} | dialog --title "Signing" --programbox 20 70
	read -r _SU_N _SU_OK _SU_FAIL <"$statfile"
	rm -f "$statfile"
	if ((_SU_FAIL > 0)); then
		dialog --title "Signing" --msgbox "Signing failed for some packages.\nProcessed: $_SU_N\nOK: $_SU_OK\nFailed: $_SU_FAIL" 12 45
	elif ((_SU_N == 0)); then
		dialog --title "Signing" --msgbox "Nothing to sign (all packages already have .sig, or there are no .pkg.tar.zst files)." 10 55
	else
		dialog --title "Signing" --msgbox "Processed: $_SU_N\nOK: $_SU_OK\nFailed: $_SU_FAIL" 12 45
	fi
}

prune_missing_from_db() {
	local db="pearos.db.tar.gz"
	[[ -f "$db" ]] || return 0
	local -a present stale
	local pkg base name
	for pkg in *.pkg.tar.zst; do
		[[ -f "$pkg" ]] || continue
		base="${pkg%.pkg.tar.zst}"
		name="${base%-*-*-*}"
		present+=("$name")
	done
	local entry
	for entry in $(tar -tzf "$db" 2>/dev/null | sed 's#/.*##' | sort -u); do
		[[ "$entry" == */* ]] && continue
		name="${entry%-*-*}"
		if [[ ! " ${present[*]} " == *" $name "* ]]; then
			stale+=("$name")
		fi
	done
	if ((${#stale[@]} > 0)); then
		repo-remove pearos.db.tar.gz "${stale[@]}"
	fi
}

rebuild_db_work() {
	refresh_stats
	if ((total == 0)); then
		return 1
	fi
	repo-add pearos.db.tar.gz *.pkg.tar.zst
	prune_missing_from_db
}

do_rebuild_db() {
	local statfile rc
	refresh_stats
	if ((total == 0)); then
		dialog --title "repo-add" --msgbox "No .pkg.tar.zst files in this directory." 9 50
		return
	fi
	statfile=$(mktemp)
	{
		rebuild_db_work
		echo "$?" >"$statfile"
	} 2>&1 | dialog --title "repo-add" --programbox 22 78
	rc=$(cat "$statfile" 2>/dev/null); rc=${rc:-1}
	rm -f "$statfile"
	if ((rc == 0)); then
		rm -f pearos.db 2>/dev/null || true
		cp -f pearos.db.tar.gz pearos.db
		dialog --title "repo-add" --msgbox "pearos.db.tar.gz database rebuilt." 9 50
	else
		dialog --title "repo-add - error" --msgbox "repo-add / repo-remove failed (see previous output)." 9 55
	fi
}

_show_rclone_error() {
	local title=$1 path=$2 logname
	logname=$(basename -- "$path")
	dialog --title "${title} - error (log: ${logname})" --textbox "$path" 26 85
}

# TUI: rclone push, live output in programbox + log file.
_push_tui_sync() {
	local rc statfile
	statfile=$(mktemp)
	{
		echo "======== $(date '+%F %T') - rclone push - $REMOTE_RCLONE ========"
		echo ""
	} >"$RCLONE_PUSH_LOG"
	{
		rclone sync "$LOCAL_DIR" "$REMOTE_RCLONE" \
			-L \
			--filter "+ *.pkg.tar.zst*" \
			--filter "+ pearos.db*" \
			--filter "+ pearos.files*" \
			--filter "+ *.sh" \
			--filter "+ sign" \
			--filter "- Makefile" \
			--filter "- PKGBUILD" \
			--filter "- *" \
			-v \
			--stats=5s \
			--stats-one-line \
			--delete-after \
			--fast-list 2>&1
		echo "$?" >"$statfile"
	} | tee -a "$RCLONE_PUSH_LOG" | dialog --title "Push - $REMOTE_RCLONE" --programbox 26 85
	rc=$(cat "$statfile" 2>/dev/null); rc=${rc:-1}
	rm -f "$statfile"
	{
		echo ""
		echo "======== rclone exit code: $rc ========"
	} >>"$RCLONE_PUSH_LOG"
	((rc != 0)) && _show_rclone_error "Push" "$RCLONE_PUSH_LOG"
}

do_push() {
	local pu
	if ! command -v rclone >/dev/null 2>&1; then
		dialog --title "Push" --msgbox "rclone not found. Install: sudo pacman -S rclone" 9 52
		return
	fi
	refresh_stats
	if ((unsigned > 0)); then
		pu=$(dialog --stdout --title "Upload - unsigned packages" \
			--menu "Some .pkg.tar.zst files have no .sig. With SigLevel = Required, pacman will reject them.\n\nChoose an action:" 17 74 3 \
			1 "Upload without signing (not recommended)" \
			2 "Sign then upload (recommended)" \
			3 "Cancel") || return
		case "$pu" in
			1)
				if ! dialog --title "Upload - confirm" --yesno "Really upload with unsigned packages? This is not recommended." 10 62; then
					return
				fi
				;;
			2)
				if ! sign_unsigned_work; then
					dialog --title "Signing failed" --msgbox "GPG signing failed (see terminal if gpg printed errors). Fix the issue and try upload again." 12 58
					return
				fi
				;;
			3 | *) return ;;
		esac
	fi
	_push_tui_sync
}

# CLI / auto: same as push.sh (terminal progress).
push_work() {
	rclone sync "$LOCAL_DIR" "$REMOTE_RCLONE" \
		-L \
		--filter "+ *.pkg.tar.zst*" \
		--filter "+ pearos.db*" \
		--filter "+ pearos.files*" \
		--filter "+ *.sh" \
		--filter "+ sign" \
		--filter "- Makefile" \
		--filter "- PKGBUILD" \
		--filter "- *" \
		--progress \
		--delete-after \
		--fast-list
}

do_pull() {
	local rc statfile
	if ! command -v rclone >/dev/null 2>&1; then
		dialog --title "Pull" --msgbox "rclone not found. Install: sudo pacman -S rclone" 9 52
		return
	fi
	if ! dialog --title "Pull - confirmation" --yesno "This pull will sync from the server into your local directory and may delete local files (because rclone uses --delete-after).\n\nContinue?" 14 85; then
		return
	fi
	statfile=$(mktemp)
	{
		echo "======== $(date '+%F %T') - rclone pull - $REMOTE_RCLONE ========"
		echo ""
	} >"$RCLONE_PULL_LOG"
	{
		rclone sync "$REMOTE_RCLONE" "$LOCAL_DIR" \
			-L \
			--filter "+ *.pkg.tar.zst*" \
			--filter "+ pearos.db*" \
			--filter "+ pearos.files*" \
			--filter "+ *.sh" \
			--filter "+ sign" \
			--filter "- Makefile" \
			--filter "- PKGBUILD" \
			--filter "- *" \
			-v \
			--stats=5s \
			--stats-one-line \
			--delete-after \
			--fast-list 2>&1
		echo "$?" >"$statfile"
	} | tee -a "$RCLONE_PULL_LOG" | dialog --title "Pull - $REMOTE_RCLONE" --programbox 26 85
	rc=$(cat "$statfile" 2>/dev/null); rc=${rc:-1}
	rm -f "$statfile"
	{
		echo ""
		echo "======== rclone exit code: $rc ========"
	} >>"$RCLONE_PULL_LOG"
	((rc != 0)) && _show_rclone_error "Pull" "$RCLONE_PULL_LOG"
}

do_unsign_all() {
	local f n=0
	dialog --title "Unsign all" --yesno "Delete every *.sig file in this directory? This cannot be undone." 10 60 || return
	for f in *.sig; do
		[[ -f "$f" ]] || continue
		rm -f -- "$f"
		n=$((n + 1))
	done
	dialog --title "Unsign all" --msgbox "Removed $n signature file(s)." 9 50
}

main_menu() {
	local choice h
	while true; do
		refresh_stats
		h=18
		((total == 0)) && h=16
		choice=$(dialog --stdout --clear --title "pearOS - local x86_64 repo" \
			--menu "$(summary_text)" "$h" 72 8 \
			1 "Sign packages missing .sig (gpg)" \
			2 "Rebuild pearos.db (repo-add)" \
			3 "Upload to server (rclone push)" \
			4 "Download from server (rclone pull)" \
			5 "Unsign all (delete all .sig files)" \
			0 "Exit") || break

		case "$choice" in
			1) do_sign_unsigned ;;
			2) do_rebuild_db ;;
			3) do_push ;;
			4) do_pull ;;
			5) do_unsign_all ;;
			0) break ;;
		esac
	done
}

run_auto_pipeline() {
	echo "==> GPG: sign packages missing .sig..."
	if ! sign_unsigned_work; then
		echo "Signing failed (see gpg output above)." >&2
		return 1
	fi
	if ((_SU_N == 0)); then
		echo "    Nothing to sign."
	else
		echo "    Signed: $_SU_OK / $_SU_N (failed: $_SU_FAIL)"
	fi

	echo "==> repo-add: rebuild pearos.db..."
	refresh_stats
	if ((total == 0)); then
		echo "No .pkg.tar.zst in this directory; abort." >&2
		return 1
	fi
	if ! rebuild_db_work; then
		echo "repo-add failed." >&2
		return 1
	fi
	rm -f pearos.db 2>/dev/null || true
	cp -f pearos.db.tar.gz pearos.db
	echo "    Database updated."

	if ! command -v rclone >/dev/null 2>&1; then
		echo "rclone not found. Install: sudo pacman -S rclone" >&2
		return 1
	fi
	echo "==> rclone: push to $REMOTE_RCLONE..."
	if ! push_work; then
		echo "rclone push failed." >&2
		return 1
	fi
	echo "==> Done."
}

usage() {
	echo "Usage: $(basename "$0") [--ui] [--help]" >&2
	echo "  (default)  Sign, rebuild pearos.db, push (no TUI)" >&2
	echo "  --ui      Interactive menu (dialog)" >&2
	exit "${1:-0}"
}

case "${1:-}" in
	--ui)
		require_dialog
		main_menu
		clear
		echo "Goodbye."
		;;
	--help | -h)
		usage 0
		;;
	"")
		run_auto_pipeline
		;;
	*)
		echo "Unknown option: $1" >&2
		usage 1
		;;
esac
