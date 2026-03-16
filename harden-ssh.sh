#!/usr/bin/env bash
# =============================================================================
#  harden-ssh.sh — SSH Hardening Script
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

# =============================================================================
#  FARBEN & SYMBOLE
# =============================================================================
if [[ -t 1 ]]; then
  RESET="\033[0m"
  BOLD="\033[1m"
  DIM="\033[2m"
  RED="\033[0;31m"
  GREEN="\033[0;32m"
  YELLOW="\033[0;33m"
  CYAN="\033[0;36m"
  WHITE="\033[1;37m"
  BLUE="\033[0;34m"
  MAGENTA="\033[0;35m"
else
  RESET="" BOLD="" DIM="" RED="" GREEN="" YELLOW="" CYAN="" WHITE="" BLUE="" MAGENTA=""
fi

IC_OK="${GREEN}✔${RESET}"
IC_WARN="${YELLOW}⚠${RESET}"
IC_ERR="${RED}✖${RESET}"
IC_INFO="${CYAN}→${RESET}"
IC_NEW="${MAGENTA}+${RESET}"
IC_SKIP="${DIM}=${RESET}"
IC_CHG="${YELLOW}~${RESET}"
IC_KEY="${CYAN}🔑${RESET}"
IC_USER="${CYAN}👤${RESET}"
IC_LOCK="${GREEN}🔒${RESET}"

# =============================================================================
#  HILFSFUNKTIONEN
# =============================================================================

banner() {
  echo ""
  echo -e "${CYAN}${BOLD}"
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║                                              ║"
  echo "  ║        SSH Hardening Script  v2.0            ║"
  echo "  ║                                              ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo -e "${RESET}"
}

print_step() {
  local num="$1"
  local title="$2"
  echo ""
  echo -e "${BOLD}${BLUE}  ┌─────────────────────────────────────────────┐${RESET}"
  printf "${BOLD}${BLUE}  │${RESET}  ${WHITE}${BOLD}Schritt %s — %-33s${RESET}${BOLD}${BLUE}│${RESET}\n" "$num" "$title"
  echo -e "${BOLD}${BLUE}  └─────────────────────────────────────────────┘${RESET}"
  echo ""
}

print_section() {
  echo ""
  echo -e "${DIM}  ────────────────────────────────────────────────${RESET}"
  echo -e "  ${BOLD}${WHITE}$1${RESET}"
  echo -e "${DIM}  ────────────────────────────────────────────────${RESET}"
  echo ""
}

ok()   { echo -e "  ${IC_OK}  $*"; }
warn() { echo -e "  ${IC_WARN}  ${YELLOW}$*${RESET}"; }
err()  { echo -e "  ${IC_ERR}  ${RED}$*${RESET}" >&2; }
info() { echo -e "  ${IC_INFO}  ${DIM}$*${RESET}"; }

ask() {
  # ask "Prompt" VAR [default]
  local prompt="$1"
  local -n _var=$2
  local default="${3:-}"
  if [[ -n "$default" ]]; then
    printf "  ${CYAN}?${RESET}  ${BOLD}%s${RESET} ${DIM}[%s]${RESET}: " "$prompt" "$default" > /dev/tty
  else
    printf "  ${CYAN}?${RESET}  ${BOLD}%s${RESET}: " "$prompt" > /dev/tty
  fi
  read -r _var < /dev/tty
  [[ -z "$_var" && -n "$default" ]] && _var="$default"
}

divider() {
  echo -e "\n${DIM}  ···············································${RESET}\n"
}

# =============================================================================
#  ROOT-CHECK
# =============================================================================
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}${BOLD}  Dieses Script muss als root ausgeführt werden.${RESET}" >&2
  exit 1
fi

if [[ ! -f "$SSHD_CONFIG" ]]; then
  err "FEHLER: ${SSHD_CONFIG} nicht gefunden."
  exit 1
fi

# =============================================================================
#  BANNER
# =============================================================================
banner
echo -e "  ${DIM}Schritte: Benutzer prüfen → SSH-Key hinterlegen → SSH härten${RESET}"
echo ""

# =============================================================================
#  SCHRITT 1: BENUTZER-CHECK
# =============================================================================
print_step "1" "Benutzer-Check"

NORMAL_USERS=()
while IFS=: read -r uname _ uid _ _ _ shell; do
  if (( uid >= 1000 )) && [[ "$shell" != */nologin && "$shell" != */false ]]; then
    NORMAL_USERS+=("$uname")
  fi
done < /etc/passwd

if [[ ${#NORMAL_USERS[@]} -eq 0 ]]; then
  warn "Keine normalen Benutzerkonten gefunden (nur root / Systemuser)."
  echo ""
  echo -e "  ${YELLOW}Es wird empfohlen, vor dem Deaktivieren des Root-Logins${RESET}"
  echo -e "  ${YELLOW}einen normalen Sudo-User anzulegen.${RESET}"
  USER_ACTION="create"
else
  echo -e "  ${BOLD}Gefundene Benutzerkonten${RESET} ${DIM}(UID ≥ 1000):${RESET}"
  echo ""
  for u in "${NORMAL_USERS[@]}"; do
    if groups "$u" 2>/dev/null | grep -qE '\b(sudo|wheel)\b'; then
      SUDO_BADGE=" ${GREEN}[sudo]${RESET}"
    else
      SUDO_BADGE=" ${DIM}[kein sudo]${RESET}"
    fi
    echo -e "    ${IC_USER}  ${BOLD}${u}${RESET}${SUDO_BADGE}"
  done
  echo ""
  echo -e "  ${BOLD}[1]${RESET} Vorhandenen Benutzer verwenden"
  echo -e "  ${BOLD}[2]${RESET} Neuen Benutzer anlegen"
  echo ""
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

  if getent group sudo &>/dev/null; then
    SUDO_GROUP="sudo"
  elif getent group wheel &>/dev/null; then
    SUDO_GROUP="wheel"
  else
    groupadd sudo
    SUDO_GROUP="sudo"
  fi

  ask "Zur Gruppe '${SUDO_GROUP}' hinzufügen? [J/n]" ADD_SUDO "J"

  useradd -m -s /bin/bash "$NEW_USERNAME"
  ok "Benutzer ${BOLD}'${NEW_USERNAME}'${RESET} angelegt ${DIM}(Home: /home/${NEW_USERNAME}, Shell: /bin/bash)${RESET}"

  if [[ "${ADD_SUDO^^}" == "J" || "${ADD_SUDO^^}" == "Y" ]]; then
    usermod -aG "$SUDO_GROUP" "$NEW_USERNAME"
    ok "Zur Gruppe ${BOLD}'${SUDO_GROUP}'${RESET} hinzugefügt"
  fi

  echo ""
  echo -e "  ${IC_KEY}  ${BOLD}Passwort für '${NEW_USERNAME}' setzen${RESET} ${DIM}(wird für sudo benötigt)${RESET}"
  echo ""
  while true; do
    if passwd "$NEW_USERNAME"; then
      ok "Passwort gesetzt."
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
    ok "Verwende Benutzer: ${BOLD}${TARGET_USER}${RESET}"
  else
    ask "Benutzername eingeben" TARGET_USER
    if ! id "$TARGET_USER" &>/dev/null; then
      warn "Benutzer '${TARGET_USER}' nicht gefunden — Schritt übersprungen."
      TARGET_USER=""
    else
      ok "Verwende Benutzer: ${BOLD}${TARGET_USER}${RESET}"
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
echo ""
ask "Auswahl [1/2]" KEY_CHOICE "2"

if [[ "$KEY_CHOICE" == "1" ]]; then
  if [[ -z "$TARGET_USER" ]]; then
    ask "Benutzername" TARGET_USER
    if ! id "$TARGET_USER" &>/dev/null; then
      warn "Benutzer '${TARGET_USER}' nicht gefunden — Key-Setup übersprungen."
      TARGET_USER=""
      KEY_CHOICE="skip"
    fi
  fi

  if [[ -n "$TARGET_USER" ]]; then
    TARGET_HOME=$(eval echo "~${TARGET_USER}")
    AUTH_KEYS="${TARGET_HOME}/.ssh/authorized_keys"

    if [[ ! -d "${TARGET_HOME}/.ssh" ]]; then
      mkdir -p "${TARGET_HOME}/.ssh"
      chmod 700 "${TARGET_HOME}/.ssh"
      chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.ssh"
      ok "Verzeichnis ${BOLD}${TARGET_HOME}/.ssh${RESET} angelegt"
    fi

    echo ""
    echo -e "  ${IC_KEY}  ${BOLD}Public Key einfügen${RESET} ${DIM}(ssh-ed25519 / ssh-rsa / ecdsa ...)${RESET}"
    echo -e "  ${DIM}Abschließen mit ENTER${RESET}"
    echo ""
    printf "  ${CYAN}❯${RESET} " > /dev/tty
    read -r KEY_INPUT < /dev/tty
    echo ""

    if [[ -z "$KEY_INPUT" ]]; then
      warn "Kein Key eingegeben — Schritt übersprungen."
    else
      ADDED=0
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if echo "$line" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp|sk-ssh-ed25519|sk-ecdsa-sha2)'; then
          echo "$line" >> "$AUTH_KEYS"
          ok "Key eingetragen: ${DIM}${line:0:55}...${RESET}"
          (( ADDED++ ))
        else
          warn "Ungültige Zeile übersprungen: ${DIM}${line:0:40}...${RESET}"
        fi
      done <<< "$KEY_INPUT"

      if [[ $ADDED -gt 0 ]]; then
        chmod 600 "$AUTH_KEYS"
        chown "${TARGET_USER}:${TARGET_USER}" "$AUTH_KEYS"
        ok "${BOLD}${ADDED} Key(s)${RESET} in ${DIM}${AUTH_KEYS}${RESET} gespeichert"
      else
        warn "Keine gültigen Keys gefunden — Schritt übersprungen."
      fi
    fi
  fi
else
  info "Key-Setup übersprungen."
fi

# =============================================================================
#  SCHRITT 3: SSH HÄRTEN
# =============================================================================
print_step "3" "SSH-Konfiguration härten"

set_sshd_option() {
  local key="$1"
  local value="$2"
  local current
  current=$(grep -E "^[[:space:]]*${key}[[:space:]]+" "$SSHD_CONFIG" | awk '{print $2}' | tail -1)

  if [[ "$current" == "$value" ]]; then
    echo -e "  ${IC_SKIP}  ${DIM}${key}${RESET} ${DIM}→ ${value}  (bereits gesetzt)${RESET}"
    return 0
  fi

  sed -i "s/^[[:space:]]*#*[[:space:]]*${key}[[:space:]].*$//" "$SSHD_CONFIG"
  echo "${key} ${value}" >> "$SSHD_CONFIG"

  if [[ -n "$current" ]]; then
    echo -e "  ${IC_CHG}  ${BOLD}${key}${RESET} → ${GREEN}${value}${RESET}  ${DIM}(war: ${current})${RESET}"
  else
    echo -e "  ${IC_NEW}  ${BOLD}${key}${RESET} → ${GREEN}${value}${RESET}  ${DIM}(neu gesetzt)${RESET}"
  fi
}

info "Erstelle Backup: ${DIM}${BACKUP}${RESET}"
cp "$SSHD_CONFIG" "$BACKUP"
echo ""

set_sshd_option "PermitRootLogin"                 "no"
set_sshd_option "PasswordAuthentication"          "no"
set_sshd_option "ChallengeResponseAuthentication" "no"
set_sshd_option "KbdInteractiveAuthentication"    "no"
set_sshd_option "PubkeyAuthentication"            "yes"
set_sshd_option "PermitEmptyPasswords"            "no"
set_sshd_option "UsePAM"                          "yes"

echo ""
info "Validiere Konfiguration ..."
if sshd -t 2>/dev/null; then
  ok "Konfiguration ist valide."
else
  err "Konfiguration ungültig — stelle Backup wieder her ..."
  cp "$BACKUP" "$SSHD_CONFIG"
  err "Backup wiederhergestellt. Keine Änderungen aktiv."
  exit 1
fi

echo ""
info "Lade SSH-Dienst neu ..."
if systemctl is-active --quiet ssh 2>/dev/null; then
  systemctl reload ssh
  ok "Dienst ${BOLD}'ssh'${RESET} neu geladen."
elif systemctl is-active --quiet sshd 2>/dev/null; then
  systemctl reload sshd
  ok "Dienst ${BOLD}'sshd'${RESET} neu geladen."
elif service ssh reload &>/dev/null; then
  ok "Dienst ${BOLD}'ssh'${RESET} neu geladen (SysV)."
else
  warn "SSH-Dienst konnte nicht automatisch neu geladen werden."
  warn "Bitte manuell ausführen: ${BOLD}systemctl reload sshd${RESET}"
fi

# =============================================================================
#  ZUSAMMENFASSUNG
# =============================================================================
echo ""
echo -e "${CYAN}${BOLD}"
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║           Hardening abgeschlossen            ║"
echo "  ╚══════════════════════════════════════════════╝"
echo -e "${RESET}"

if [[ -n "$NEW_USER_CREATED" ]]; then
  echo -e "  ${IC_OK}  Benutzer      ${BOLD}'${NEW_USER_CREATED}'${RESET} ${GREEN}neu angelegt${RESET}"
elif [[ -n "$TARGET_USER" ]]; then
  echo -e "  ${IC_OK}  Benutzer      ${BOLD}'${TARGET_USER}'${RESET} verwendet"
else
  echo -e "  ${IC_WARN}  Benutzer      ${YELLOW}kein Benutzer ausgewählt${RESET}"
fi

if [[ "$KEY_CHOICE" == "1" && $ADDED -gt 0 ]]; then
  echo -e "  ${IC_OK}  SSH Key       ${GREEN}${ADDED} Key(s) hinterlegt${RESET} für ${BOLD}'${TARGET_USER}'${RESET}"
else
  echo -e "  ${IC_WARN}  SSH Key       ${YELLOW}nicht eingetragen — bitte manuell nachholen!${RESET}"
fi

echo -e "  ${IC_LOCK}  Root-Login    ${GREEN}deaktiviert${RESET}"
echo -e "  ${IC_LOCK}  Passwort-SSH  ${GREEN}deaktiviert${RESET}"
echo -e "  ${IC_OK}  Key-Auth      ${GREEN}aktiviert${RESET}"
echo -e "  ${IC_OK}  Backup        ${DIM}${BACKUP}${RESET}"

if [[ $ADDED -eq 0 ]]; then
  echo ""
  echo -e "  ${YELLOW}${BOLD}  WICHTIG:${RESET} ${YELLOW}Stelle sicher, dass ein gültiger SSH-Key${RESET}"
  echo -e "  ${YELLOW}in ~/.ssh/authorized_keys eingetragen ist,${RESET}"
  echo -e "  ${YELLOW}BEVOR du dich ausloggst!${RESET}"
fi

echo ""
echo -e "${DIM}  ───────────────────────────────────────────────${RESET}"
echo ""
