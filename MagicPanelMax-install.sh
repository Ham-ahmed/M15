#!/bin/sh

##setup command=wget -q "--no-check-certificate" https://raw.githubusercontent.com/Ham-ahmed/M15/refs/heads/main/MagicPanelMax-install.sh -O - | /bin/sh

######### Only This line to edit with new version ######
version='15.0'
##############################################################

PLUGIN_NAME="MagicPanelMax"
TMPPATH="/tmp/${PLUGIN_NAME}"
BACKUP="/tmp/${PLUGIN_NAME}_backup"
GITHUB_BASE="https://raw.githubusercontent.com/Ham-ahmed/M15/refs/heads/main"
ARCHIVE="${PLUGIN_NAME}_v${version}.tar.gz"

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

OLD_REMOVED=0

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
# Rollback: restore the old version if the new install fails
# ---------------------------------------------------------------
rollback() {
    if [ "$OLD_REMOVED" -eq 1 ] && [ -d "$BACKUP" ]; then
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
        print_message "$GREEN" "> Previous version restored."
    fi
}

die() {
    print_message "$RED" "$1"
    rollback
    cd / 2>/dev/null
    rm -rf "$TMPPATH" "$BACKUP" >/dev/null 2>&1
    exit 1
}

# ---------------------------------------------------------------
# Restart Enigma2
# ---------------------------------------------------------------
restart_enigma2() {
    print_message "$YELLOW" "> Restarting Enigma2..."
    sleep 2
    if command_exists systemctl; then
        systemctl restart enigma2
    elif command_exists init; then
        init 4
        sleep 2
        init 3
    elif command_exists restart; then
        restart
    else
        killall -9 enigma2 >/dev/null 2>&1
        sleep 2
        if command_exists enigma2; then
            enigma2 >/dev/null 2>&1 &
        fi
    fi
    sleep 3
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
        apt-get update >/dev/null 2>&1 && apt-get install "$pkg" -y >/dev/null 2>&1
    else
        command_exists opkg || { print_message "$RED" "> opkg not found!"; return 1; }
        opkg update >/dev/null 2>&1 && opkg install "$pkg" >/dev/null 2>&1
    fi
}

# ---------------------------------------------------------------
# Download with retries (wget, then curl)
# ---------------------------------------------------------------
download_file() {
    url="$1"
    output="$2"
    attempt=1
    while [ "$attempt" -le 3 ]; do
        print_message "$BLUE" "> Download attempt $attempt of 3..."
        rm -f "$output"
        if command_exists wget; then
            wget -q -T 30 --no-check-certificate "$url" -O "$output" >/dev/null 2>&1
            [ -s "$output" ] && return 0
        fi
        if command_exists curl; then
            curl -s --connect-timeout 20 --max-time 60 --insecure "$url" -o "$output" >/dev/null 2>&1
            [ -s "$output" ] && return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
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

    # 2) Remove package registered in the package manager
    for pkg in $OLD_PACKAGES; do
        if check_package "$pkg"; then
            print_message "$YELLOW" "> Removing package: $pkg"
            if [ "$OSTYPE_NAME" = "DreamOs" ]; then
                apt-get remove --purge -y "$pkg" >/dev/null 2>&1
            else
                opkg remove --force-depends "$pkg" >/dev/null 2>&1
            fi
        fi
    done

    # 3) Remove plugin folders (all architectures)
    for d in $OLD_DIRS; do
        [ -d "$d" ] && rm -rf "$d" >/dev/null 2>&1
    done

    OLD_REMOVED=1
    if [ "$i" -eq 0 ]; then
        print_message "$GREEN" "> No old version found. Clean install."
    else
        print_message "$GREEN" "> Old version removed successfully."
    fi
}

# ---------------------------------------------------------------
# Banner & environment detection
# ---------------------------------------------------------------
if [ -f /var/lib/dpkg/status ]; then
    OSTYPE_NAME="DreamOs"
else
    OSTYPE_NAME="Dream"
fi

clear
echo ""
print_message "$CYAN"   "======================================================"
print_message "$YELLOW" "           MagicPanelMax Installer v$version"
print_message "$CYAN"   "======================================================"
echo ""

# Python detection
Packagesix=""
Packagerequests="python-requests"
if command_exists python3; then
    print_message "$GREEN" "> You have Python3 image"
    Packagesix="python3-six"
    Packagerequests="python3-requests"
elif command_exists python2; then
    print_message "$GREEN" "> You have Python2 image"
elif command_exists python; then
    if python --version 2>&1 | grep -q '^Python 3\.'; then
        print_message "$GREEN" "> You have Python3 image"
        Packagesix="python3-six"
        Packagerequests="python3-requests"
    else
        print_message "$GREEN" "> You have Python2 image"
    fi
else
    print_message "$RED" "> Python not found! Please install Python first."
    exit 1
fi

# Fresh temp folder
rm -rf "$TMPPATH" >/dev/null 2>&1
mkdir -p "$TMPPATH" || exit 1
cd "$TMPPATH" || exit 1

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
    if download_file "$url" "$TMPPATH/$ARCHIVE"; then
        if tar -tzf "$TMPPATH/$ARCHIVE" >/dev/null 2>&1; then
            DOWNLOAD_SUCCESS=1
            print_message "$GREEN" "> Download successful and file validated"
            break
        else
            print_message "$YELLOW" "> Downloaded file is not a valid tar.gz archive"
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
    die "> Complete download failure! (old version was not touched)"
fi

FILE_SIZE=$(wc -c < "$TMPPATH/$ARCHIVE" 2>/dev/null | tr -d ' ')
if [ -z "$FILE_SIZE" ] || [ "$FILE_SIZE" -lt 1024 ]; then
    die "> Downloaded file is too small (${FILE_SIZE:-0} bytes). File may be corrupted! (old version was not touched)"
fi

# Extract into a separate folder
print_message "$BLUE" "> Extracting files..."
EXTRACT_DIR="$TMPPATH/extract"
mkdir -p "$EXTRACT_DIR"
tar -xzf "$TMPPATH/$ARCHIVE" -C "$EXTRACT_DIR" >/dev/null 2>&1 \
    || die "> Failed to extract files! Archive may be corrupted. (old version was not touched)"

# ---------------------------------------------------------------
# Now remove the old version, then install the new one
# ---------------------------------------------------------------
echo ""
remove_old_version

print_message "$BLUE" "> Installing plugin..."
mkdir -p "$PLUGINPATH"
cd "$EXTRACT_DIR" || die "> Cannot enter extraction folder"

INSTALL_OK=1
if [ -d "$PLUGIN_NAME" ]; then
    cp -rf "$PLUGIN_NAME"/. "$PLUGINPATH"/ >/dev/null 2>&1 && INSTALL_OK=0
elif [ -d "${PLUGIN_NAME}-main" ]; then
    if [ -d "${PLUGIN_NAME}-main/usr" ]; then
        cp -rf "${PLUGIN_NAME}-main/usr"/. /usr/ >/dev/null 2>&1 && INSTALL_OK=0
    else
        cp -rf "${PLUGIN_NAME}-main"/. "$PLUGINPATH"/ >/dev/null 2>&1 && INSTALL_OK=0
    fi
elif [ -d "usr" ]; then
    cp -rf usr/. /usr/ >/dev/null 2>&1 && INSTALL_OK=0
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
    [ -d "locale" ] && cp -rf locale "$PLUGINPATH/../" >/dev/null 2>&1
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
if ! ls "$PLUGINPATH"/plugin.py "$PLUGINPATH"/plugin.pyc "$PLUGINPATH"/plugin.pyo "$PLUGINPATH"/plugin.so >/dev/null 2>&1; then
    die "> Installation failed! plugin entry file not found."
fi

# Permissions
print_message "$BLUE" "> Setting file permissions..."
chmod -R 755 "$PLUGINPATH" >/dev/null 2>&1
find "$PLUGINPATH" -type f \( -name "*.py" -o -name "*.pyo" -o -name "*.pyc" \) -exec chmod 644 {} \; >/dev/null 2>&1

# Cleanup
print_message "$BLUE" "> Cleaning temporary files..."
cd / || exit 1
rm -rf "$TMPPATH" "$BACKUP" >/dev/null 2>&1
sync

# ---------------------------------------------------------------
# Success
# ---------------------------------------------------------------
echo ""
print_message "$CYAN"   "==================================================================="
print_message "$GREEN"  "===              Installation Successful!                       ==="
print_message "$YELLOW" "$(printf '===                 MagicPanelMax v%-24s===' "$version")"
print_message "$BLUE"   "===              Downloaded by  >>>>   HAMDY_AHMED               ==="
print_message "$CYAN"   "==================================================================="
echo ""
print_message "$YELLOW" "Enigma2 will restart automatically after 5 seconds..."
print_message "$BLUE"   "Press Ctrl+C to cancel"
echo ""

i=5
while [ "$i" -ge 1 ]; do
    printf '%bRestarting in %s seconds...%b\r' "$YELLOW" "$i" "$NC"
    sleep 1
    i=$((i - 1))
done
echo ""

print_message "$GREEN"  "========================================================="
print_message "$YELLOW" "===            Restarting Enigma2                     ==="
print_message "$GREEN"  "========================================================="

restart_enigma2

exit 0
