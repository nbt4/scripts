#!/usr/bin/env bash
# =============================================================================
#  harden-ssh.sh — SSH Hardening Script  v3.0
#  - Überprüft vorhandene normale Benutzer, legt ggf. neuen an
#  - Deaktiviert Passwort-Login (nur Key-Auth)
#  - Deaktiviert Root-Login via SSH
#  - Backup der sshd_config
# =============================================================================

set -euo pipefail

SSHD_CONFIG="/etc/ssh/sshd_config"
BACKUP="${SSHD_CONFIG}.bak.$(date +%Y%m%d_%H%M%S)"

# Tracking-Variablen
NEW_USER_CREATED=""
TARGET_USER=""
ADDED=0
KEY_CHOICE=""
SUDO_GROUP=""
ADD_SUDO="n"
USER_ACTION=""

# Erfolgs-Tracking
CHECKS_TOTAL=0
CHECKS_OK=0
WARNINGS=()

# =============================================================================
#  FARBEN & SYMBOLE
# =============================================================================
if [[ -t 1 ]]; then
  RESET="\033[0m"; BOLD="\033[1m"; DIM="\033[2m"
  RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[0;33m"
  CYAN="\033[0;36m"; WHITE="\033[1;37m"; BLUE="\033[0;34m"
  MAGENTA="\033[0;35m"; BG_GREEN="\033[42m"; BG_RED="\033[41m"
else
  RESET="" BOLD="" DIM="" RED="" GREEN="" YELLOW=""
  CYAN="" WHITE="" BLUE="" MAGENTA="" BG_GREEN="" BG_RED=""
fi

IC_OK="${GREEN}✔${RESET}"
IC_WARN="${YELLOW}⚠${RESET}"
IC_ERR="${RED}✖${RESET}"
IC_INFO="${CYAN}›${RESET}"
IC_CHECK="${CYAN}◆${RESET}"
IC_NEW="${MAGENTA}+${RESET}"
IC_SKIP="${DIM}─${RESET}"
IC_CHG="${YELLOW}~${RESET}"

# =============================================================================
#  HILFSFUNKTIONEN
# =============================================================================

banner() {
  clear 2>/dev/null || true
  echo ""
  echo -e "${CYAN}${BOLD}"
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║                                              ║"
  echo "  ║      🔐  SSH Hardening Script  v3.0          ║"
  echo "  ║                                              ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo -e "${RESET}"
  echo -e "  ${DIM}System:  $(hostname)  │  $(date '+%d.%m.%Y %H:%M:%S')${RESET}"
  echo ""
}

print_step() {
  echo ""
  echo -e "${BOLD}${BLUE}  ╔═══════════════════════════════════════════════╗${RESET}"
  printf "${BOLD}${BLUE}  ║${RESET}  ${WHITE}${BOLD}  Schritt %s von 3 — %-29s${RESET}${BOLD}${BLUE}║${RESET}\n" "$1" "$2"
  echo -e "${BOLD}${BLUE}  ╚═══════════════════════════════════════════════╝${RESET}"
  echo ""
}

print_section() {
  echo ""
  echo -e "  ${BOLD}${WHITE}▸ $1${RESET}"
  echo -e "${DIM}  ···············································${RESET}"
}

ok()      { (( CHECKS_OK++ )) || true; (( CHECKS_TOTAL++ )) || true; echo -e "  ${IC_OK}  $*"; }
ok_info() { echo -e "  ${IC_OK}  $*"; }
warn()    { WARNINGS+=("$*"); echo -e "  ${IC_WARN}  ${YELLOW}$*${RESET}"; }
err()     { echo -e "  ${IC_ERR}  ${RED}${BOLD}$*${RESET}" >&2; }
info()    { echo -e "  ${IC_INFO}  ${DIM}$*${RESET}"; }
check()   { (( CHECKS_TOTAL++ )) || true; echo -e "  ${IC_CHECK}  ${DIM}Prüfe:${RESET} $*"; }

ask() {
  local prompt="$1"; local -n _askvar=$2; local default="${3:-}"
  exec 3>/dev/tty
  echo "" >&3
  if [[ -n "$default" ]]; then
    printf "  ${CYAN}?${RESET}  ${BOLD}%s${RESET} ${DIM}[Standard: %s]${RESET}: " "$prompt" "$default" >&3
  else
    printf "  ${CYAN}?${RESET}  ${BOLD}%s${RESET}: " "$prompt" >&3
  fi
  exec 3>&-
  read -r _askvar < /dev/tty
  [[ -z "$_askvar" && -n "$default" ]] && _askvar="$default"
}

# =============================================================================
#  PRE-CHECKS
# =============================================================================
banner

echo -e "  ${BOLD}Vorab-Prüfungen${RESET}"
echo -e "${DIM}  ···············································${RESET}"
echo ""

# Root-Check
check "Root-Rechte ..."
if [[ $EUID -ne 0 ]]; then
  err "Dieses Script muss als root ausgeführt werden."
  exit 1
fi
ok "Root-Rechte vorhanden"

# sshd_config vorhanden
check "${SSHD_CONFIG} vorhanden ..."
if [[ ! -f "$SSHD_CONFIG" ]]; then
  err "Datei ${SSHD_CONFIG} nicht gefunden."
  exit 1
fi
ok "${SSHD_CONFIG} gefunden"

# sshd installiert?
check "SSH-Dienst installiert ..."
if command -v sshd &>/dev/null; then
  SSHD_VERSION=$(sshd -V 2>&1 | head -1 || true)
  ok "sshd gefunden ${DIM}(${SSHD_VERSION})${RESET}"
else
  warn "sshd nicht gefunden — Script läuft trotzdem weiter"
fi

# sshd aktiv?
check "SSH-Dienst aktiv ..."
if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
  ok "SSH-Dienst läuft"
else
  warn "SSH-Dienst scheint nicht aktiv zu sein"
fi

# Backup-Verzeichnis beschreibbar?
check "Backup-Pfad beschreibbar ..."
if touch "${SSHD_CONFIG}.testwrite" 2>/dev/null; then
  rm -f "${SSHD_CONFIG}.testwrite"
  ok "Backup-Pfad ist beschreibbar"
else
  err "Keine Schreibrechte auf ${SSHD_CONFIG} — abbruch."
  exit 1
fi

echo ""

# =============================================================================
#  SCHRITT 1: BENUTZER-CHECK
# =============================================================================
print_step "1" "Benutzer-Check"

# /etc/passwd einlesen
print_section "Benutzerkonten analysieren"
echo ""

check "/etc/passwd wird eingelesen ..."
NORMAL_USERS=()
ALL_USERS_COUNT=0
SYS_USERS_COUNT=0

while IFS=: read -r uname _ uid _ _ _ shell; do
  (( ALL_USERS_COUNT++ )) || true
  if (( uid >= 1000 )) && [[ "$shell" != */nologin && "$shell" != */false ]]; then
    NORMAL_USERS+=("$uname")
  elif (( uid < 1000 )); then
    (( SYS_USERS_COUNT++ )) || true
  fi
done < /etc/passwd

ok "${ALL_USERS_COUNT} Einträge gelesen — ${SYS_USERS_COUNT} Systembenutzer gefiltert"

echo ""
if [[ ${#NORMAL_USERS[@]} -eq 0 ]]; then
  warn "Keine normalen Benutzerkonten gefunden (UID ≥ 1000 mit Login-Shell)."
  echo -e "  ${YELLOW}  → Neuen Sudo-User wird angelegt.${RESET}"
  USER_ACTION="create"
else
  echo -e "  ${BOLD}Gefundene normale Benutzerkonten:${RESET}"
  echo ""
  for u in "${NORMAL_USERS[@]}"; do
    UID_VAL=$(id -u "$u" 2>/dev/null || echo "?")
    SHELL_VAL=$(getent passwd "$u" | cut -d: -f7)
    if groups "$u" 2>/dev/null | grep -qE '\b(sudo|wheel)\b'; then
      SUDO_BADGE="${GREEN}[sudo]${RESET}"
    else
      SUDO_BADGE="${DIM}[kein sudo]${RESET}"
    fi
    echo -e "    👤  ${BOLD}${u}${RESET}  ${DIM}uid=${UID_VAL}  shell=${SHELL_VAL}${RESET}  ${SUDO_BADGE}"
  done
  echo ""
  echo -e "  ${BOLD}[1]${RESET} Vorhandenen Benutzer verwenden"
  echo -e "  ${BOLD}[2]${RESET} Neuen Benutzer anlegen"
  ask "Auswahl [1/2]" USER_ACTION_INPUT "1"
  [[ "$USER_ACTION_INPUT" == "2" ]] && USER_ACTION="create" || USER_ACTION="existing"
fi

# ── Neuen Benutzer anlegen ────────────────────────────────────────────────────
if [[ "$USER_ACTION" == "create" ]]; then
  print_section "Neuen Benutzer anlegen"

  while true; do
    ask "Benutzername" NEW_USERNAME
    if [[ -z "$NEW_USERNAME" ]]; then
      warn "Benutzername darf nicht leer sein."; continue
    fi
    if id "$NEW_USERNAME" &>/dev/null; then
      warn "Benutzer '${NEW_USERNAME}' existiert bereits."; continue
    fi
    if ! echo "$NEW_USERNAME" | grep -qE '^[a-z_][a-z0-9_-]{0,31}$'; then
      warn "Ungültiger Name (nur a-z, 0-9, _, - erlaubt, max. 32 Zeichen)."; continue
    fi
    break
  done

  # Sudo-Gruppe ermitteln
  check "Sudo-Gruppe ermitteln ..."
  if getent group sudo &>/dev/null; then
    SUDO_GROUP="sudo"
    ok "Gruppe 'sudo' gefunden (Debian/Ubuntu)"
  elif getent group wheel &>/dev/null; then
    SUDO_GROUP="wheel"
    ok "Gruppe 'wheel' gefunden (RHEL/Arch)"
  else
    groupadd sudo
    SUDO_GROUP="sudo"
    ok "Gruppe 'sudo' neu angelegt"
  fi

  ask "Zur Gruppe '${SUDO_GROUP}' hinzufügen? [J/n]" ADD_SUDO "J"

  echo ""
  check "Benutzer '${NEW_USERNAME}' anlegen ..."
  useradd -m -s /bin/bash "$NEW_USERNAME"
  ok "Benutzer ${BOLD}'${NEW_USERNAME}'${RESET} angelegt"
  ok_info "  Home-Verzeichnis: ${DIM}/home/${NEW_USERNAME}${RESET}"
  ok_info "  Login-Shell:      ${DIM}/bin/bash${RESET}"

  if [[ "${ADD_SUDO^^}" == "J" || "${ADD_SUDO^^}" == "Y" ]]; then
    check "Sudo-Rechte vergeben ..."
    usermod -aG "$SUDO_GROUP" "$NEW_USERNAME"
    ok "Benutzer zur Gruppe ${BOLD}'${SUDO_GROUP}'${RESET} hinzugefügt"
  fi

  echo ""
  echo -e "  🔑  ${BOLD}Passwort für '${NEW_USERNAME}' setzen${RESET} ${DIM}(für sudo benötigt)${RESET}"
  echo ""
  while true; do
    if passwd "$NEW_USERNAME" < /dev/tty; then
      ok "Passwort gesetzt"
      break
    else
      warn "Passwort-Vergabe fehlgeschlagen — erneut versuchen ..."
    fi
  done

  TARGET_USER="$NEW_USERNAME"
  NEW_USER_CREATED="$NEW_USERNAME"

# ── Vorhandenen Benutzer wählen ───────────────────────────────────────────────
else
  echo ""
  if [[ ${#NORMAL_USERS[@]} -eq 1 ]]; then
    TARGET_USER="${NORMAL_USERS[0]}"
    check "Einzigen verfügbaren Benutzer automatisch auswählen ..."
    ok "Verwende Benutzer: ${BOLD}${TARGET_USER}${RESET}"
  else
    ask "Benutzername eingeben" TARGET_USER
    check "Benutzer '${TARGET_USER}' prüfen ..."
    if ! id "$TARGET_USER" &>/dev/null; then
      warn "Benutzer '${TARGET_USER}' nicht gefunden — Schritt übersprungen."
      TARGET_USER=""
    else
      ok "Benutzer ${BOLD}'${TARGET_USER}'${RESET} existiert"
    fi
  fi
fi

# =============================================================================
#  SCHRITT 2: SSH PUBLIC KEY
# =============================================================================
print_step "2" "SSH Public Key einrichten"

if [[ -n "$TARGET_USER" ]]; then
  echo -e "  ${BOLD}[1]${RESET} Key jetzt eintragen ${DIM}(für '${TARGET_USER}')${RESET}"
else
  echo -e "  ${BOLD}[1]${RESET} Key jetzt eintragen"
fi
echo -e "  ${BOLD}[2]${RESET} Überspringen ${DIM}(Key bereits vorhanden)${RESET}"
ask "Auswahl [1/2]" KEY_CHOICE "2"

if [[ "$KEY_CHOICE" == "1" ]]; then

  if [[ -z "$TARGET_USER" ]]; then
    ask "Benutzername" TARGET_USER
    check "Benutzer '${TARGET_USER}' prüfen ..."
    if ! id "$TARGET_USER" &>/dev/null; then
      warn "Benutzer '${TARGET_USER}' nicht gefunden — Key-Setup übersprungen."
      TARGET_USER=""
      KEY_CHOICE="skip"
    else
      ok "Benutzer ${BOLD}'${TARGET_USER}'${RESET} gefunden"
    fi
  fi

  if [[ -n "$TARGET_USER" ]]; then
    TARGET_HOME=$(eval echo "~${TARGET_USER}")
    AUTH_KEYS="${TARGET_HOME}/.ssh/authorized_keys"

    print_section "SSH-Verzeichnis prüfen"
    echo ""

    check "${TARGET_HOME}/.ssh vorhanden ..."
    if [[ ! -d "${TARGET_HOME}/.ssh" ]]; then
      mkdir -p "${TARGET_HOME}/.ssh"
      chmod 700 "${TARGET_HOME}/.ssh"
      chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.ssh"
      ok "Verzeichnis ${BOLD}${TARGET_HOME}/.ssh${RESET} angelegt ${DIM}(chmod 700)${RESET}"
    else
      ok "Verzeichnis ${BOLD}${TARGET_HOME}/.ssh${RESET} bereits vorhanden"
      # Berechtigungen prüfen
      check "Berechtigungen auf .ssh prüfen ..."
      PERM=$(stat -c "%a" "${TARGET_HOME}/.ssh")
      if [[ "$PERM" != "700" ]]; then
        chmod 700 "${TARGET_HOME}/.ssh"
        ok "Berechtigungen korrigiert: ${YELLOW}${PERM}${RESET} → ${GREEN}700${RESET}"
      else
        ok "Berechtigungen korrekt ${DIM}(700)${RESET}"
      fi
    fi

    # authorized_keys prüfen
    check "${AUTH_KEYS} prüfen ..."
    if [[ -f "$AUTH_KEYS" ]]; then
      EXISTING_KEYS=$(grep -cE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp|sk-)' "$AUTH_KEYS" 2>/dev/null || echo 0)
      ok "Datei existiert — ${DIM}${EXISTING_KEYS} Key(s) bereits vorhanden${RESET}"
    else
      ok_info "Datei wird neu angelegt"
    fi

    echo ""
    echo -e "  🔑  ${BOLD}Public Key einfügen${RESET} ${DIM}(ssh-ed25519 / ssh-rsa / ecdsa ...)${RESET}"
    echo -e "  ${DIM}Abschließen mit ENTER${RESET}"
    echo ""
    printf "  ${CYAN}❯ ${RESET}" > /dev/tty
    read -r KEY_INPUT < /dev/tty
    echo ""

    if [[ -z "$KEY_INPUT" ]]; then
      warn "Kein Key eingegeben — Schritt übersprungen."
    else
      ADDED=0
      check "Key-Format validieren ..."
      echo ""
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if echo "$line" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp|sk-ssh-ed25519|sk-ecdsa-sha2)'; then
          KEY_TYPE=$(echo "$line" | awk '{print $1}')
          KEY_COMMENT=$(echo "$line" | awk '{print $3}')
          echo "$line" >> "$AUTH_KEYS"
          ok "Key akzeptiert ${DIM}[${KEY_TYPE}]${RESET}${KEY_COMMENT:+ — ${DIM}${KEY_COMMENT}${RESET}}"
          (( ADDED++ ))
        else
          warn "Ungültiges Format übersprungen: ${DIM}${line:0:40}...${RESET}"
        fi
      done <<< "$KEY_INPUT"

      if [[ $ADDED -gt 0 ]]; then
        chmod 600 "$AUTH_KEYS"
        chown "${TARGET_USER}:${TARGET_USER}" "$AUTH_KEYS"
        echo ""
        ok "${GREEN}${BOLD}${ADDED} Key(s)${RESET} erfolgreich gespeichert"
        ok_info "Pfad:          ${DIM}${AUTH_KEYS}${RESET}"
        ok_info "Berechtigungen: ${DIM}600 / Eigentümer: ${TARGET_USER}${RESET}"
      else
        warn "Keine gültigen Keys — Schritt übersprungen."
      fi
    fi
  fi

else
  print_section "Key-Setup"
  echo ""
  info "Übersprungen — Key bereits vorhanden."
  check "authorized_keys prüfen ..."
  if [[ -n "$TARGET_USER" ]]; then
    AK_PATH=$(eval echo "~${TARGET_USER}")/.ssh/authorized_keys
    if [[ -f "$AK_PATH" ]]; then
      KEY_COUNT=$(grep -cE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp|sk-)' "$AK_PATH" 2>/dev/null || echo 0)
      ok "authorized_keys gefunden — ${GREEN}${KEY_COUNT} Key(s)${RESET} vorhanden"
    else
      warn "authorized_keys nicht gefunden — SSH-Login nach dem Härten evtl. nicht möglich!"
    fi
  else
    warn "Kein Benutzer ausgewählt — Key-Prüfung übersprungen."
  fi
fi

# =============================================================================
#  SCHRITT 3: SSH-KONFIGURATION HÄRTEN
# =============================================================================
print_step "3" "SSH-Konfiguration härten"

set_sshd_option() {
  local key="$1"
  local value="$2"
  local current
  current=$(grep -E "^[[:space:]]*${key}[[:space:]]+" "$SSHD_CONFIG" | awk '{print $2}' | tail -1)

  if [[ "$current" == "$value" ]]; then
    (( CHECKS_OK++ )) || true; (( CHECKS_TOTAL++ )) || true
    echo -e "  ${IC_SKIP}  ${DIM}${key} → ${value}  (bereits gesetzt — keine Änderung)${RESET}"
    return 0
  fi

  sed -i "s/^[[:space:]]*#*[[:space:]]*${key}[[:space:]].*$//" "$SSHD_CONFIG"
  echo "${key} ${value}" >> "$SSHD_CONFIG"
  (( CHECKS_OK++ )) || true; (( CHECKS_TOTAL++ )) || true

  if [[ -n "$current" ]]; then
    echo -e "  ${IC_CHG}  ${BOLD}${key}${RESET} → ${GREEN}${value}${RESET}  ${DIM}(geändert von: ${current})${RESET}"
  else
    echo -e "  ${IC_NEW}  ${BOLD}${key}${RESET} → ${GREEN}${value}${RESET}  ${DIM}(neu hinzugefügt)${RESET}"
  fi
}

print_section "Backup erstellen"
echo ""
check "Backup von ${SSHD_CONFIG} ..."
cp "$SSHD_CONFIG" "$BACKUP"
ok "Backup erstellt: ${DIM}${BACKUP}${RESET}"

print_section "Direktiven setzen"
echo ""

set_sshd_option "PermitRootLogin"                 "no"
set_sshd_option "PasswordAuthentication"          "no"
set_sshd_option "ChallengeResponseAuthentication" "no"
set_sshd_option "KbdInteractiveAuthentication"    "no"
set_sshd_option "PubkeyAuthentication"            "yes"
set_sshd_option "PermitEmptyPasswords"            "no"
set_sshd_option "UsePAM"                          "yes"

print_section "Konfiguration validieren"
echo ""
check "sshd -t (Syntax-Check) ..."
if sshd -t 2>/dev/null; then
  ok "Konfiguration ist syntaktisch korrekt"
else
  err "Konfiguration ungültig — stelle Backup wieder her ..."
  cp "$BACKUP" "$SSHD_CONFIG"
  err "Backup wiederhergestellt. Keine Änderungen aktiv."
  exit 1
fi

print_section "SSH-Dienst neu laden"
echo ""
check "Aktiven SSH-Dienst ermitteln ..."
if systemctl is-active --quiet ssh 2>/dev/null; then
  ok "Dienst ${BOLD}'ssh'${RESET} ist aktiv"
  check "systemctl reload ssh ..."
  systemctl reload ssh
  ok "Dienst ${BOLD}'ssh'${RESET} erfolgreich neu geladen"
elif systemctl is-active --quiet sshd 2>/dev/null; then
  ok "Dienst ${BOLD}'sshd'${RESET} ist aktiv"
  check "systemctl reload sshd ..."
  systemctl reload sshd
  ok "Dienst ${BOLD}'sshd'${RESET} erfolgreich neu geladen"
elif service ssh reload &>/dev/null; then
  ok "Dienst ${BOLD}'ssh'${RESET} neu geladen (SysV)"
else
  warn "SSH-Dienst konnte nicht automatisch neu geladen werden."
  warn "Bitte manuell ausführen: ${BOLD}systemctl reload sshd${RESET}"
fi

# =============================================================================
#  ABSCHLUSSBERICHT
# =============================================================================
echo ""
echo ""

# Erfolg oder Warnung?
HAS_WARNINGS=0
[[ ${#WARNINGS[@]} -gt 0 ]] && HAS_WARNINGS=1

if [[ $HAS_WARNINGS -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}"
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║                                              ║"
  echo "  ║   ✅   ALL CHECKS PASSED — SUCCESS!          ║"
  echo "  ║                                              ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo -e "${RESET}"
else
  echo -e "${YELLOW}${BOLD}"
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║                                              ║"
  echo "  ║   ⚠   DONE — MIT WARNUNGEN                   ║"
  echo "  ║                                              ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo -e "${RESET}"
fi

echo -e "  ${DIM}Ergebnis: ${CHECKS_OK}/${CHECKS_TOTAL} Checks erfolgreich${RESET}"
echo ""

# Detailübersicht
echo -e "  ${BOLD}${WHITE}Übersicht${RESET}"
echo -e "${DIM}  ───────────────────────────────────────────────${RESET}"

if [[ -n "$NEW_USER_CREATED" ]]; then
  echo -e "  ${IC_OK}  Benutzer       ${BOLD}'${NEW_USER_CREATED}'${RESET} ${GREEN}neu angelegt${RESET}"
elif [[ -n "$TARGET_USER" ]]; then
  echo -e "  ${IC_OK}  Benutzer       ${BOLD}'${TARGET_USER}'${RESET} verwendet"
else
  echo -e "  ${IC_WARN}  Benutzer       ${YELLOW}keiner ausgewählt${RESET}"
fi

if [[ "$KEY_CHOICE" == "1" && $ADDED -gt 0 ]]; then
  echo -e "  ${IC_OK}  SSH Key        ${GREEN}${ADDED} Key(s) hinterlegt${RESET} für ${BOLD}'${TARGET_USER}'${RESET}"
elif [[ "$KEY_CHOICE" == "2" ]]; then
  echo -e "  ${IC_OK}  SSH Key        bereits vorhanden ${DIM}(übersprungen)${RESET}"
else
  echo -e "  ${IC_WARN}  SSH Key        ${YELLOW}nicht eingetragen!${RESET}"
fi

echo -e "  ${IC_OK}  Root-Login     ${GREEN}deaktiviert${RESET}  ${DIM}(PermitRootLogin no)${RESET}"
echo -e "  ${IC_OK}  Passwort-SSH   ${GREEN}deaktiviert${RESET}  ${DIM}(PasswordAuthentication no)${RESET}"
echo -e "  ${IC_OK}  Key-Auth       ${GREEN}aktiviert${RESET}    ${DIM}(PubkeyAuthentication yes)${RESET}"
echo -e "  ${IC_OK}  SSH-Dienst     ${GREEN}neu geladen${RESET}"
echo -e "  ${IC_OK}  Backup         ${DIM}${BACKUP}${RESET}"

# Warnungen ausgeben
if [[ $HAS_WARNINGS -eq 1 ]]; then
  echo ""
  echo -e "  ${BOLD}${YELLOW}Warnungen${RESET}"
  echo -e "${DIM}  ───────────────────────────────────────────────${RESET}"
  for w in "${WARNINGS[@]}"; do
    echo -e "  ${IC_WARN}  ${YELLOW}${w}${RESET}"
  done
fi

# Kritische Hinweise
if [[ "$KEY_CHOICE" != "1" || $ADDED -eq 0 ]] && [[ "$KEY_CHOICE" != "2" ]]; then
  echo ""
  echo -e "  ${RED}${BOLD}  !! KRITISCH:${RESET}  ${YELLOW}Kein SSH-Key hinterlegt!${RESET}"
  echo -e "  ${YELLOW}  Stelle sicher, dass ein Key in${RESET}"
  echo -e "  ${YELLOW}  ~/.ssh/authorized_keys vorhanden ist,${RESET}"
  echo -e "  ${YELLOW}  BEVOR du dich ausloggst!${RESET}"
fi

echo ""
echo -e "${DIM}  ───────────────────────────────────────────────${RESET}"
echo -e "  ${DIM}$(date '+%d.%m.%Y %H:%M:%S')  │  $(hostname)${RESET}"
echo ""
