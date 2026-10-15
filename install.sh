#!/usr/bin/env bash
# Installs or updates Kosmodock from its GitHub releases.
#
#   curl -fsSL https://raw.githubusercontent.com/soaresnro/kosmodock/main/install.sh | bash
#
# Downloads the release .zip, checks it against the release's SHA256SUMS.txt,
# and checks that the app is signed with the release certificate pinned in the
# repository at that release's tag. Files fetched with curl aren't quarantined,
# so Gatekeeper doesn't stop the first launch: running this script is the trust
# decision instead of "Open Anyway". Nothing besides the app is installed.
#
#   KOSMODOCK_VERSION=1.0.1               that version instead of the latest
#   KOSMODOCK_INSTALL_DIR=~/Applications  somewhere other than /Applications
#   KOSMODOCK_NO_OPEN=1                   don't launch it afterwards
#
# With curl | bash, put the variables before bash: `curl … | KOSMODOCK_NO_OPEN=1 bash`.
set -euo pipefail

REPO="soaresnro/kosmodock"
BUNDLE_ID="dev.kosmodock.Kosmodock"
WORK=""

say() { printf '▸ %s\n' "$*"; }
fail() { printf '✗ %s\n' "$*" >&2; exit 1; }

# Everything runs from main, called on the last line, so a truncated download runs nothing.
main() {
    [[ "$(uname -s)" == Darwin ]] || fail "Kosmodock runs on macOS only."
    local os major
    os="$(sw_vers -productVersion)"
    major="${os%%.*}"
    (( major >= 14 )) || fail "Kosmodock needs macOS 14 or later (this Mac has $os)."
    [[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" == 1 ]] || fail "Kosmodock needs a Mac with Apple Silicon."

    local version="${KOSMODOCK_VERSION:-}"
    if [[ -z "$version" ]]; then
        # /releases/latest redirects to /releases/tag/vX.Y.Z: no API call, no rate limit, no JSON.
        local latest
        latest="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")"
        version="${latest##*/}"
    fi
    version="${version#v}"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] || fail "Couldn't tell which release to install (got \"$version\")."
    local tag="v$version" zip="Kosmodock-$version.zip"
    local base="https://github.com/$REPO/releases/download/$tag"
    local install_dir="${KOSMODOCK_INSTALL_DIR:-/Applications}"
    local dest="$install_dir/Kosmodock.app"
    mkdir -p "$install_dir"
    [[ -w "$install_dir" ]] || fail "Can't write to $install_dir. Use an administrator account, or KOSMODOCK_INSTALL_DIR=~/Applications."

    curl -fsSIL -o /dev/null "https://github.com/$REPO/releases/tag/$tag" 2>/dev/null \
        || fail "There's no Kosmodock release $tag. See https://github.com/$REPO/releases"
    local pin
    pin="$(curl -fsSL "https://raw.githubusercontent.com/$REPO/$tag/.github/release-signing-certificate.sha1" 2>/dev/null | tr -d '[:space:]')" || pin=""
    [[ "$pin" =~ ^[0-9a-f]{40}$ ]] || fail "Kosmodock $version isn't signed with the release certificate. Install it from the .dmg instead: https://github.com/$REPO/releases/tag/$tag"

    WORK="$(mktemp -d)"
    # Keep the exit status: otherwise an error exit reports rm's success.
    trap 'rc=$?; rm -rf "$WORK"; exit $rc' EXIT

    say "Downloading Kosmodock ${version}…"
    curl -fsSL -o "$WORK/$zip" "$base/$zip" 2>/dev/null || fail "Release $tag has no $zip."
    curl -fsSL -o "$WORK/SHA256SUMS.txt" "$base/SHA256SUMS.txt" 2>/dev/null || fail "Release $tag has no SHA256SUMS.txt."
    (cd "$WORK" && awk -v f="$zip" '$2 == f' SHA256SUMS.txt | shasum -a 256 -c - >/dev/null 2>&1) \
        || fail "$zip doesn't match the release's SHA256SUMS.txt. Not installing it."

    ditto -x -k "$WORK/$zip" "$WORK/unzipped"
    local app="$WORK/unzipped/Kosmodock.app"
    codesign --verify --deep --strict -R "=identifier \"$BUNDLE_ID\" and certificate leaf = H\"$pin\"" "$app" 2>/dev/null \
        || fail "Kosmodock.app isn't signed with the release certificate $pin. Not installing it."
    say "Checksum and signature verified (release certificate $pin)."

    # Only one Kosmodock runs at a time, and a running app can't be replaced in place.
    local pid running=""
    pid="$(pgrep -x Kosmodock | head -1 || true)"
    [[ -n "$pid" ]] && running="$(ps -o comm= -p "$pid" || true)"
    if [[ -n "$running" && ( -z "${KOSMODOCK_NO_OPEN:-}" || "$running" == "$dest/"* ) ]]; then
        say "Quitting the running Kosmodock…"
        osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
        local _
        for _ in {1..40}; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.25
        done
        if kill -0 "$pid" 2>/dev/null; then
            fail "Kosmodock didn't quit. Quit it from its menu and run this again."
        fi
    fi

    # The Accessibility grant belongs to a signature. If the installed app was signed
    # differently (1.0.0 was ad-hoc), its grant would look on without working, so reset it
    # while macOS still knows the old app; tccutil can't find a bundle id that's gone.
    local grant=kept
    if [[ -d "$dest" ]]; then
        local old
        old="$(codesign -d -r- "$dest" 2>&1 | sed -n 's/.*certificate leaf = H"\([0-9a-f]*\)".*/\1/p')"
        if [[ "$old" != "$pin" ]]; then
            tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
            grant=new-signature
        fi
    else
        grant=first-install
    fi

    local staged="$install_dir/.Kosmodock.app.installing"
    rm -rf "$staged"
    ditto "$app" "$staged"
    rm -rf "$dest"
    mv "$staged" "$dest"
    say "Installed Kosmodock $version in $install_dir."

    case "$grant" in
        first-install) say "When Kosmodock asks, turn it on in System Settings → Privacy & Security → Accessibility." ;;
        new-signature) say "This build has a new signature, so grant Accessibility again when Kosmodock asks." ;;
        kept) say "Your Accessibility permission carries over." ;;
    esac

    if [[ -z "${KOSMODOCK_NO_OPEN:-}" ]]; then
        open "$dest"
    fi
}

main "$@"
