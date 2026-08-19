#!/usr/bin/env bash
# =============================================================================
#  catsdk 0.1.1 — Cat SDK
#  Installs / detects compilers for eras 1930–2026 (Atari → PS5)
#  Auto-installs libdragon (N64). Bare run = install ALL open toolchains.
# =============================================================================
set -euo pipefail

CATSDK_VERSION="0.1.1"
CATSDK_NAME="catsdk"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Prefer CATSDK_HOME if set (AC OS / prior catsdk), else CATSDK_ROOT, else ~/.catsdk
# Paths with # : > break Make (libdragon/gcc) — force home if unsafe.
_CATSDK_DEFAULT="$HOME/.catsdk"
CATSDK_ROOT="${CATSDK_ROOT:-${CATSDK_HOME:-$_CATSDK_DEFAULT}}"
if [[ "$CATSDK_ROOT" == *'#'* || "$CATSDK_ROOT" == *':/'* || "$CATSDK_ROOT" == *'>'* ]]; then
  printf '%s\n' "[!] CATSDK_ROOT='$CATSDK_ROOT' is unsafe for toolchain builds — using $_CATSDK_DEFAULT" >&2
  CATSDK_ROOT="$_CATSDK_DEFAULT"
fi
export CATSDK_HOME="$CATSDK_ROOT"
CATSDK_BIN="$CATSDK_ROOT/bin"
CATSDK_TOOLCHAINS="$CATSDK_ROOT/toolchains"
CATSDK_ENV="$CATSDK_ROOT/env.sh"
CATSDK_LOG="$CATSDK_ROOT/install.log"
CATSDK_VERSION_FILE="$CATSDK_ROOT/VERSION"
DEVKITPRO="${DEVKITPRO:-/opt/devkitpro}"
INSTALL_FAILURES=0

# ── colors ──────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_CYN=$'\033[36m'; C_DIM=$'\033[2m'
  C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED= C_GRN= C_YEL= C_BLU= C_CYN= C_DIM= C_BLD= C_RST=
fi

log()  { printf '%s\n' "$*" | tee -a "$CATSDK_LOG" >/dev/null; printf '%s\n' "$*"; }
info() { printf "${C_CYN}==>${C_RST} %s\n" "$*" | tee -a "$CATSDK_LOG" >/dev/null; printf "${C_CYN}==>${C_RST} %s\n" "$*"; }
ok()   { printf "${C_GRN}[ok]${C_RST} %s\n" "$*"; }
warn() { printf "${C_YEL}[!]${C_RST} %s\n" "$*"; }
err()  { printf "${C_RED}[err]${C_RST} %s\n" "$*" >&2; }
die()  { err "$*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

banner() {
  cat <<EOF
${C_BLD}${C_CYN}
   _____   ____ ______ _____ ____  __ __
  / ___/  / __ /_  __// ___// __ \\/ //_/
 / /__   / /_/ / / /  \\__ \\/ / / / ,<
 \\___/   \\__,_/ /_/  /____/_/ /_/_/|_|  ${C_RST}${C_BLD}${CATSDK_VERSION}${C_RST}
${C_DIM}  Atari → PS5 · 1930–2026 · libdragon auto · open toolchains${C_RST}

EOF
}

mkdir -p "$CATSDK_ROOT" "$CATSDK_BIN" "$CATSDK_TOOLCHAINS"
: >>"$CATSDK_LOG"
printf '%s\n' "$CATSDK_VERSION" >"$CATSDK_VERSION_FILE"

# ── host auto-detect ────────────────────────────────────────────────────────
detect_host() {
  OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
  ARCH="$(uname -m)"
  case "$ARCH" in
    arm64|aarch64) ARCH_NORM="arm64" ;;
    x86_64|amd64)  ARCH_NORM="x86_64" ;;
    i386|i686)     ARCH_NORM="x86" ;;
    *)             ARCH_NORM="$ARCH" ;;
  esac

  PKG=""
  if have brew; then PKG="brew"
  elif have apt-get; then PKG="apt"
  elif have dnf; then PKG="dnf"
  elif have pacman; then PKG="pacman"
  elif have yum; then PKG="yum"
  elif have apk; then PKG="apk"
  elif have port; then PKG="macports"
  fi

  case "$OS" in
    darwin) HOST="macos" ;;
    linux)  HOST="linux" ;;
    msys*|mingw*|cygwin*) HOST="windows" ;;
    *) HOST="$OS" ;;
  esac

  NPROC="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)"
}

# ── detect already-installed toolchains ─────────────────────────────────────
# Returns path or empty. Sets DETECTED_* globals used by status/env.
detect_toolchains() {
  DETECTED=()

  # Host C
  for c in cc clang gcc; do
    if have "$c"; then DETECTED+=("host-$c:$(command -v "$c")"); break; fi
  done

  # Atari / 6502 / Z80 family
  have dasm      && DETECTED+=("atari2600-dasm:$(command -v dasm)")
  have cl65      && DETECTED+=("cc65:$(command -v cl65)")
  have ca65      && DETECTED+=("ca65:$(command -v ca65)")
  have sdcc      && DETECTED+=("sdcc:$(command -v sdcc)")
  have z88dk-z80asm && DETECTED+=("z88dk:$(command -v z88dk-z80asm)")
  have rgbasm    && DETECTED+=("rgbds:$(command -v rgbasm)")
  have lcc       && DETECTED+=("gbdk-lcc:$(command -v lcc)")
  have wla-6502  && DETECTED+=("wla-dx:$(command -v wla-6502)")
  have vasm6502_oldstyle && DETECTED+=("vasm:$(command -v vasm6502_oldstyle)")
  have llvm-mc   && DETECTED+=("llvm-mos-or-host:$(command -v llvm-mc)")

  # N64 / libdragon
  if [[ -n "${N64_INST:-}" && -x "${N64_INST}/bin/mips64-elf-gcc" ]]; then
    DETECTED+=("libdragon:$N64_INST")
  elif [[ -x "$CATSDK_TOOLCHAINS/libdragon/bin/mips64-elf-gcc" ]]; then
    DETECTED+=("libdragon:$CATSDK_TOOLCHAINS/libdragon")
    export N64_INST="$CATSDK_TOOLCHAINS/libdragon"
  elif have mips64-elf-gcc; then
    DETECTED+=("libdragon-mips:$(command -v mips64-elf-gcc)")
  fi
  have dragon  && DETECTED+=("libdragon-cli:$(command -v dragon)")

  # devkitPro family
  if [[ -d "$DEVKITPRO" ]]; then
    [[ -d "$DEVKITPRO/devkitARM" ]] && DETECTED+=("devkitARM:$DEVKITPRO/devkitARM")
    [[ -d "$DEVKITPRO/devkitPPC" ]] && DETECTED+=("devkitPPC:$DEVKITPRO/devkitPPC")
    [[ -d "$DEVKITPRO/devkitA64" ]] && DETECTED+=("devkitA64:$DEVKITPRO/devkitA64")
    have arm-none-eabi-gcc && DETECTED+=("arm-none-eabi:$(command -v arm-none-eabi-gcc)")
    have powerpc-eabi-gcc  && DETECTED+=("powerpc-eabi:$(command -v powerpc-eabi-gcc)")
    have aarch64-none-elf-gcc && DETECTED+=("aarch64-none-elf:$(command -v aarch64-none-elf-gcc)")
  fi

  # Sega / Dreamcast / PS1–PSP open SDKs
  [[ -d "${KOS_BASE:-}" ]] && DETECTED+=("kallistios:$KOS_BASE")
  [[ -d "${PSN00BSDK_LIBS:-}" ]] && DETECTED+=("psn00b:$PSN00BSDK_LIBS")
  [[ -d "${PS2SDK:-}" ]] && DETECTED+=("ps2sdk:$PS2SDK")
  [[ -d "${PSPDEV:-}" ]] && DETECTED+=("pspdev:$PSPDEV")
  [[ -d "${SGDK_PATH:-$HOME/SGDK}" ]] && DETECTED+=("sgdk:${SGDK_PATH:-$HOME/SGDK}")

  # Official / proprietary (detect only — never download)
  for p in \
    "/opt/ProsperoSDK" \
    "$HOME/ProsperoSDK" \
    "/usr/local/ProsperoSDK" \
    "${SCE_PROSPERO_SDK_DIR:-}" \
    "${PROSPERO_SDK_DIR:-}"; do
    [[ -n "$p" && -d "$p" ]] && DETECTED+=("ps5-prospero:$p") && break
  done
  for p in \
    "/opt/OrbisSDK" \
    "$HOME/OrbisSDK" \
    "${SCE_ORBIS_SDK_DIR:-}" \
    "${ORBIS_SDK_DIR:-}"; do
    [[ -n "$p" && -d "$p" ]] && DETECTED+=("ps4-orbis:$p") && break
  done
  for p in \
    "${SCE_PS3_ROOT:-}" \
    "/usr/local/cell" \
    "$HOME/cell"; do
    [[ -n "$p" && -d "$p" ]] && DETECTED+=("ps3-cell:$p") && break
  done
  for p in \
    "${NX_SDK_ROOT:-}" \
    "${NINTENDO_SDK_ROOT:-}"; do
    [[ -n "$p" && -d "$p" ]] && DETECTED+=("switch-official:$p") && break
  done
  for p in \
    "${GDK:-}" \
    "${GameDK:-}"; do
    [[ -n "$p" && -d "$p" ]] && DETECTED+=("xbox-gdk:$p") && break
  done

  # Modern host / cross
  have rustc && DETECTED+=("rustc:$(command -v rustc)")
  have go    && DETECTED+=("go:$(command -v go)")
  have emcc  && DETECTED+=("emscripten:$(command -v emcc)")
  have zig   && DETECTED+=("zig:$(command -v zig)")
}

# ── package helpers ─────────────────────────────────────────────────────────
pkg_install() {
  local pkgs=("$@")
  [[ ${#pkgs[@]} -eq 0 ]] && return 0
  info "Installing via $PKG: ${pkgs[*]}"
  case "$PKG" in
    brew)
      brew install "${pkgs[@]}" || warn "brew install had issues (some formulae may be unavailable)"
      ;;
    apt)
      sudo apt-get update -qq
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
      ;;
    dnf)  sudo dnf install -y "${pkgs[@]}" ;;
    yum)  sudo yum install -y "${pkgs[@]}" ;;
    pacman) sudo pacman -Sy --noconfirm "${pkgs[@]}" ;;
    apk)  sudo apk add "${pkgs[@]}" ;;
    *) warn "No supported package manager; skip: ${pkgs[*]}" ;;
  esac
}

ensure_basics() {
  info "Ensuring host build basics ($HOST / $ARCH_NORM / pkg=$PKG)"
  case "$PKG" in
    brew)
      pkg_install git curl wget cmake ninja pkg-config python3
      # Apple CLT / Xcode
      if ! xcode-select -p >/dev/null 2>&1; then
        warn "Xcode Command Line Tools missing — run: xcode-select --install"
      fi
      ;;
    apt)
      pkg_install build-essential git curl wget cmake ninja-build pkg-config python3 \
        flex bison texinfo libgmp-dev libmpfr-dev libmpc-dev libisl-dev
      ;;
    dnf|yum)
      pkg_install git curl wget cmake ninja-build gcc gcc-c++ make python3
      ;;
    pacman)
      pkg_install base-devel git curl wget cmake ninja python
      ;;
    *)
      warn "Install git/curl/cmake manually if missing"
      ;;
  esac
}

# ── era catalog (1930–2026) ─────────────────────────────────────────────────
# Open/homebrew installable where possible. Proprietary = detect + docs only.
print_catalog() {
  cat <<'EOF'
catsdk eras (1930–2026) — what we install vs detect

  1930–1959  Theoretical / early computing
             (docs only — no real console compilers)

  1970s      Atari 2600 .......... dasm, batari Basic (brew/git)
             6502 family ......... cc65, vasm, wla-dx

  1980s      NES / Atari 8-bit ... cc65, llvm-mos
             Master System/GG .... sdcc, z88dk
             Genesis/MD .......... SGDK (m68k gcc)
             Game Boy ............ rgbds, GBDK-2020

  1990s      SNES ................ cc65 / wla-dx
             N64 ................. libdragon (auto) ★
             PS1 ................. PSn00bSDK
             Saturn .............. (limited FOSS — detect)
             Dreamcast ........... KallistiOS

  2000s      GBA / NDS ........... devkitARM (devkitPro)
             GC / Wii ............ devkitPPC
             PS2 ................. ps2sdk
             PSP ................. pspdev
             Xbox classic ........ (detect / OpenXDK notes)

  2010s      3DS / Switch ........ devkitA64 / libnx
             PS3 ................. ps3toolchain (FOSS) / CELL detect
             PS4 Orbis ........... DETECT ONLY (Sony licensed SDK)
             Wii U ............... (devkitPro / community)

  2020–2026  PS5 Prospero ........ DETECT ONLY (Sony licensed SDK)
             Xbox GDK ............ DETECT ONLY (Microsoft)
             Switch 2 ............ DETECT ONLY when present
             Host modern ......... clang/gcc, rust, zig, emscripten

★ libdragon is first-class: auto-detect N64_INST or install under ~/.catsdk
EOF
}

# ── installers ──────────────────────────────────────────────────────────────
install_retro_6502() {
  info "Installing 6502 / Atari–NES–SNES toolchain (cc65, dasm, rgbds…)"
  case "$PKG" in
    brew)
      pkg_install cc65 dasm rgbds sdcc
      # optional / may fail on some brew versions
      brew install wla-dx 2>/dev/null || warn "wla-dx not in brew — skip"
      brew install z88dk 2>/dev/null || warn "z88dk not in brew — skip"
      ;;
    apt)
      pkg_install cc65 sdcc z80asm
      ;;
    *)
      warn "Install cc65/rgbds/sdcc via your distro or from source"
      ;;
  esac
}

install_devkitpro() {
  info "Installing / ensuring devkitPro (GBA, NDS, 3DS, Switch, GC, Wii)"
  if [[ -d "$DEVKITPRO" ]] && have dkp-pacman; then
    ok "devkitPro already at $DEVKITPRO"
  else
    case "$HOST" in
      macos|linux)
        info "Fetching devkitPro installer"
        local tmp
        tmp="$(mktemp -d)"
        if [[ "$HOST" == "macos" ]]; then
          curl -fsSL "https://github.com/devkitPro/installer/releases/latest/download/devkitpro-pacman-installer.pkg" \
            -o "$tmp/dkp.pkg" || { warn "Could not download dkp installer"; return 0; }
          warn "Open and install: $tmp/dkp.pkg  (needs GUI/admin)"
          warn "Or: https://devkitpro.org/wiki/Getting_Started"
          open "$tmp/dkp.pkg" 2>/dev/null || true
        else
          curl -fsSL https://apt.devkitpro.org/install-devkitpro-pacman | sudo bash \
            || warn "devkitPro apt install failed — see https://devkitpro.org"
        fi
        ;;
      *)
        warn "Install devkitPro manually: https://devkitpro.org/wiki/Getting_Started"
        return 0
        ;;
    esac
  fi

  if have dkp-pacman || [[ -x "$DEVKITPRO/pacman/bin/dkp-pacman" ]]; then
    local dkp
    dkp="$(command -v dkp-pacman 2>/dev/null || echo "$DEVKITPRO/pacman/bin/dkp-pacman")"
    info "Installing devkitPro packages (ARM/PPC/A64 + libs)"
    sudo "$dkp" -S --noconfirm \
      gba-dev nds-dev 3ds-dev switch-dev gamecube-dev wii-dev wiiu-dev \
      2>/dev/null || warn "dkp-pacman package install incomplete — run manually later"
  else
    warn "dkp-pacman not on PATH yet — re-open shell after installing devkitPro"
  fi
}

install_libdragon() {
  info "libdragon — auto-detect or install"
  detect_toolchains

  if [[ -n "${N64_INST:-}" && -x "${N64_INST}/bin/mips64-elf-gcc" ]]; then
    ok "libdragon toolchain already at N64_INST=$N64_INST"
    return 0
  fi
  if [[ -x "$CATSDK_TOOLCHAINS/libdragon/bin/mips64-elf-gcc" ]]; then
    ok "libdragon already under $CATSDK_TOOLCHAINS/libdragon"
    export N64_INST="$CATSDK_TOOLCHAINS/libdragon"
    return 0
  fi

  local dest="$CATSDK_TOOLCHAINS/libdragon"
  local src="$CATSDK_TOOLCHAINS/src/libdragon"
  mkdir -p "$CATSDK_TOOLCHAINS/src"

  if [[ ! -d "$src/.git" ]]; then
    info "Cloning libdragon…"
    if ! git clone --depth 1 https://github.com/DragonMinded/libdragon.git "$src"; then
      err "git clone libdragon failed"; return 1
    fi
  else
    info "Updating libdragon…"
    git -C "$src" pull --ff-only || warn "libdragon pull failed — using existing tree"
  fi

  info "Building libdragon toolchain into $dest (this takes a while)"
  export N64_INST="$dest"
  mkdir -p "$dest"

  # Official path: tools/build-toolchain.sh when present; else make install-toolchain
  pushd "$src" >/dev/null
  local rc=0
  if [[ -x tools/build-toolchain.sh ]]; then
    ./tools/build-toolchain.sh || rc=$?
  elif [[ -f Makefile ]]; then
    make -j"$NPROC" install-toolchain || rc=$?
    if [[ $rc -eq 0 ]]; then
      make -j"$NPROC" || rc=$?
      make install || warn "libdragon make install had warnings"
    fi
  else
    err "Unrecognized libdragon layout — check $src"
    popd >/dev/null
    return 1
  fi
  popd >/dev/null

  if [[ $rc -ne 0 ]]; then
    err "libdragon toolchain build failed (rc=$rc) — continuing other installs"
    return 1
  fi

  if [[ -x "$dest/bin/mips64-elf-gcc" ]]; then
    ok "libdragon ready: N64_INST=$dest"
    ln -sfn "$dest/bin/"* "$CATSDK_BIN/" 2>/dev/null || true
  else
    warn "Toolchain binary not found — see libdragon docs: https://github.com/DragonMinded/libdragon"
    return 1
  fi
}

install_dreamcast_kos() {
  info "KallistiOS (Dreamcast) — clone skeleton under toolchains"
  local dest="$CATSDK_TOOLCHAINS/KallistiOS"
  if [[ -d "$dest/.git" ]]; then
    ok "KallistiOS already at $dest"
  else
    git clone --depth 1 https://github.com/KallistiOS/KallistiOS.git "$dest" \
      || warn "KOS clone failed"
  fi
  warn "KOS needs a SH-4 toolchain — follow $dest/doc or kos-ports docs after clone"
}

install_ps_open() {
  info "Open PlayStation homebrew SDKs (PS1/PS2/PSP — not official PS4/PS5)"
  local src="$CATSDK_TOOLCHAINS/src"
  mkdir -p "$src"

  if [[ ! -d "$src/PSn00bSDK/.git" ]]; then
    git clone --depth 1 https://github.com/Lameguy64/PSn00bSDK.git "$src/PSn00bSDK" \
      || warn "PSn00bSDK clone failed"
  else
    ok "PSn00bSDK tree present"
  fi

  if [[ ! -d "$src/ps2sdk/.git" ]]; then
    git clone --depth 1 https://github.com/ps2dev/ps2sdk.git "$src/ps2sdk" \
      || warn "ps2sdk clone failed"
  else
    ok "ps2sdk tree present"
  fi

  if [[ ! -d "$src/pspdev/.git" ]]; then
    git clone --depth 1 https://github.com/pspdev/pspdev.git "$src/pspdev" \
      || warn "pspdev clone failed"
  else
    ok "pspdev tree present"
  fi

  warn "PS1–PSP: build each SDK per its README under $src/{PSn00bSDK,ps2sdk,pspdev}"
  warn "PS4 Orbis / PS5 Prospero: catsdk will DETECT licensed SDKs only — never redistributes them"
}

install_modern_host() {
  info "Modern host compilers (2020–2026)"
  case "$PKG" in
    brew)
      pkg_install llvm
      brew install rust 2>/dev/null || true
      brew install zig 2>/dev/null || true
      brew install emscripten 2>/dev/null || warn "emscripten optional — skip if unavailable"
      ;;
    apt)
      pkg_install clang llvm rustc
      ;;
    *)
      warn "Install clang/rust/zig via your package manager"
      ;;
  esac
}

install_sgdk() {
  info "SGDK (Sega Genesis / Mega Drive)"
  local dest="$CATSDK_TOOLCHAINS/SGDK"
  if [[ -d "$dest/.git" ]]; then
    ok "SGDK at $dest"
  else
    git clone --depth 1 https://github.com/Stephane-D/SGDK.git "$dest" \
      || warn "SGDK clone failed"
  fi
  warn "SGDK: set SGDK_PATH=$dest and install a m68k-elf gcc (see SGDK wiki)"
}

# ── env file ────────────────────────────────────────────────────────────────
write_env() {
  detect_toolchains
  local n64="${N64_INST:-$CATSDK_TOOLCHAINS/libdragon}"
  cat >"$CATSDK_ENV" <<EOF
# Generated by catsdk $CATSDK_VERSION — $(date -u +%Y-%m-%dT%H:%MZ)
# Source:  source "$CATSDK_ENV"
export CATSDK_VERSION="$CATSDK_VERSION"
export CATSDK_HOME="$CATSDK_ROOT"
export CATSDK_ROOT="$CATSDK_ROOT"
export CATSDK_BIN="$CATSDK_BIN"
export PATH="\$CATSDK_BIN:\$PATH"

# libdragon / N64
export N64_INST="\${N64_INST:-$n64}"
[[ -d "\$N64_INST/bin" ]] && export PATH="\$N64_INST/bin:\$PATH"

# devkitPro
export DEVKITPRO="\${DEVKITPRO:-$DEVKITPRO}"
export DEVKITARM="\$DEVKITPRO/devkitARM"
export DEVKITPPC="\$DEVKITPRO/devkitPPC"
[[ -d "\$DEVKITPRO/devkitA64" ]] && export DEVKITA64="\$DEVKITPRO/devkitA64"
[[ -d "\$DEVKITPRO/tools/bin" ]] && export PATH="\$DEVKITPRO/tools/bin:\$PATH"
[[ -d "\$DEVKITARM/bin" ]] && export PATH="\$DEVKITARM/bin:\$PATH"
[[ -d "\$DEVKITPPC/bin" ]] && export PATH="\$DEVKITPPC/bin:\$PATH"
[[ -d "\${DEVKITA64:-}/bin" ]] && export PATH="\$DEVKITA64/bin:\$PATH"

# Sega / DC / PS open
export SGDK_PATH="\${SGDK_PATH:-$CATSDK_TOOLCHAINS/SGDK}"
export KOS_BASE="\${KOS_BASE:-$CATSDK_TOOLCHAINS/KallistiOS}"

# Official SDKs — set these yourself after installing licensed tools
# export SCE_PROSPERO_SDK_DIR=...   # PS5
# export SCE_ORBIS_SDK_DIR=...      # PS4
# export SCE_PS3_ROOT=...           # PS3
# export NINTENDO_SDK_ROOT=...      # Switch official
# export GDK=...                    # Xbox GDK
EOF
  ok "Wrote $CATSDK_ENV"
}

# ── status / doctor ─────────────────────────────────────────────────────────
cmd_status() {
  detect_host
  detect_toolchains
  printf "\n${C_BLD}%s %s${C_RST}\n" "$CATSDK_NAME" "$CATSDK_VERSION"
  printf "  host:  %s %s (%s)\n" "$HOST" "$ARCH_NORM" "$(uname -srm)"
  printf "  pkg:   %s\n" "${PKG:-none}"
  printf "  root:  %s\n" "$CATSDK_ROOT"
  printf "\n${C_BLD}Detected toolchains${C_RST} (%d)\n" "${#DETECTED[@]}"
  if [[ ${#DETECTED[@]} -eq 0 ]]; then
    warn "None found — run: $0 install"
  else
    local e name path
    for e in "${DETECTED[@]}"; do
      name="${e%%:*}"
      path="${e#*:}"
      printf "  ${C_GRN}%-22s${C_RST} %s\n" "$name" "$path"
    done
  fi
  printf "\n"
  print_catalog
}

cmd_doctor() {
  cmd_status
  info "Doctor checks"
  have git || warn "git missing"
  have curl || have wget || warn "curl/wget missing"
  have cmake || warn "cmake missing"
  [[ "$HOST" == "macos" ]] && { xcode-select -p >/dev/null 2>&1 || warn "Xcode CLT missing"; }
  [[ -f "$CATSDK_ENV" ]] && ok "env file present" || warn "no env yet — run install"
  # libdragon specific
  if [[ -n "${N64_INST:-}" ]]; then
    [[ -x "$N64_INST/bin/mips64-elf-gcc" ]] && ok "mips64-elf-gcc OK" \
      || warn "N64_INST set but mips64-elf-gcc missing"
  else
    warn "N64_INST unset — libdragon not active in this shell"
  fi
}

# Run a step; never abort the whole install on one failure.
run_step() {
  local name="$1"; shift
  info "── step: $name"
  set +e
  "$@"
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    INSTALL_FAILURES=$((INSTALL_FAILURES + 1))
    warn "step failed: $name (rc=$rc) — continuing"
  else
    ok "step ok: $name"
  fi
}

# ── install profiles ────────────────────────────────────────────────────────
cmd_install() {
  detect_host
  local profile="${1:-all}"
  INSTALL_FAILURES=0
  banner
  info "catsdk ${CATSDK_VERSION} install profile=$profile on $HOST/$ARCH_NORM"
  info "root=$CATSDK_ROOT  (CATSDK_HOME=$CATSDK_HOME)"
  ensure_basics
  case "$profile" in
    all)
      # Full 1930–2026 open stack: Atari/6502 → N64/libdragon → Nintendo → Sega/DC → PS open → modern
      run_step retro        install_retro_6502
      run_step libdragon    install_libdragon
      run_step devkitpro    install_devkitpro
      run_step sgdk         install_sgdk
      run_step dreamcast    install_dreamcast_kos
      run_step playstation  install_ps_open
      run_step modern       install_modern_host
      ;;
    retro|atari|6502) run_step retro install_retro_6502 ;;
    libdragon|n64)    run_step libdragon install_libdragon ;;
    dkp|nintendo)     run_step devkitpro install_devkitpro ;;
    sega)
      run_step sgdk install_sgdk
      run_step dreamcast install_dreamcast_kos
      ;;
    playstation|ps)   run_step playstation install_ps_open ;;
    modern)           run_step modern install_modern_host ;;
    *)
      die "Unknown profile: $profile (all|retro|libdragon|dkp|sega|playstation|modern)"
      ;;
  esac
  printf '%s\n' "$CATSDK_VERSION" >"$CATSDK_VERSION_FILE"
  # Convenience launcher on PATH via ~/.catsdk/bin
  ln -sfn "$SCRIPT_DIR/catsdk.sh" "$CATSDK_BIN/catsdk" 2>/dev/null || true
  write_env
  if [[ $INSTALL_FAILURES -gt 0 ]]; then
    warn "catsdk ${CATSDK_VERSION}: finished with $INSTALL_FAILURES failed step(s)."
    warn "Activate: source $CATSDK_ENV"
  else
    ok "catsdk ${CATSDK_VERSION} done. Activate:  source $CATSDK_ENV"
  fi
  cmd_status
}

cmd_detect() {
  detect_host
  detect_toolchains
  # machine-readable
  printf "host=%s arch=%s pkg=%s root=%s\n" "$HOST" "$ARCH_NORM" "${PKG:-none}" "$CATSDK_ROOT"
  local e
  for e in "${DETECTED[@]+"${DETECTED[@]}"}"; do
    printf "toolchain=%s\n" "$e"
  done
}

usage() {
  banner
  cat <<EOF
${C_BLD}catsdk${C_RST} ${CATSDK_VERSION} — Atari→PS5 + libdragon (1930–2026)

Usage:  $0 [command] [args]

  (no args)          ${C_BLD}AUTO-INSTALL ALL${C_RST} compilers/toolchains + libdragon

Commands:
  install [profile]  Install toolchains (default: all)
                     profiles: all retro libdragon dkp sega playstation modern
  detect             Auto-detect host + toolchains (machine-readable)
  status             Human status + era catalog (1930–2026)
  doctor             status + dependency checks
  env                Write/refresh $CATSDK_ENV
  catalog            Print era → compiler map
  version            Print version
  help               This help

Env:
  CATSDK_HOME / CATSDK_ROOT   install prefix (default: ~/.catsdk)
  N64_INST                    libdragon prefix (auto-detect / set by install)
  DEVKITPRO                   devkitPro root (default: /opt/devkitpro)

Examples:
  ./catsdk.sh                 # install everything (0.1.1 default)
  ./catsdk.sh install libdragon
  ./catsdk.sh detect
  source ~/.catsdk/env.sh
EOF
}

# ── main ────────────────────────────────────────────────────────────────────
main() {
  detect_host
  # Bare run → install ALL compilers (Atari→PS5 + libdragon)
  if [[ $# -eq 0 ]]; then
    cmd_install all
    return
  fi
  local cmd="$1"
  shift || true
  case "$cmd" in
    install)  cmd_install "${1:-all}" ;;
    detect)   cmd_detect ;;
    status)   banner; cmd_status ;;
    doctor)   banner; cmd_doctor ;;
    env)      write_env ;;
    catalog)  print_catalog ;;
    version|-V|--version) printf '%s %s\n' "$CATSDK_NAME" "$CATSDK_VERSION" ;;
    help|-h|--help) usage ;;
    *) err "Unknown command: $cmd"; usage; exit 1 ;;
  esac
}

main "$@"
