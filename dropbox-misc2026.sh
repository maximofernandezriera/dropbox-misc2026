#!/bin/bash
# dropbox-misc2026.sh
# Reinstala Dropbox en Debian 13 + GNOME (capa OMADEB) dejando únicamente
# ~/Dropbox/misc2026 sincronizada, con icono de notificación en la barra
# superior (AppIndicator) y soporte de rollback completo.
#
# Uso:
#   ./dropbox-misc2026.sh              Instalación completa
#   ./dropbox-misc2026.sh --rollback   Deshace los cambios (restaura backup)
#   ./dropbox-misc2026.sh --status     Verificación del estado actual
#   ./dropbox-misc2026.sh --dry-run    Muestra los pasos sin ejecutarlos
#
# Autonomía: si sudo no está cacheado, exporta SUDO_PASS antes de lanzar.

set -euo pipefail
IFS=$'\n\t'

KEEP_FOLDER="misc2026"
DROPBOX_DIR="$HOME/Dropbox"
STATE_DIR="$HOME/.local/state/dropbox-misc2026"
BACKUP_ROOT="$STATE_DIR/backups"
LOG_DIR="$STATE_DIR/logs"
APPINDICATOR_UUID="appindicatorsupport@rgcjonas.gmail.com"
DROPBOX_PKG="nautilus-dropbox"
DIST_URL="https://www.dropbox.com/download?plat=lnx.x86_64"
DAEMON_WAIT_S=90
ENUM_WAIT_S=600
SETTLE_WAIT_S=900

MODE="install"
USE_BACKUP=""
[[ "${1:-}" == "--rollback" ]] && MODE="rollback"
[[ "${1:-}" == "--status" ]] && MODE="status"
[[ "${1:-}" == "--dry-run" ]] && MODE="dry-run"
[[ "${1:-}" == "--use-backup" ]] && USE_BACKUP="${2:-}"

mkdir -p "$BACKUP_ROOT" "$LOG_DIR"
LOG_FILE="$LOG_DIR/$(date +%Y%m%d-%H%M%S)-$MODE.log"
exec > >(tee -a "$LOG_FILE") 2>&1

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { log "OK   $*"; }
warn() { log "WARN $*"; }
die()  { log "FAIL $*"; exit 1; }
run()  { local s; s=$(printf '%q ' "$@"); if [[ $MODE == "dry-run" ]]; then log "DRY  $s"; else log "RUN  $s"; "$@"; fi; }

as_root() {
  if (( EUID == 0 )); then "$@"; return; fi
  if sudo -n true 2>/dev/null; then sudo -n "$@"; return; fi
  [[ -n "${SUDO_PASS:-}" ]] || die "sudo requiere contraseña: exporta SUDO_PASS"
  printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"
}

notify() {
  if command -v omadeb-notification-send >/dev/null; then
    omadeb-notification-send "Dropbox misc2026" "$1" || true
  fi
}

backup_dir() {
  local latest="$BACKUP_ROOT/latest"
  if [[ -L $latest && -e $latest ]]; then readlink -f "$latest"; return; fi
  ls -1dt "$BACKUP_ROOT"/20*/ 2>/dev/null | head -1 | sed 's:/$::'
}

manifest_put() {
  [[ $MODE == "dry-run" ]] && return 0
  printf '%s\n' "$*" >> "$MANIFEST"
}

daemon_running() { pgrep -f "$HOME/.dropbox-dist/.*/dropbox" >/dev/null 2>&1; }

wipe_dir() {
  [[ -e $1 ]] || return 0
  chmod -R u+w "$1" 2>/dev/null || true
  rm -rf "$1"
}

stop_daemon() {
  daemon_running || return 0
  if [[ $MODE == "dry-run" ]]; then log "DRY  detendría el daemon"; return; fi
  dropbox_cli stop >/dev/null
  sleep 2
  daemon_running && pkill -f "$HOME/.dropbox-dist" || true
  sleep 1
}

dropbox_cli() { dropbox "$@" 2>/dev/null | grep -v DeprecationWarning || true; }

wait_for_daemon() {
  local waited=0
  until daemon_running; do
    (( waited >= DAEMON_WAIT_S )) && return 1
    sleep 3; (( waited += 3 ))
  done
  return 0
}

wait_for_cli() {
  local waited=0 st
  until
    st=$(dropbox_cli status)
    [[ -n $st ]] && ! grep -qiE "isn't running|not running|no se est" <<< "$st"
  do
    (( waited >= DAEMON_WAIT_S )) && return 1
    sleep 3; (( waited += 3 ))
  done
  return 0
}

linked() { [[ -f $HOME/.dropbox/info.json ]]; }

# Si el daemon queda sin enlazar (credenciales restauradas rotadas), abre la
# URL de vinculación en el navegador y espera a que el enlace se complete.
ensure_linked() {
  linked && return 0
  local waited=0 st url
  while (( waited < 600 )); do
    linked && { ok "Cuenta enlazada"; break; }
    st=$(dropbox_cli status)
    url=$(grep -o 'https://[^ ]*cli_link_nonce[^ ]*' <<< "$st" | head -1)
    if [[ -n $url && ! -f /tmp/.dbx-link-opened ]]; then
      warn "Dropbox necesita vincular la cuenta: abre el navegador y confirma"
      warn "$url"
      xdg-open "$url" >/dev/null 2>&1 || true
      notify "Confirma la vinculación de Dropbox en el navegador"
      touch /tmp/.dbx-link-opened
    fi
    sleep 10; (( waited += 10 ))
  done
  rm -f /tmp/.dbx-link-opened
  linked || die "cuenta no enlazada tras 10 min; ejecuta la URL de vinculación"
  # Snapshot de credenciales válidas para futuros rollbacks.
  cp -a "$HOME/.dropbox" "$BACKUP_DIR/.dropbox-postlink" 2>/dev/null || true
}

# --- fases ----------------------------------------------------------------

phase_backup() {
  log "== Fase 1: backup previo =="
  BACKUP_DIR="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
  MANIFEST="$BACKUP_DIR/manifest.txt"
  if [[ $MODE != "dry-run" ]]; then mkdir -p "$BACKUP_DIR"; fi
  manifest_put "mode=install"
  manifest_put "date=$(date -Is)"

  stop_daemon

  for src in "$HOME/.dropbox" "$HOME/.dropbox-dist" "$DROPBOX_DIR"; do
    [[ -e $src ]] || continue
    log "Copiando $src → $BACKUP_DIR/"
    run cp -a "$src" "$BACKUP_DIR/"
  done
  [[ -e "$HOME/.config/autostart/dropbox.desktop" ]] && \
    run cp -a "$HOME/.config/autostart/dropbox.desktop" "$BACKUP_DIR/autostart-dropbox.desktop"

  dpkg -l | awk '/dropbox/ && /^ii/ {print $2"="$3}' | while read -r l; do manifest_put "pkg:$l"; done
  gnome-extensions list --enabled | while read -r e; do manifest_put "ext:$e"; done
  [[ -d $DROPBOX_DIR ]] && ls -1A "$DROPBOX_DIR" | while read -r d; do manifest_put "top:$d"; done
  [[ -d "$DROPBOX_DIR/$KEEP_FOLDER/.git" ]] && manifest_put "git:$DROPBOX_DIR/$KEEP_FOLDER"

  if [[ $MODE != "dry-run" ]]; then
    ln -sfn "$BACKUP_DIR" "$BACKUP_ROOT/latest"
    ok "Backup en $BACKUP_DIR ($(du -sh "$BACKUP_DIR" | cut -f1))"
  fi
}

phase_uninstall() {
  log "== Fase 2: desinstalación de Dropbox y extensiones =="
  stop_daemon

  if dpkg -s "$DROPBOX_PKG" >/dev/null 2>&1; then
    run as_root env DEBIAN_FRONTEND=noninteractive apt-get purge -y "$DROPBOX_PKG"
    run as_root apt-get autoremove -y
  fi
  for ext in $(ls "$HOME/.local/share/gnome-shell/extensions" 2>/dev/null | grep -i dropbox || true); do
    run gnome-extensions uninstall "$ext"
  done
  run wipe_dir "$HOME/.dropbox"
  run wipe_dir "$HOME/.dropbox-dist"
  run wipe_dir "$DROPBOX_DIR"
  rm -f "$HOME/.config/autostart/dropbox.desktop" 2>/dev/null || true
  ok "Dropbox desinstalado"
}

phase_install() {
  log "== Fase 3: instalación =="
  run as_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq
  run as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$DROPBOX_PKG"

  log "Descargando daemon oficial → ~/.dropbox-dist"
  if [[ $MODE != "dry-run" ]]; then
    curl -fsSL "$DIST_URL" -o /tmp/dropbox-dist.tgz
    tar -xzf /tmp/dropbox-dist.tgz -C "$HOME"
    rm -f /tmp/dropbox-dist.tgz
    [[ -x $HOME/.dropbox-dist/dropboxd ]] || die "daemon no encontrado tras extracción"
  fi

  log "Restaurando enlace de cuenta (~/.dropbox)"
  run cp -a "$BACKUP_DIR/.dropbox" "$HOME/.dropbox"
  run dropbox start
  if [[ $MODE == "dry-run" ]]; then return; fi
  wait_for_daemon || die "el daemon no arrancó en ${DAEMON_WAIT_S}s"
  wait_for_cli || die "el CLI no responde en ${DAEMON_WAIT_S}s"
  ok "Daemon activo: $(dropbox_cli status | head -1)"

  ensure_linked
}

phase_selective_sync() {
  log "== Fase 4: sincronización selectiva (solo $KEEP_FOLDER) =="
  [[ $MODE == "dry-run" ]] && { log "DRY  excluiría todo excepto $KEEP_FOLDER"; return; }

  declare -A excluded=()
  local current left st waited=0 stable=0
  local known_count
  known_count=$(grep -c '^top:' "$MANIFEST" || true)
  (( known_count > 0 )) && (( known_count -= 1 ))  # menos misc2026

  # El daemon exige que la carpeta exista localmente para aceptar la exclusión,
  # así que primero espera a que termine la indexación inicial.
  while (( waited < ENUM_WAIT_S )); do
    st=$(dropbox_cli status | head -1)
    grep -qiE "índice|index|starting|iniciando|conectando" <<< "$st" || break
    sleep 10; (( waited += 10 ))
  done
  log "Indexación terminada (${waited}s): $st"

  waited=0
  while (( waited < ENUM_WAIT_S )); do
    mapfile -t current < <(ls -1A "$DROPBOX_DIR" 2>/dev/null | grep -v '^\.' || true)
    for d in "${current[@]}"; do
      [[ $d == "$KEEP_FOLDER" || -n ${excluded[$d]:-} ]] && continue
      [[ -d "$DROPBOX_DIR/$d" ]] || continue
      if dropbox_cli exclude add "$DROPBOX_DIR/$d" | grep -q "Excluded"; then
        excluded[$d]=1
        log "Excluida: $d"
      else
        warn "no se pudo excluir: $d"
      fi
    done
    left=$(ls -1A "$DROPBOX_DIR" 2>/dev/null | grep -v '^\.' | grep -vx "$KEEP_FOLDER" || true)
    [[ -z $left && ${#excluded[@]} -ge $known_count ]] && break
    if [[ -z $left ]]; then (( stable += 1 )); else stable=0; fi
    (( stable >= 12 )) && break
    sleep 10; (( waited += 10 ))
  done
  manifest_put "excluded=$(printf '%s|' "${!excluded[@]}")"
  ok "Carpetas excluidas: ${#excluded[@]} (tras ${waited}s)"

  log "Esperando a que $KEEP_FOLDER quede al día…"
  waited=0
  while (( waited < SETTLE_WAIT_S )); do
    local st; st="$(dropbox_cli status | head -1)"
    if dropbox_cli filestatus "$DROPBOX_DIR/$KEEP_FOLDER" 2>/dev/null | grep -qiE "up to date|actualizado"; then
      ok "$KEEP_FOLDER sincronizada"; break
    fi
    [[ $st =~ (Up.to.date|Actualizado|Idle) ]] && { ok "Daemon al día"; break; }
    sleep 15; (( waited += 15 ))
  done
}

phase_tray() {
  log "== Fase 5: icono de notificación en la barra superior =="
  if ! gnome-extensions list | grep -qx "$APPINDICATOR_UUID"; then
    run as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y gnome-shell-extension-appindicator || true
  fi
  if ! gnome-extensions list --enabled | grep -qx "$APPINDICATOR_UUID"; then
    run gnome-extensions enable "$APPINDICATOR_UUID"
    warn "extensión AppIndicator habilitada (puede requerir reinicio de sesión)"
  fi
  ok "AppIndicator activo"

  [[ $MODE == "dry-run" ]] && return
  local items waited=0
  while (( waited < 120 )); do
    items=$(gdbus call --session \
      --dest org.kde.StatusNotifierWatcher \
      --object-path /StatusNotifierWatcher \
      --method org.freedesktop.DBus.Properties.Get \
      org.kde.StatusNotifierWatcher RegisteredStatusNotifierItems 2>/dev/null || true)
    [[ $items =~ [Dd]ropbox ]] && { ok "Dropbox registrado en la bandeja del sistema"; return; }
    sleep 5; (( waited += 5 ))
  done
  warn "no se detectó el icono en StatusNotifierWatcher (puede tardar tras el login)"
}

phase_git() {
  log "== Fase 6: git init en $KEEP_FOLDER =="
  local target="$DROPBOX_DIR/$KEEP_FOLDER"
  [[ -d $target ]] || run mkdir -p "$target"
  if [[ ! -d $target/.git ]]; then
    run git -C "$target" init -q
    if [[ $MODE != "dry-run" ]] && ! grep -qx '.dropbox\*' "$target/.gitignore" 2>/dev/null; then
      printf '.dropbox*\n' >> "$target/.gitignore"
    fi
    run git -C "$target" add -A
    run git -C "$target" commit -qm "Estado inicial tras reinstalación selectiva" || true
  fi
  ok "Repositorio git en $target"
}

phase_verify() {
  log "== Verificación =="
  local fail=0
  daemon_running && ok "daemon activo" || { warn "daemon NO activo"; fail=1; }
  if [[ -d $DROPBOX_DIR ]]; then
    local others nfiles=0 e
    others=$(
      while IFS= read -r e; do
        [[ -d $DROPBOX_DIR/$e ]] && printf '%s\n' "$e"
      done < <(ls -1A "$DROPBOX_DIR" | grep -v '^\.' | grep -vx "$KEEP_FOLDER" || true)
    )
    while IFS= read -r e; do
      [[ -f $DROPBOX_DIR/$e ]] && (( nfiles += 1 ))
    done < <(ls -1A "$DROPBOX_DIR" | grep -v '^\.' || true)
    if [[ -n $others ]]; then warn "quedan carpetas locales: $(printf '%s ' $others)"; fail=1
    else ok "solo $KEEP_FOLDER está presente localmente"; fi
    if (( nfiles > 0 )); then
      log "INFO $nfiles archivos sueltos en la raíz (Dropbox no permite excluir archivos, solo carpetas)"
    fi
  fi
  [[ -d "$DROPBOX_DIR/$KEEP_FOLDER/.git" ]] && ok "git repo presente" || { warn "sin repo git"; fail=1; }
  gnome-extensions list --enabled | grep -qx "$APPINDICATOR_UUID" \
    && ok "AppIndicator habilitado" || { warn "AppIndicator NO habilitado"; fail=1; }
  dropbox_cli status | head -1 | sed 's/^/     status: /'
  (( fail == 0 ))
}

do_rollback() {
  local b; b=$(backup_dir)
  [[ -n $b && -f $b/manifest.txt ]] || die "no hay backup para rollback"
  log "== Rollback desde $b =="

  MODE="install"  # stop_daemon y run deben actuar en rollback
  stop_daemon

  dpkg -s "$DROPBOX_PKG" >/dev/null 2>&1 || \
    as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$DROPBOX_PKG"

  # Solo repone credenciales si el enlace actual está roto: restaurar un
  # .dropbox antiguo revoca la sesión (Dropbox rota host.db al arrancar).
  if ! linked; then
    rm -rf "$HOME/.dropbox" "$HOME/.dropbox-dist"
    if [[ -d $b/.dropbox-postlink ]]; then
      cp -a "$b/.dropbox-postlink" "$HOME/.dropbox"
    else
      cp -a "$b/.dropbox" "$HOME/.dropbox" 2>/dev/null || warn "sin backup de .dropbox"
    fi
    cp -a "$b/.dropbox-dist" "$HOME/.dropbox-dist" 2>/dev/null || warn "sin backup de .dropbox-dist"
  fi
  [[ -f $b/autostart-dropbox.desktop ]] && \
    cp -a "$b/autostart-dropbox.desktop" "$HOME/.config/autostart/dropbox.desktop"

  # Repone la copia local antes de arrancar: el daemon valida hashes y evita
  # volver a descargar el contenido idéntico.
  if [[ -d $b/Dropbox ]]; then
    mkdir -p "$DROPBOX_DIR"
    cp -an "$b/Dropbox/." "$DROPBOX_DIR/" 2>/dev/null || true
  fi
  grep -q '^git:' "$b/manifest.txt" || rm -rf "$DROPBOX_DIR/$KEEP_FOLDER/.git"

  daemon_running || dropbox start
  wait_for_daemon || die "daemon no arrancó en rollback"
  wait_for_cli || true
  ensure_linked

  # Quita todas las exclusiones para resincronizar la cuenta completa.
  local ex
  dropbox_cli exclude | tail -n +2 | while IFS= read -r ex; do
    [[ -z $ex ]] && continue
    dropbox_cli exclude remove "$DROPBOX_DIR/$ex" >/dev/null || true
  done
  gnome-extensions enable "$APPINDICATOR_UUID" 2>/dev/null || true
  ok "Rollback completado; el daemon vuelve a sincronizar la cuenta completa"
}

# --- main -----------------------------------------------------------------

case $MODE in
  status)
    phase_verify && exit 0 || exit 1 ;;
  rollback)
    do_rollback; phase_verify || true; exit 0 ;;
  install|dry-run)
    notify "Iniciando reinstalación selectiva"
    if [[ -n $USE_BACKUP ]]; then
      BACKUP_DIR="$(readlink -f "$USE_BACKUP")"
      MANIFEST="$BACKUP_DIR/manifest.txt"
      [[ -f $MANIFEST ]] || die "backup inválido: $USE_BACKUP"
      log "Reanudando con backup existente: $BACKUP_DIR"
    else
      [[ $MODE == "dry-run" ]] && BACKUP_DIR="$BACKUP_ROOT/dry-run" && MANIFEST=/dev/null
      phase_backup
    fi
    phase_uninstall
    phase_install
    phase_selective_sync
    phase_tray
    phase_git
    [[ $MODE == "dry-run" ]] && { ok "Dry-run terminado. Log: $LOG_FILE"; exit 0; }
    phase_verify || die "verificación con avisos: revisa $LOG_FILE"
    notify "Instalación completada: solo $KEEP_FOLDER sincronizada"
    ok "Terminado. Log: $LOG_FILE"
    ;;
esac
