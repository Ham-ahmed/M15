#!/bin/sh

##setup command=wget -q https://raw.githubusercontent.com/Ham-ahmed/M15/refs/heads/main/MagicPanelMax-install.sh -O - | /bin/sh

######### Only This line to edit with new version ######
version='15.0'
##############################################################

# Optional environment variables:
#   ALLOW_INSECURE=1      -> allow a fallback WITHOUT certificate verification
#                            (only if your box has no CA certificates)
#   EXPECTED_SHA256=<hex> -> force a specific SHA-256 for the archive

# The Enigma2 "Terminal" plugin may start the shell with a minimal PATH
# (that is why "tar: command not found" can appear). Set a full PATH first.
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
export PATH

PLUGIN_NAME="MagicPanelMax"
GITHUB_BASE="https://raw.githubusercontent.com/Ham-ahmed/M15/refs/heads/main"
ARCHIVE="${PLUGIN_NAME}_v${version}.tar.gz"
ALLOW_INSECURE="${ALLOW_INSECURE:-0}"
EXPECTED_SHA256="${EXPECTED_SHA256:-}"

TMPPATH=""
BACKUP=""
EXTRACT_DIR=""
LOCKDIR="/tmp/${PLUGIN_NAME}.lock"
LOCK_OWNED=0
OLD_REMOVED=0
INSTALL_DONE=0
PYBIN=""

# Plugin path (by architecture)
if [ -d /usr/lib64/enigma2 ]; then
    PLUGINPATH="/usr/lib64/enigma2/python/Plugins/Extensions/${PLUGIN_NAME}"
else
    PLUGINPATH="/usr/lib/enigma2/python/Plugins/Extensions/${PLUGIN_NAME}"
fi

# All locations where an old version may exist
OLD_DIRS="/usr/lib/enigma2/python/Plugins/Extensions/${PLUGIN_NAME} /usr/lib64/enigma2/python/Plugins/Extensions/${PLUGIN_NAME}"

# Known package names of the plugin
OLD_PACKAGES="enigma2-plugin-extensions-magicpanelmax enigma2-plugin-extensions-magicpanel-max"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_message() {
    printf '%b%s%b\n' "$1" "$2" "$NC"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------
# Required tools (use busybox applets when a standalone binary is missing)
# ---------------------------------------------------------------
MISSING_TOOLS=""
for _t in tar gzip grep sed head cut tr wc find cp mv rm mkdir chmod; do
    if ! command_exists "$_t"; then
        if command_exists busybox && busybox --list 2>/dev/null | grep -qx "$_t"; then
            eval "$_t() { busybox $_t \"\$@\"; }"
        else
            MISSING_TOOLS="$MISSING_TOOLS $_t"
        fi
    fi
done
if [ -n "$MISSING_TOOLS" ]; then
    print_message "$RED" "> Missing required tools:$MISSING_TOOLS"
    print_message "$YELLOW" "> Install them first, e.g.: opkg update && opkg install tar gzip"
    exit 1
fi

# ---------------------------------------------------------------
# Sanity check on the version string (it is used in URLs)
# ---------------------------------------------------------------
case "$version" in
    ""|*[!0-9.]*)
        print_message "$RED" "> Invalid version string: $version"
        exit 1
        ;;
esac

# ---------------------------------------------------------------
# Rollback: restore the old version if the new install fails
# ---------------------------------------------------------------
rollback() {
    if [ "$OLD_REMOVED" -eq 1 ] && [ "$INSTALL_DONE" -eq 0 ] && [ -n "$BACKUP" ] && [ -d "$BACKUP" ]; then
        print_message "$YELLOW" "> Restoring the previous version (rollback)..."
        for d in $OLD_DIRS; do
            rm -rf "$d" >/dev/null 2>&1
        done
        for p in "$BACKUP"/*.path; do
            [ -f "$p" ] || continue
            dest=$(cat "$p")
            src="${p%.path}"
            mkdir -p "$dest"
            cp -a "$src"/. "$dest"/ >/dev/null 2>&1
        done
        OLD_REMOVED=0
        print_message "$GREEN" "> Previous version restored."
    fi
}

# Always runs on exit: remove temp files and the lock
cleanup() {
    cd / 2>/dev/null
    case "$TMPPATH" in
        /tmp/"${PLUGIN_NAME}".*) rm -rf "$TMPPATH" >/dev/null 2>&1 ;;
    esac
    if [ "$LOCK_OWNED" -eq 1 ]; then
        rm -rf "$LOCKDIR" >/dev/null 2>&1
        LOCK_OWNED=0
    fi
}

on_signal() {
    echo ""
    print_message "$RED" "> Interrupted."
    rollback
    exit 130
}

die() {
    print_message "$RED" "$1"
    rollback
    exit 1
}

# ---------------------------------------------------------------
# System information helpers
# ---------------------------------------------------------------
# Print the first non-empty first line among the given files
read_first() {
    for _f in "$@"; do
        if [ -r "$_f" ]; then
            _v=$(head -n 1 "$_f" 2>/dev/null | tr -d '\r')
            if [ -n "$_v" ]; then
                printf '%s\n' "$_v"
                return 0
            fi
        fi
    done
    return 1
}

# kv_get <file> <key>  ->  value of key=value
kv_get() {
    [ -r "$1" ] || return 1
    sed -n "s/^$2[[:space:]]*=[[:space:]]*//p" "$1" 2>/dev/null | head -n 1 | tr -d '\r"'
}

bb_get() {
    printf '%s\n' "$BB" | sed -n "s/^$1=//p" | head -n 1
}

detect_python() {
    Packagesix=""
    Packagerequests="python-requests"
    PYBIN=""
    PYMAJOR=""
    if command_exists python3; then
        PYBIN="python3"
        PYMAJOR=3
    elif command_exists python2; then
        PYBIN="python2"
        PYMAJOR=2
    elif command_exists python; then
        PYBIN="python"
        if python --version 2>&1 | grep -q '^Python 3\.'; then
            PYMAJOR=3
        else
            PYMAJOR=2
        fi
    fi

    if [ "$PYMAJOR" = "3" ]; then
        Packagesix="python3-six"
        Packagerequests="python3-requests"
    fi
}

collect_system_info() {
    # --- Python version ---
    PYVER=""
    if [ -n "$PYBIN" ]; then
        PYVER=$("$PYBIN" --version 2>&1 </dev/null | head -n 1 | sed 's/^Python //')
    fi
    [ -n "$PYVER" ] || PYVER="Unknown"

    # --- Ask enigma2's boxbranding module (OpenATV, OpenPLi, ...) ---
    BB=""
    if [ -n "$PYBIN" ]; then
        BB=$("$PYBIN" -c '
import sys
for p in ("/usr/lib/enigma2/python", "/usr/lib64/enigma2/python"):
    if p not in sys.path:
        sys.path.append(p)
try:
    import boxbranding as b
    def g(n):
        try:
            return str(getattr(b, n)())
        except Exception:
            return ""
    print("BRAND=" + g("getMachineBrand"))
    print("NAME=" + g("getMachineName"))
    print("BOXTYPE=" + g("getBoxType"))
    print("DISTRO=" + g("getImageDistro"))
    print("IMGVER=" + g("getImageVersion"))
    print("IMGBUILD=" + g("getImageBuild"))
except Exception:
    pass
' 2>/dev/null </dev/null)
    fi

    BRAND=$(bb_get BRAND)
    MNAME=$(bb_get NAME)
    BOXTYPE=$(bb_get BOXTYPE)
    DISTRO=$(bb_get DISTRO)
    IMGVER=$(bb_get IMGVER)
    IMGBUILD=$(bb_get IMGBUILD)

    # --- Model (internal box type) ---
    if [ -z "$BOXTYPE" ]; then
        BOXTYPE=$(read_first /proc/stb/info/boxtype /proc/stb/info/hwmodel \
            /proc/stb/info/gbmodel /proc/stb/info/vumodel /proc/stb/info/model /etc/model)
    fi
    MODEL="${BOXTYPE:-Unknown}"

    # --- Receiver name (brand + name) ---
    if [ -z "$BRAND" ] && [ "$OSTYPE_NAME" = "DreamOs" ]; then
        BRAND="Dreambox"
    fi
    if [ -n "$MNAME" ]; then
        RECEIVER="$BRAND $MNAME"
    elif [ -n "$BRAND" ] && [ -n "$BOXTYPE" ]; then
        RECEIVER="$BRAND $BOXTYPE"
    elif [ -n "$BOXTYPE" ]; then
        RECEIVER="$BOXTYPE"
    else
        RECEIVER=$(read_first /etc/hostname)
        [ -n "$RECEIVER" ] || RECEIVER="Unknown"
    fi

    # --- Enigma2 image name ---
    if [ -z "$DISTRO" ]; then
        DISTRO=$(kv_get /etc/image-version distro)
        [ -n "$DISTRO" ] || DISTRO=$(kv_get /etc/os-release NAME)
        [ -n "$DISTRO" ] || DISTRO=$(head -n 1 /etc/issue 2>/dev/null \
            | sed 's/\\[a-zA-Z]//g; s/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//')
    fi
    if [ -z "$IMGVER" ]; then
        IMGVER=$(kv_get /etc/image-version version)
        [ -n "$IMGVER" ] || IMGVER=$(kv_get /etc/os-release VERSION_ID)
    fi
    IMAGE="${DISTRO:-Unknown}"
    [ -n "$IMGVER" ] && IMAGE="$IMAGE $IMGVER"
    [ -n "$IMGBUILD" ] && IMAGE="$IMAGE (build $IMGBUILD)"

    ARCH=$(uname -m 2>/dev/null)
    [ -n "$ARCH" ] || ARCH="Unknown"
}

info_line() {
    print_message "$GREEN" "$(printf '  %-16s: %s' "$1" "$2")"
}

show_system_info() {
    print_message "$CYAN" "------------------- Device Information -------------------"
    info_line "Receiver"      "$RECEIVER"
    info_line "Model"         "$MODEL"
    info_line "Enigma2 Image" "$IMAGE"
    info_line "Python"        "$PYVER ($PYBIN)"
    info_line "Architecture"  "$ARCH"
    info_line "Package type"  "$([ "$OSTYPE_NAME" = "DreamOs" ] && echo 'DEB (apt)' || echo 'IPK (opkg)')"
    print_message "$CYAN" "----------------------------------------------------------"
    echo ""
}

# ---------------------------------------------------------------
# Package helpers
# ---------------------------------------------------------------
check_package() {
    pkg="$1"
    if [ -f /var/lib/dpkg/status ]; then
        grep -qs "^Package: ${pkg}\$" /var/lib/dpkg/status
    elif [ -f /var/lib/opkg/status ]; then
        grep -qs "^Package: ${pkg}\$" /var/lib/opkg/status
    else
        return 1
    fi
}

install_package() {
    pkg="$1"
    print_message "$BLUE" "> Installing $pkg..."
    if [ "$OSTYPE_NAME" = "DreamOs" ]; then
        command_exists apt-get || { print_message "$RED" "> apt-get not found!"; return 1; }
        apt-get update >/dev/null 2>&1 </dev/null && apt-get install "$pkg" -y >/dev/null 2>&1 </dev/null
    else
        command_exists opkg || { print_message "$RED" "> opkg not found!"; return 1; }
        opkg update >/dev/null 2>&1 </dev/null && opkg install "$pkg" >/dev/null 2>&1 </dev/null
    fi
}

# ---------------------------------------------------------------
# Download with retries (HTTPS only, certificate verified by default)
# usage: download_file <url> <output> [attempts]
# ---------------------------------------------------------------
download_file() {
    url="$1"
    output="$2"
    max="${3:-3}"
    attempt=1

    case "$url" in
        https://*) ;;
        *) print_message "$RED" "> Refusing non-HTTPS URL: $url"; return 1 ;;
    esac

    while [ "$attempt" -le "$max" ]; do
        print_message "$BLUE" "> Download attempt $attempt of $max..."
        rm -f "$output"

        if command_exists wget; then
            wget -q -T 30 "$url" -O "$output" >/dev/null 2>&1 </dev/null
            [ -s "$output" ] && return 0
            rm -f "$output"
        fi
        if command_exists curl; then
            curl -fsSL --connect-timeout 20 --max-time 120 "$url" -o "$output" >/dev/null 2>&1 </dev/null
            [ -s "$output" ] && return 0
            rm -f "$output"
        fi

        # Unverified fallback: ONLY when explicitly allowed by the user
        if [ "$ALLOW_INSECURE" = "1" ]; then
            print_message "$YELLOW" "> WARNING: retrying WITHOUT certificate verification (ALLOW_INSECURE=1)"
            if command_exists wget; then
                wget -q -T 30 --no-check-certificate "$url" -O "$output" >/dev/null 2>&1 </dev/null
                [ -s "$output" ] && return 0
                rm -f "$output"
            fi
            if command_exists curl; then
                curl -fsSL --connect-timeout 20 --max-time 120 --insecure "$url" -o "$output" >/dev/null 2>&1 </dev/null
                [ -s "$output" ] && return 0
                rm -f "$output"
            fi
        fi

        attempt=$((attempt + 1))
        [ "$attempt" -le "$max" ] && sleep 2
    done
    rm -f "$output"
    return 1
}

# ---------------------------------------------------------------
# Update check
# ---------------------------------------------------------------
check_for_updates() {
    print_message "$BLUE" "> Checking for updates..."
    LATEST_VERSION=""
    if download_file "${GITHUB_BASE}/version.txt" "$TMPPATH/version.txt"; then
        LATEST_VERSION=$(head -n 1 "$TMPPATH/version.txt" | tr -d '\r ' | grep -E '^[0-9.]+$')
    fi

    if [ -z "$LATEST_VERSION" ]; then
        print_message "$YELLOW" "> Cannot check for updates. Proceeding with installation..."
        return 1
    fi

    if [ "$version" != "$LATEST_VERSION" ]; then
        echo ""
        print_message "$GREEN"  "####################################################"
        print_message "$BLUE"   "#              New version available!              #"
        print_message "$YELLOW" "$(printf '#       Current version: %-23s#' "$version")"
        print_message "$BLUE"   "$(printf '#       Latest version:  %-23s#' "$LATEST_VERSION")"
        print_message "$YELLOW" "#    Please download latest version from:          #"
        print_message "$BLUE"   "#      https://github.com/Ham-ahmed/M15            #"
        print_message "$GREEN"  "####################################################"
        echo ""
        print_message "$YELLOW" "> Press Ctrl+C to cancel and download latest version"
        print_message "$YELLOW" "> Continuing with current version in 10 seconds..."
        sleep 10
        return 0
    fi
    print_message "$GREEN" "> You have the latest version ($version)"
    return 1
}

# ---------------------------------------------------------------
# Archive security checks
# ---------------------------------------------------------------
verify_checksum() {
    expected="$EXPECTED_SHA256"
    forced=0
    [ -n "$expected" ] && forced=1

    if [ -z "$expected" ]; then
        if download_file "${GITHUB_BASE}/${ARCHIVE}.sha256" "$TMPPATH/archive.sha256" 1; then
            expected=$(head -n 1 "$TMPPATH/archive.sha256" | cut -d' ' -f1 | tr -d '\r' | tr 'A-F' 'a-f')
        fi
    fi

    case "$expected" in
        *[!0-9a-f]*) expected="" ;;
    esac
    [ "${#expected}" -eq 64 ] || expected=""

    if [ -z "$expected" ]; then
        if [ "$forced" -eq 1 ]; then
            die "> EXPECTED_SHA256 is not a valid SHA-256 value!"
        fi
        print_message "$YELLOW" "> No SHA-256 checksum published for this archive (integrity relies on HTTPS only)."
        return 0
    fi

    if ! command_exists sha256sum; then
        [ "$forced" -eq 1 ] && die "> sha256sum not found, cannot verify the archive!"
        print_message "$YELLOW" "> sha256sum not available, skipping checksum verification."
        return 0
    fi

    actual=$(sha256sum "$TMPPATH/$ARCHIVE" 2>/dev/null | cut -d' ' -f1)
    if [ "$actual" != "$expected" ]; then
        die "> SHA-256 mismatch! The archive is corrupted or has been tampered with. (old version was not touched)"
    fi
    print_message "$GREEN" "> SHA-256 checksum verified"
}

validate_archive() {
    LIST="$TMPPATH/archive.list"
    ERRF="$TMPPATH/tar.err"

    tar -tzf "$TMPPATH/$ARCHIVE" > "$LIST" 2> "$ERRF"
    TAR_RC=$?
    if [ ! -s "$LIST" ]; then
        print_message "$YELLOW" "> tar cannot list this archive: $(head -n 1 "$ERRF" 2>/dev/null | cut -c1-100)"
        return 1
    fi
    if [ "$TAR_RC" -ne 0 ]; then
        print_message "$YELLOW" "> tar warning: $(head -n 1 "$ERRF" 2>/dev/null | cut -c1-100)"
    fi

    # Absolute paths or ".." components
    if grep -Eq '(^/|(^|/)\.\.(/|$))' "$LIST"; then
        print_message "$RED" "> Unsafe path found inside the archive (absolute path or '..')."
        return 1
    fi

    # Special entries (verbose listing). If this tar cannot produce it,
    # the same checks are done after extraction instead.
    if tar -tvzf "$TMPPATH/$ARCHIVE" > "$LIST.v" 2>/dev/null && [ -s "$LIST.v" ]; then
        if grep -Eq '^[bcph]' "$LIST.v"; then
            print_message "$RED" "> Archive contains special files (device/fifo/hardlink)."
            return 1
        fi
        if grep -Eq '^l.* -> (/|.*\.\.)' "$LIST.v"; then
            print_message "$RED" "> Archive contains a symlink pointing outside the plugin."
            return 1
        fi
    else
        print_message "$YELLOW" "> Verbose listing not supported by this tar; checking after extraction."
    fi
    return 0
}

# Checks on the extracted tree (device nodes, unsafe symlinks, setuid)
check_extracted_tree() {
    if [ -n "$(find "$EXTRACT_DIR" \( -type b -o -type c -o -type p -o -type s \) 2>/dev/null | head -n 1)" ]; then
        die "> Archive contains device/special files. Aborting. (old version was not touched)"
    fi
    find "$EXTRACT_DIR" -type l > "$TMPPATH/links.txt" 2>/dev/null
    while read -r l; do
        t=$(readlink "$l" 2>/dev/null)
        case "$t" in
            /*|*..*) die "> Unsafe symlink in archive: $l -> $t (old version was not touched)" ;;
        esac
    done < "$TMPPATH/links.txt"
    if [ -n "$(find "$EXTRACT_DIR" \( -perm -4000 -o -perm -2000 \) 2>/dev/null | head -n 1)" ]; then
        die "> Archive contains setuid/setgid files. Aborting. (old version was not touched)"
    fi
}

# Copy a "usr" tree only if every file lands in an expected Enigma2 location
install_usr_tree() {
    src="$1"
    BAD=$(cd "$src" 2>/dev/null && find usr -type f 2>/dev/null \
        | grep -Ev '^usr/(lib|lib64)/enigma2/|^usr/share/(enigma2|locale)/' | head -n 5)
    if [ -n "$BAD" ]; then
        print_message "$RED" "> Archive wants to write outside the allowed Enigma2 folders:"
        printf '%s\n' "$BAD"
        return 1
    fi
    cp -rf "$src/usr"/. /usr/ >/dev/null 2>&1
}

# ---------------------------------------------------------------
# Remove the old version completely (with backup for rollback)
# ---------------------------------------------------------------
remove_old_version() {
    print_message "$BLUE" "> Removing old version of $PLUGIN_NAME..."
    rm -rf "$BACKUP" >/dev/null 2>&1
    mkdir -p "$BACKUP"

    # 1) Backup existing folders
    i=0
    for d in $OLD_DIRS; do
        if [ -d "$d" ]; then
            i=$((i + 1))
            mkdir -p "$BACKUP/$i"
            cp -a "$d"/. "$BACKUP/$i"/ >/dev/null 2>&1
            echo "$d" > "$BACKUP/$i.path"
            print_message "$YELLOW" "> Found old version at: $d"
        fi
    done

    # From here on a failure must trigger a rollback
    OLD_REMOVED=1

    # 2) Remove package registered in the package manager
    for pkg in $OLD_PACKAGES; do
        if check_package "$pkg"; then
            print_message "$YELLOW" "> Removing package: $pkg"
            if [ "$OSTYPE_NAME" = "DreamOs" ]; then
                apt-get remove --purge -y "$pkg" >/dev/null 2>&1 </dev/null
            else
                opkg remove --force-depends "$pkg" >/dev/null 2>&1 </dev/null
            fi
        fi
    done

    # 3) Remove plugin folders (all architectures)
    for d in $OLD_DIRS; do
        [ -d "$d" ] && rm -rf "$d" >/dev/null 2>&1
    done

    if [ "$i" -eq 0 ]; then
        print_message "$GREEN" "> No old version found. Clean install."
    else
        print_message "$GREEN" "> Old version removed successfully."
    fi
}

# ===============================================================
#                           MAIN
# ===============================================================

# Environment detection
if [ -f /var/lib/dpkg/status ]; then
    OSTYPE_NAME="DreamOs"
else
    OSTYPE_NAME="Dream"
fi

# Must be root
if [ "$(id -u 2>/dev/null)" != "0" ]; then
    print_message "$RED" "> This installer must be run as root."
    exit 1
fi

umask 077

# Prevent two installers from running at the same time
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    oldpid=$(cat "$LOCKDIR/pid" 2>/dev/null)
    if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
        print_message "$RED" "> Another installation is already running (PID $oldpid)."
        exit 1
    fi
    rm -rf "$LOCKDIR" >/dev/null 2>&1
    mkdir "$LOCKDIR" || { print_message "$RED" "> Cannot create lock directory."; exit 1; }
fi
LOCK_OWNED=1
echo "$$" > "$LOCKDIR/pid"

# Private temporary workspace (unpredictable name, mode 700)
TMPPATH=$(mktemp -d "/tmp/${PLUGIN_NAME}.XXXXXX" 2>/dev/null)
if [ -z "$TMPPATH" ] || [ ! -d "$TMPPATH" ]; then
    TMPPATH="/tmp/${PLUGIN_NAME}.$$"
    rm -rf "$TMPPATH" >/dev/null 2>&1
    mkdir -m 700 "$TMPPATH" || { print_message "$RED" "> Cannot create temp folder."; cleanup; exit 1; }
fi
BACKUP="$TMPPATH/backup"
EXTRACT_DIR="$TMPPATH/extract"

trap cleanup EXIT
trap on_signal INT TERM HUP

cd "$TMPPATH" || exit 1

clear 2>/dev/null
echo ""
print_message "$CYAN"   "======================================================"
print_message "$YELLOW" "           MagicPanelMax Installer v$version"
print_message "$CYAN"   "======================================================"
echo ""

# Python detection
detect_python
if [ -z "$PYBIN" ]; then
    die "> Python not found! Please install Python first."
fi
if [ "$PYMAJOR" = "3" ]; then
    print_message "$GREEN" "> You have Python3 image"
else
    print_message "$GREEN" "> You have Python2 image"
fi
echo ""

# Device information
collect_system_info
show_system_info

check_for_updates

# ---------------------------------------------------------------
# Required packages
# ---------------------------------------------------------------
echo ""
print_message "$BLUE" "> Checking required packages..."

if [ -n "$Packagesix" ] && ! check_package "$Packagesix"; then
    print_message "$YELLOW" "> Required package $Packagesix not found, installing..."
    install_package "$Packagesix" || print_message "$YELLOW" "> Failed to install $Packagesix, continuing without it..."
fi

if ! check_package "$Packagerequests"; then
    print_message "$YELLOW" "> $Packagerequests must be installed"
    install_package "$Packagerequests" || die "> Failed to install $Packagerequests"
fi

echo ""
if [ -f /var/lib/dpkg/status ]; then
    print_message "$GREEN" "# Your image is OE2.5/2.6 #"
else
    print_message "$GREEN" "# Your image is OE2.0 #"
fi
echo ""

# ---------------------------------------------------------------
# Download + validate the NEW version first
# (the old version is NOT touched until the download is verified)
# ---------------------------------------------------------------
print_message "$BLUE" "> Downloading MagicPanelMax v$version..."

DOWNLOAD_SUCCESS=0
for url in \
    "${GITHUB_BASE}/${PLUGIN_NAME}_v${version}.tar.gz" \
    "${GITHUB_BASE}/${PLUGIN_NAME}_v${version}.tgz"
do
    print_message "$BLUE" "> Trying to download from: $url"
    case "$url" in
        *.tgz) tries=1 ;;
        *)     tries=3 ;;
    esac
    if download_file "$url" "$TMPPATH/$ARCHIVE" "$tries"; then
        if validate_archive; then
            DOWNLOAD_SUCCESS=1
            print_message "$GREEN" "> Download successful and archive validated"
            break
        else
            SZ=$(wc -c < "$TMPPATH/$ARCHIVE" 2>/dev/null | tr -d ' ')
            print_message "$YELLOW" "> Downloaded file is not a valid/safe tar.gz archive (${SZ:-0} bytes)"
            if [ -n "$SZ" ] && [ "$SZ" -lt 300 ]; then
                print_message "$YELLOW" "> Server replied: $(head -n 1 "$TMPPATH/$ARCHIVE" | cut -c1-100)"
                print_message "$YELLOW" "> (this usually means the file does not exist for version $version)"
            fi
            rm -f "$TMPPATH/$ARCHIVE"
        fi
    fi
    sleep 1
done

if [ "$DOWNLOAD_SUCCESS" -eq 0 ]; then
    print_message "$YELLOW" "> Possible reasons:"
    print_message "$YELLOW" "  1. No internet connection"
    print_message "$YELLOW" "  2. GitHub repository is unavailable"
    print_message "$YELLOW" "  3. Version $version does not exist"
    print_message "$YELLOW" "  4. File is corrupted on server"
    print_message "$YELLOW" "  5. No CA certificates on this box (see ALLOW_INSECURE in the script header)"
    die "> Complete download failure! (old version was not touched)"
fi

FILE_SIZE=$(wc -c < "$TMPPATH/$ARCHIVE" 2>/dev/null | tr -d ' ')
if [ -z "$FILE_SIZE" ] || [ "$FILE_SIZE" -lt 1024 ]; then
    die "> Downloaded file is too small (${FILE_SIZE:-0} bytes). File may be corrupted! (old version was not touched)"
fi

verify_checksum

# Extract into a separate folder
print_message "$BLUE" "> Extracting files..."
mkdir -p "$EXTRACT_DIR"
tar -xzf "$TMPPATH/$ARCHIVE" -C "$EXTRACT_DIR" >/dev/null 2>&1 \
    || die "> Failed to extract files! Archive may be corrupted. (old version was not touched)"

check_extracted_tree

# ---------------------------------------------------------------
# Now remove the old version, then install the new one
# ---------------------------------------------------------------
echo ""
remove_old_version

print_message "$BLUE" "> Installing plugin..."
umask 022
mkdir -p "$PLUGINPATH"
cd "$EXTRACT_DIR" || die "> Cannot enter extraction folder"

INSTALL_OK=1
if [ -d "$PLUGIN_NAME" ]; then
    cp -rf "$PLUGIN_NAME"/. "$PLUGINPATH"/ >/dev/null 2>&1 && INSTALL_OK=0
elif [ -d "${PLUGIN_NAME}-main" ]; then
    if [ -d "${PLUGIN_NAME}-main/usr" ]; then
        install_usr_tree "${PLUGIN_NAME}-main" && INSTALL_OK=0
    else
        cp -rf "${PLUGIN_NAME}-main"/. "$PLUGINPATH"/ >/dev/null 2>&1 && INSTALL_OK=0
    fi
elif [ -d "usr" ]; then
    install_usr_tree "." && INSTALL_OK=0
else
    LIST="$TMPPATH/filelist.txt"
    find . -type f \( -name "*.py" -o -name "*.pyo" -o -name "*.pyc" -o -name "*.so" \
        -o -name "*.png" -o -name "*.xml" -o -name "*.json" \) > "$LIST"
    if [ -s "$LIST" ]; then
        INSTALL_OK=0
        while read -r f; do
            dest_dir="$PLUGINPATH/$(dirname "$f")"
            mkdir -p "$dest_dir"
            cp -f "$f" "$dest_dir/" >/dev/null 2>&1 || INSTALL_OK=1
        done < "$LIST"
    fi
    [ -d "locale" ] && cp -rf locale "$PLUGINPATH/" >/dev/null 2>&1
fi

# If the archive used a different lib/lib64 layout, relocate it
if [ -z "$(ls -A "$PLUGINPATH" 2>/dev/null)" ]; then
    for d in $OLD_DIRS; do
        if [ "$d" != "$PLUGINPATH" ] && [ -n "$(ls -A "$d" 2>/dev/null)" ]; then
            print_message "$YELLOW" "> Moving plugin from $d to $PLUGINPATH"
            cp -a "$d"/. "$PLUGINPATH"/ >/dev/null 2>&1
            rm -rf "$d"
        fi
    done
fi

# ---------------------------------------------------------------
# Verify installation
# ---------------------------------------------------------------
print_message "$BLUE" "> Verifying installation..."
if [ "$INSTALL_OK" -ne 0 ] || [ -z "$(ls -A "$PLUGINPATH" 2>/dev/null)" ]; then
    die "> Installation failed! Could not copy plugin files."
fi
ENTRY_FOUND=0
for f in plugin.py plugin.pyc plugin.pyo plugin.so; do
    if [ -f "$PLUGINPATH/$f" ]; then
        ENTRY_FOUND=1
        break
    fi
done
if [ "$ENTRY_FOUND" -eq 0 ]; then
    # Some builds keep the entry file in a subfolder: search before failing
    if [ -z "$(find "$PLUGINPATH" -type f \( -name 'plugin.py*' -o -name 'plugin.so' \) 2>/dev/null | head -n 1)" ]; then
        print_message "$YELLOW" "> Files found in $PLUGINPATH:"
        ls -la "$PLUGINPATH" 2>/dev/null | head -n 20
        die "> Installation failed! plugin entry file not found."
    fi
fi

# Ownership and permissions
print_message "$BLUE" "> Setting file permissions..."
chown -R root:root "$PLUGINPATH" >/dev/null 2>&1
chmod -R 755 "$PLUGINPATH" >/dev/null 2>&1
find "$PLUGINPATH" -type f \( -name "*.py" -o -name "*.pyo" -o -name "*.pyc" \) -exec chmod 644 {} \; >/dev/null 2>&1

# Installation finished: no rollback needed anymore
INSTALL_DONE=1
OLD_REMOVED=0

print_message "$BLUE" "> Cleaning temporary files..."
cd / || exit 1
rm -rf "$TMPPATH" >/dev/null 2>&1
TMPPATH=""
sync

# ---------------------------------------------------------------
# Success (NO automatic restart: the user restarts manually)
# ---------------------------------------------------------------
echo ""
print_message "$CYAN"   "==================================================================="
print_message "$GREEN"  "===              Installation Successful!                       ==="
print_message "$YELLOW" "$(printf '===                 MagicPanelMax v%-24s===' "$version")"
print_message "$BLUE"   "===              Downloaded by  >>>>   HAMDY_AHMED               ==="
print_message "$CYAN"   "==================================================================="
echo ""
print_message "$GREEN"  "> Installed to: $PLUGINPATH"
echo ""
print_message "$YELLOW" "###################################################################"
print_message "$YELLOW" "#  IMPORTANT: Enigma2 was NOT restarted automatically.            #"
print_message "$YELLOW" "#  Please restart Enigma2 MANUALLY to activate the plugin:        #"
print_message "$YELLOW" "###################################################################"
print_message "$BLUE"   "  - From the remote: Menu > Standby / Restart > Restart GUI"
print_message "$BLUE"   "  - Or from telnet/SSH:  systemctl restart enigma2"
print_message "$BLUE"   "                   or:   init 4 && sleep 2 && init 3"
echo ""

exit 0
