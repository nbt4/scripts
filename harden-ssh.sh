#!/usr/bin/env bash
# =============================================================================
#  harden-ssh.sh — SSH Hardening Script
#  - Überprüft vorhandene normale Benutzer, legt ggf. neuen an
#  - Deaktiviert Passwort-Login (nur Key-Auth)
#  - Deaktiviert Root-Login via SSH
#  - Optionales Backup der sshd_config
# =============================================================================

set -euo pipefail

SSHD_CONFIG="/etc/ssh/sshd_config"
BACKUP="${SSHD_CONFIG}.bak.$(date +%Y%m%d_%H%M%S)"
LOG_PREFIX="[harden-ssh]"

# Tracking-Variablen für Zusammenfassung
NEW_USER_CREATED=""
TARGET_USER=""
ADDED=0
KEY_CHOICE=""

# ── Hilfsfunktionen ───────────────────────────────────────────────────────────
print_header() {
  echo ""
  echo "════════════════════════════════════════════"
  echo "  $1"
  echo "════════════════════════════════════════════"
}

print_step() {
  echo ""
  echo "┌─────────────────────────────────────────┐"
  printf  "│  Schritt %-2s: %-27s│\n" "$1" "$2"
  echo "└─────────────────────────────────────────┘"
}

# ── Root-Check ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "${LOG_PREFIX} Dieses Script muss als root ausgeführt werden." >&2
  exit 1
fi

# ── Prüfen ob sshd_config existiert ──────────────────────────────────────────
if [[ ! -f "$SSHD_CONFIG" ]]; then
  echo "${LOG_PREFIX} FEHLER: ${SSHD_CONFIG} nicht gefunden." >&2
  exit 1
fi

print_header "SSH Hardening Script"
echo "  Dieses Script führt folgende Schritte aus:"
echo "   1) Vorhandene Benutzer prüfen / neuen anlegen"
echo "   2) SSH Public Key hinterlegen"
echo "   3) SSH-Konfiguration härten"
echo ""

# =============================================================================
#  SCHRITT 1: Benutzer-Check
# =============================================================================
print_step "1" "Benutzer-Check"

# Alle normalen Benutzer ermitteln (UID >= 1000, kein nologin/false shell)
NORMAL_USERS=()
while IFS=: read -r uname _ uid _ _ _ shell; do
  if (( uid >= 1000 )) && [[ "$shell" != */nologin && "$shell" != */false ]]; then
    NORMAL_USERS+=("$uname")
  fi
done < /etc/passwd

if [[ ${#NORMAL_USERS[@]} -eq 0 ]]; then
  echo ""
  echo "  ⚠  Keine normalen Benutzerkonten gefunden!"
  echo "     (nur root und Systembenutzer vorhanden)"
  echo ""
  echo "  Es wird empfohlen, vor dem Deaktivieren des"
  echo "  Root-Logins einen normalen Sudo-User anzulegen."
  USER_ACTION="create"
else
  echo ""
  echo "  Gefundene Benutzerkonten (UID >= 1000):"
  echo ""
  for u in "${NORMAL_USERS[@]}"; do
    if groups "$u" 2>/dev/null | grep -qE '\b(sudo|wheel)\b'; then
      SUDO_FLAG="  [sudo]"
    else
      SUDO_FLAG=""
    fi
    printf "    *  %-20s%s\n" "$u" "$SUDO_FLAG"
  done
  echo ""
  echo "  [1] Vorhandenen Benutzer verwenden"
  echo "  [2] Neuen Benutzer anlegen"
  echo ""
  read -rp "  Auswahl [1/2]: " USER_ACTION_INPUT < /dev/tty
  [[ "$USER_ACTION_INPUT" == "2" ]] && USER_ACTION="create" || USER_ACTION="existing"
fi

# ── Neuen Benutzer anlegen ────────────────────────────────────────────────────
if [[ "$USER_ACTION" == "create" ]]; then
  echo ""
  echo "  Neuen Benutzer anlegen:"
  echo ""

  while true; do
    read -rp "  Benutzername: " NEW_USERNAME < /dev/tty
    if [[ -z "$NEW_USERNAME" ]]; then
      echo "  ⚠  Benutzername darf nicht leer sein."
      continue
    fi
    if id "$NEW_USERNAME" &>/dev/null; then
      echo "  ⚠  Benutzer '${NEW_USERNAME}' existiert bereits."
      continue
    fi
    if ! echo "$NEW_USERNAME" | grep -qE '^[a-z_][a-z0-9_-]{0,31}$'; then
      echo "  ⚠  Ungültiger Name (nur a-z, 0-9, _, - erlaubt, max. 32 Zeichen)."
      continue
    fi
    break
  done

  # Sudo-Gruppe ermitteln (sudo auf Debian/Ubuntu, wheel auf RHEL/Arch)
  if getent group sudo &>/dev/null; then
    SUDO_GROUP="sudo"
  elif getent group wheel &>/dev/null; then
    SUDO_GROUP="wheel"
  else
    groupadd sudo
    SUDO_GROUP="sudo"
  fi

  echo ""
  read -rp "  Benutzer zur Gruppe '${SUDO_GROUP}' hinzufügen? [J/n]: " ADD_SUDO < /dev/tty
  ADD_SUDO="${ADD_SUDO:-J}"

  # Benutzer anlegen mit Homeverzeichnis und bash als Shell
  useradd -m -s /bin/bash "$NEW_USERNAME"
  echo "${LOG_PREFIX}  ✓  Benutzer '${NEW_USERNAME}' angelegt (Home: /home/${NEW_USERNAME})."

  if [[ "${ADD_SUDO^^}" == "J" || "${ADD_SUDO^^}" == "Y" ]]; then
    usermod -aG "$SUDO_GROUP" "$NEW_USERNAME"
    echo "${LOG_PREFIX}  ✓  Benutzer zur Gruppe '${SUDO_GROUP}' hinzugefügt."
  fi

  # Passwort setzen
  echo ""
  echo "  Passwort für '${NEW_USERNAME}' setzen:"
  echo "  (Wird fuer sudo benoetigt — SSH-Login erfolgt per Key)"
  echo ""
  while true; do
    if passwd "$NEW_USERNAME"; then
      echo "${LOG_PREFIX}  ✓  Passwort gesetzt."
      break
    else
      echo "  ⚠  Passwort-Vergabe fehlgeschlagen, erneut versuchen ..."
    fi
  done

  TARGET_USER="$NEW_USERNAME"
  NEW_USER_CREATED="$NEW_USERNAME"

# ── Vorhandenen Benutzer auswählen ────────────────────────────────────────────
else
  echo ""
  if [[ ${#NORMAL_USERS[@]} -eq 1 ]]; then
    TARGET_USER="${NORMAL_USERS[0]}"
    echo "  ->  Verwende Benutzer: ${TARGET_USER}"
  else
    read -rp "  Benutzername eingeben: " TARGET_USER < /dev/tty
    if ! id "$TARGET_USER" &>/dev/null; then
      echo "${LOG_PREFIX} ⚠  Benutzer '${TARGET_USER}' nicht gefunden — Schritt übersprungen."
      TARGET_USER=""
    fi
  fi
fi

# =============================================================================
#  SCHRITT 2: SSH Public Key einrichten
# =============================================================================
print_step "2" "SSH Public Key einrichten"

echo ""
if [[ -n "$TARGET_USER" ]]; then
  echo "  [1] Key jetzt eintragen (fuer '${TARGET_USER}')"
else
  echo "  [1] Key jetzt eintragen"
fi
echo "  [2] Überspringen (Key bereits vorhanden)"
echo ""
read -rp "  Auswahl [1/2]: " KEY_CHOICE < /dev/tty

if [[ "$KEY_CHOICE" == "1" ]]; then

  # Falls noch kein Target-User gesetzt, jetzt abfragen
  if [[ -z "$TARGET_USER" ]]; then
    read -rp "  Benutzername: " TARGET_USER < /dev/tty
    if ! id "$TARGET_USER" &>/dev/null; then
      echo "${LOG_PREFIX} ⚠  Benutzer '${TARGET_USER}' nicht gefunden — Key-Setup übersprungen."
      TARGET_USER=""
      KEY_CHOICE="skip"
    fi
  fi

  if [[ -n "$TARGET_USER" ]]; then
    TARGET_HOME=$(eval echo "~${TARGET_USER}")
    AUTH_KEYS="${TARGET_HOME}/.ssh/authorized_keys"

    # .ssh Verzeichnis anlegen falls nicht vorhanden
    if [[ ! -d "${TARGET_HOME}/.ssh" ]]; then
      mkdir -p "${TARGET_HOME}/.ssh"
      chmod 700 "${TARGET_HOME}/.ssh"
      chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.ssh"
      echo "${LOG_PREFIX}  ✓  Verzeichnis ${TARGET_HOME}/.ssh angelegt."
    fi

    echo ""
    echo "  Füge deinen Public Key ein (ssh-rsa / ssh-ed25519 / ecdsa ...)."
    echo "  Abschließen mit ENTER:"
    echo ""

    read -r KEY_INPUT < /dev/tty

    if [[ -z "$KEY_INPUT" ]]; then
      echo "${LOG_PREFIX} ⚠  Kein Key eingegeben — Schritt übersprungen."
    else
      ADDED=0
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if echo "$line" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp|sk-ssh-ed25519|sk-ecdsa-sha2)'; then
          echo "$line" >> "$AUTH_KEYS"
          echo "${LOG_PREFIX}  ✓  Key eingetragen: ${line:0:50}..."
          (( ADDED++ ))
        else
          echo "${LOG_PREFIX} ⚠  Ungültige Zeile übersprungen: ${line:0:50}..."
        fi
      done <<< "$KEY_INPUT"

      if [[ $ADDED -gt 0 ]]; then
        chmod 600 "$AUTH_KEYS"
        chown "${TARGET_USER}:${TARGET_USER}" "$AUTH_KEYS"
        echo "${LOG_PREFIX}  ✓  ${ADDED} Key(s) in ${AUTH_KEYS} gespeichert."
      else
        echo "${LOG_PREFIX} ⚠  Keine gültigen Keys gefunden — Schritt übersprungen."
      fi
    fi
  fi
else
  echo "${LOG_PREFIX}  ->  Key-Setup übersprungen."
fi

# =============================================================================
#  SCHRITT 3: SSH-Konfiguration härten
# =============================================================================
print_step "3" "SSH-Konfiguration haerten"

# Hilfsfunktion: Direktive setzen oder ergänzen
set_sshd_option() {
  local key="$1"
  local value="$2"
  sed -i "s/^[[:space:]]*#*[[:space:]]*${key}[[:space:]].*$//" "$SSHD_CONFIG"
  echo "${key} ${value}" >> "$SSHD_CONFIG"
  echo "${LOG_PREFIX}  ✓  ${key} -> ${value}"
}

echo ""
echo "${LOG_PREFIX} Erstelle Backup: ${BACKUP}"
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

# ── Konfiguration testen ──────────────────────────────────────────────────────
echo "${LOG_PREFIX} Teste Konfiguration mit 'sshd -t' ..."
if sshd -t; then
  echo "${LOG_PREFIX}  ✓  Konfiguration ist valide."
else
  echo "${LOG_PREFIX} FEHLER: Konfiguration ungültig — stelle Backup wieder her ..."
  cp "$BACKUP" "$SSHD_CONFIG"
  echo "${LOG_PREFIX} Backup wiederhergestellt. Keine Änderungen aktiv."
  exit 1
fi

# ── SSH-Dienst neu laden ──────────────────────────────────────────────────────
echo "${LOG_PREFIX} Lade SSH-Dienst neu ..."
if systemctl is-active --quiet ssh 2>/dev/null; then
  systemctl reload ssh
  echo "${LOG_PREFIX}  ✓  Dienst 'ssh' neu geladen (systemd)."
elif systemctl is-active --quiet sshd 2>/dev/null; then
  systemctl reload sshd
  echo "${LOG_PREFIX}  ✓  Dienst 'sshd' neu geladen (systemd)."
elif service ssh reload &>/dev/null; then
  echo "${LOG_PREFIX}  ✓  Dienst 'ssh' neu geladen (SysV)."
else
  echo "${LOG_PREFIX} ⚠  SSH-Dienst konnte nicht automatisch neu geladen werden."
  echo "${LOG_PREFIX}    Bitte manuell ausfuehren: systemctl reload sshd"
fi

# =============================================================================
#  ZUSAMMENFASSUNG
# =============================================================================
print_header "SSH Hardening abgeschlossen"

if [[ -n "$NEW_USER_CREATED" ]]; then
  echo "  ✓  Benutzer:            '${NEW_USER_CREATED}' neu angelegt"
elif [[ -n "$TARGET_USER" ]]; then
  echo "  ✓  Benutzer:            '${TARGET_USER}' verwendet"
else
  echo "  ⚠  Benutzer:            kein Benutzer ausgewaehlt"
fi

if [[ "$KEY_CHOICE" == "1" && $ADDED -gt 0 ]]; then
  echo "  ✓  SSH Key:             ${ADDED} Key(s) fuer '${TARGET_USER}' hinterlegt"
else
  echo "  ⚠  SSH Key:             nicht eingetragen — bitte manuell nachholen!"
fi

echo "  ✓  Root-Login:          deaktiviert"
echo "  ✓  Passwort-Login:      deaktiviert"
echo "  ✓  Public-Key-Auth:     aktiviert"
echo "  ✓  Backup:              ${BACKUP}"

if [[ $ADDED -eq 0 ]]; then
  echo ""
  echo "  ⚠  WICHTIG: Stelle sicher, dass mindestens"
  echo "     ein gueltiger SSH-Key in"
  echo "     ~/.ssh/authorized_keys eingetragen ist,"
  echo "     BEVOR du dich ausloggst!"
fi

echo "════════════════════════════════════════════"
