#!/usr/bin/env bash
# rodney-sandbox-setup: provision a working `rodney` (simonw/rodney) install
# inside a network-sandboxed, container-based dev environment.
#
# Idempotent: safe to run every time a task needs rodney. If a valid install
# is already present it skips straight to the smoke test.
#
# See ../SKILL.md for the design rationale and troubleshooting guide.

set -euo pipefail

RODNEY_COMMIT="a842432246f39775ccb14f0de72565b2c216b5b6"
CHROME_FALLBACK_VERSION="151.0.7922.34"

INSTALL_BIN_DIR="$HOME/.local/bin"
CHROME_DIR="$HOME/.local/share/chrome-for-testing"
CHROME_BIN="$CHROME_DIR/chrome"
RODNEY_BIN="$INSTALL_BIN_DIR/rodney"
PERSIST_FILE="${SANDBOX_PERSISTENT_ENV_FILE:-/etc/sandbox-persistent.sh}"
PERSIST_MARKER="RODNEY_SANDBOX_SETUP_DONE"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
PATCH_FILE="$SKILL_DIR/patches/remove-single-process.patch"

log() { echo "[rodney-sandbox-setup] $*" >&2; }
die() { log "ERREUR: $*"; exit 1; }

already_installed() {
  [ -x "$RODNEY_BIN" ] && [ -x "$CHROME_BIN" ]
}

# --- Preflight: distinguish "blocked by sandbox network policy" from a real
# outage before we waste time on a download that will 403 anyway. ---
check_reachable() {
  local url="$1" tmp status
  tmp="$(mktemp)"
  status="$(curl -s -o "$tmp" -w '%{http_code}' --max-time 10 "$url" 2>/dev/null || echo "000")"
  if [ "$status" = "403" ] && grep -qi "blocked by" "$tmp"; then
    log "  - $url : BLOQUÉ par la politique réseau du sandbox"
    rm -f "$tmp"
    return 1
  elif [ "$status" = "000" ]; then
    log "  - $url : injoignable (DNS/réseau, pas nécessairement une politique explicite)"
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
  return 0
}

preflight_network() {
  log "Vérification de l'accessibilité réseau requise…"
  local ok=0
  check_reachable "https://github.com/simonw/rodney" || ok=1
  check_reachable "https://storage.googleapis.com/chrome-for-testing-public/" || ok=1
  # Non bloquant : source de version dynamique, un repli codé en dur existe si
  # cet hôte est bloqué (observé dans un sandbox précédent).
  check_reachable "https://googlechromelabs.github.io/chrome-for-testing/known-good-versions-with-downloads.json" || true
  if [ "$ok" -ne 0 ]; then
    cat >&2 <<'MSG'
Un ou plusieurs domaines requis (github.com, storage.googleapis.com) sont
bloqués par la politique réseau de ce sandbox. Demandez à l'utilisateur
d'exécuter, SUR L'HÔTE (pas dans le sandbox) :

  sbx policy allow network github.com,storage.googleapis.com

puis relancez ce script.
MSG
    exit 1
  fi
}

# --- Resolve the Chrome for Testing version to install ---
get_chrome_version() {
  local json version
  if json="$(curl -fsS --max-time 15 \
    "https://googlechromelabs.github.io/chrome-for-testing/known-good-versions-with-downloads.json" 2>/dev/null)"; then
    version="$(python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    for v in reversed(data.get("versions", [])):
        downloads = v.get("downloads", {}).get("chrome", [])
        if any(d.get("platform") == "linux64" for d in downloads):
            print(v["version"])
            break
except Exception:
    pass
' <<<"$json")"
    if [ -n "$version" ]; then
      echo "$version"
      return 0
    fi
  fi
  log "Repli sur la version Chrome codée en dur ($CHROME_FALLBACK_VERSION) — l'API de version n'a pas répondu."
  echo "$CHROME_FALLBACK_VERSION"
}

install_chrome() {
  local version="$1" url tmp
  url="https://storage.googleapis.com/chrome-for-testing-public/${version}/linux64/chrome-linux64.zip"
  tmp="$(mktemp -d)"
  log "Téléchargement de Chrome for Testing ${version}…"
  if ! curl -fsSL --max-time 180 -o "$tmp/chrome-linux64.zip" "$url"; then
    rm -rf "$tmp"
    die "téléchargement de Chrome ${version} échoué depuis $url (version invalide, ou build purgé du bucket ?)"
  fi
  unzip -q "$tmp/chrome-linux64.zip" -d "$tmp"
  mkdir -p "$CHROME_DIR"
  rm -rf "${CHROME_DIR:?}"/*
  cp -r "$tmp"/chrome-linux64/* "$CHROME_DIR"/
  chmod +x "$CHROME_BIN"
  rm -rf "$tmp"
}

install_chrome_runtime_deps() {
  local missing
  missing="$(ldd "$CHROME_BIN" 2>/dev/null | awk '/not found/ {print $1}')"
  [ -z "$missing" ] && return 0

  if ! command -v sudo >/dev/null 2>&1; then
    log "AVERTISSEMENT: sudo introuvable — bibliothèques partagées manquantes pour Chrome, installez-les manuellement :"
    log "  $(echo "$missing" | tr '\n' ' ')"
    return 0
  fi

  log "Bibliothèques partagées manquantes pour Chrome : $(echo "$missing" | tr '\n' ' ')"
  log "Installation des paquets apt correspondants…"
  sudo -n apt-get update -qq >/dev/null 2>&1 || true

  # Fast path: the flat list of canonical package names, in one shot.
  local flat_pkgs=(
    libatk1.0-0 libatk-bridge2.0-0 libdbus-1-3 libcups2 libxcb1 libxkbcommon0
    libasound2t64 libgbm1 libx11-6 libxext6 libcairo2 libpango-1.0-0
    libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libatspi2.0-0
    libglib2.0-0 libnspr4 libnss3
  )
  sudo -n apt-get install -y --no-install-recommends "${flat_pkgs[@]}" >/dev/null 2>&1 || true

  missing="$(ldd "$CHROME_BIN" 2>/dev/null | awk '/not found/ {print $1}')"
  if [ -z "$missing" ]; then
    log "Dépendances système de Chrome installées."
    return 0
  fi

  # Fallback: per-library, trying several apt package name variants — covers
  # Ubuntu's "t64" SONAME-transition renaming differing across releases.
  local -A candidates=(
    ["libatk-1.0.so.0"]="libatk1.0-0 libatk1.0-0t64"
    ["libatk-bridge-2.0.so.0"]="libatk-bridge2.0-0 libatk-bridge2.0-0t64"
    ["libdbus-1.so.3"]="libdbus-1-3"
    ["libcups.so.2"]="libcups2 libcups2t64"
    ["libxcb.so.1"]="libxcb1"
    ["libxkbcommon.so.0"]="libxkbcommon0"
    ["libasound.so.2"]="libasound2t64 libasound2"
    ["libgbm.so.1"]="libgbm1"
    ["libX11.so.6"]="libx11-6"
    ["libXext.so.6"]="libxext6"
    ["libcairo.so.2"]="libcairo2"
    ["libpango-1.0.so.0"]="libpango-1.0-0"
    ["libXcomposite.so.1"]="libxcomposite1"
    ["libXdamage.so.1"]="libxdamage1"
    ["libXfixes.so.3"]="libxfixes3"
    ["libXrandr.so.2"]="libxrandr2"
    ["libatspi.so.0"]="libatspi2.0-0 libatspi2.0-0t64"
    ["libglib-2.0.so.0"]="libglib2.0-0 libglib2.0-0t64"
    ["libnspr4.so"]="libnspr4"
    ["libnss3.so"]="libnss3"
  )
  local lib pkg installed
  for lib in $missing; do
    installed=0
    for pkg in ${candidates[$lib]:-}; do
      if sudo -n apt-get install -y --no-install-recommends "$pkg" >/dev/null 2>&1; then
        installed=1
        break
      fi
    done
    [ "$installed" = 1 ] || log "  - aucun paquet apt candidat n'a fonctionné pour $lib"
  done

  missing="$(ldd "$CHROME_BIN" 2>/dev/null | awk '/not found/ {print $1}')"
  if [ -n "$missing" ]; then
    die "bibliothèques partagées encore manquantes après installation apt : $(echo "$missing" | tr '\n' ' '). Installez-les manuellement (nom de paquet selon la distro) puis relancez ce script."
  fi
  log "Dépendances système de Chrome installées."
}

build_rodney() {
  command -v go >/dev/null 2>&1 || die "Go >= 1.21 introuvable (requis pour compiler rodney depuis les sources)."
  local tmp
  tmp="$(mktemp -d)"
  log "Clonage de rodney @ ${RODNEY_COMMIT}…"
  git clone -q https://github.com/simonw/rodney.git "$tmp/rodney"
  (cd "$tmp/rodney" && git checkout -q "$RODNEY_COMMIT")
  log "Application du patch --single-process (voir patches/remove-single-process.patch)…"
  if ! (cd "$tmp/rodney" && git apply "$PATCH_FILE"); then
    rm -rf "$tmp"
    die "le patch ne s'applique plus proprement sur ${RODNEY_COMMIT} — le code source amont de rodney a changé. Inspectez manuellement launcher.New() dans main.go (cmdStart) et mettez à jour patches/remove-single-process.patch."
  fi
  log "Compilation de rodney…"
  (cd "$tmp/rodney" && go build -o rodney .)
  mkdir -p "$INSTALL_BIN_DIR"
  cp "$tmp/rodney/rodney" "$RODNEY_BIN"
  chmod +x "$RODNEY_BIN"
  rm -rf "$tmp"
}

persist_env() {
  if [ -w "$(dirname "$PERSIST_FILE")" ] || [ -w "$PERSIST_FILE" ]; then
    if ! grep -q "$PERSIST_MARKER" "$PERSIST_FILE" 2>/dev/null; then
      cat >> "$PERSIST_FILE" <<EOF

# --- rodney-sandbox-setup skill: persistent Chrome for Testing + rodney PATH ---
# Guarded by a marker variable (not re-appended on every setup.sh run) so
# repeated invocations across sessions/sandboxes never duplicate these lines.
if [ -z "\${${PERSIST_MARKER}:-}" ]; then
  export ROD_CHROME_BIN="$CHROME_BIN"
  export PATH="$INSTALL_BIN_DIR:\$PATH"
  export ${PERSIST_MARKER}=1
fi
EOF
      log "Variables d'environnement persistées dans $PERSIST_FILE"
    fi
  else
    log "AVERTISSEMENT: $PERSIST_FILE non inscriptible — export manuel requis dans cette session:"
    log "  export ROD_CHROME_BIN=$CHROME_BIN"
    log "  export PATH=$INSTALL_BIN_DIR:\$PATH"
  fi
  export ROD_CHROME_BIN="$CHROME_BIN"
  export PATH="$INSTALL_BIN_DIR:$PATH"
}

smoke_test() {
  # A "no external dependency" target (about:blank, data:) doesn't work: this
  # rodney/go-rod build gets "-32000 Cannot navigate to invalid URL" from CDP's
  # Target.createTarget for any non-http(s) scheme — verified empirically, not
  # a configuration issue. example.com is used instead: IANA-reserved for
  # exactly this kind of test, and stable for decades. This stays a valid
  # smoke test even if example.com itself is blocked by this sandbox's network
  # policy: the proxy answers blocked requests with an HTML page rather than
  # failing the TCP/TLS handshake, so navigation still completes end-to-end
  # and still proves Chrome+rodney+the --single-process patch all work —
  # a blocked body is logged as an informational note, not a failure.
  log "Test de bon fonctionnement (navigation réelle vers https://example.com)…"
  local out
  out="$(mktemp)"
  "$RODNEY_BIN" stop >/dev/null 2>&1 || true

  if ! "$RODNEY_BIN" start --insecure >"$out" 2>&1; then
    cat "$out" >&2
    if grep -qi "ERR_CERT_AUTHORITY_INVALID" "$out"; then
      die "démarrage de Chrome échoué : certificat TLS refusé. --insecure aurait dû l'éviter — vérifiez que 'rodney start' a bien reçu le flag."
    elif grep -qi "EOF\|failed to list pages" "$out"; then
      die "démarrage de Chrome échoué (EOF) : régression probable du patch --single-process. Voir SKILL.md § Dépannage."
    else
      die "'rodney start --insecure' a échoué, voir sortie ci-dessus."
    fi
  fi

  if ! "$RODNEY_BIN" open "https://example.com" >"$out" 2>&1; then
    cat "$out" >&2
    "$RODNEY_BIN" stop >/dev/null 2>&1 || true
    die "'rodney open' a échoué, voir sortie ci-dessus."
  fi

  "$RODNEY_BIN" waitload >/dev/null 2>&1 || true
  if "$RODNEY_BIN" text body >"$out" 2>&1 && grep -qi "blocked by" "$out"; then
    log "NOTE: https://example.com est bloqué par la politique réseau de ce sandbox (normal, ça varie d'un sandbox à l'autre) — Chrome/rodney fonctionnent bien, seule la cible de test est injoignable."
  fi
  "$RODNEY_BIN" stop >/dev/null 2>&1 || true
  rm -f "$out"
  log "OK — rodney est opérationnel dans ce sandbox ($RODNEY_BIN, $CHROME_BIN)."
}

main() {
  if already_installed; then
    log "Installation existante détectée — vérification seulement."
  else
    preflight_network
    command -v unzip >/dev/null 2>&1 || die "unzip introuvable (requis pour extraire Chrome for Testing)."
    local version
    version="$(get_chrome_version)"
    log "Version Chrome for Testing retenue : $version"
    install_chrome "$version"
    build_rodney
  fi
  install_chrome_runtime_deps
  persist_env
  smoke_test
}

main "$@"
