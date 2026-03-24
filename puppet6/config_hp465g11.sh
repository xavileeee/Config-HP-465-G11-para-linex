#!/usr/bin/env bash
# =============================================================================
#  CONFIGURACIÓN HP ProBook 465 G11 — Xubuntu 24.04 / Linex Cole 2025
#  Autoría: Javier Alfonso de las Heras & Gemini & Cracks del grupo adminies
#  Versión: v2.6 (Robust Edition + hardening de homes) · Fecha: 24/03/26
#  Requiere Puppet 6 (o similar)
#
#  Funcionalidades
#  ─ Hostname único y /etc/hosts → puppetinstituto
#  ─ Usuarios base (root/linex) y cliente LDAP
#  ─ Puppet preparado (wrapper + facts) y saneado de puppet.conf (pluginsync)
#  ─ **PKI robusta Puppet**:
#       · Sincroniza CA/CRL desde el puppetserver (API HTTPS)
#       · Limpieza determinista local de SSL
#       · Limpieza en **CA remota** por SSH (opcional)
#  ─ pkgsync diario; Firefox desde PPA mozillateam (sin snap)
#  ─ Perfil XFCE copiado a /etc/skel
#  ─ Deshabilitar xfce4-screensaver
#  ─ Ajuste de timeout GRUB
#  ─ Reparar lanzadores de Firefox en XFCE (panel/skel/usuario)
#  ─ Clonar panel XFCE de linex a root
#  ─ Perfil Wi‑Fi EDUCAREX (NetworkManager)
#
#  Uso: sudo -i && bash /root/config_hp465g11.sh
# =============================================================================

set -Eeuo pipefail

# --- [00] AUTO-ELEVACIÓN DE PRIVILEGIOS ---
if [[ $EUID -ne 0 ]]; then
    echo "Elevando privilegios para configuración del IES..."
    sudo "$0" "$@"
    exit $?
fi

### =============================
### [00] PARÁMETROS GLOBALES
### =============================
ROOT_USER="root"
read -s -p "🔑 Introduce contraseña para root local: " ROOT_PW; echo
LINUX_USER="linex"
read -s -p "👤 Introduce contraseña para usuario linex local: " LINUX_PW; echo

read -p "🌐 Introduce IP del puppetserver (ej: 172.9.10.2): " PUPPET_HOST_IP
# PUPPET_HOST_IP="172.2.60.2"  # (Opcional) fija aquí la IP si prefieres no preguntar
PUPPETSERVER_FQDN="puppetinstituto"

# Limpieza/Firma remota en Puppetserver (CA local del centro)
PUPPET_CA_SSH=true
read -p "🖧 Introduce el host SSH del puppetserver (ej: servidor.saenzdeburuaga): " PUPPET_SSH_HOST
# PUPPET_SSH_HOST="servidor.saenzdeburuaga"  # (Opcional) fija aquí el hostname si prefieres no preguntar
PUPPET_SSH_USER="root"
# PUPPET_SSH_PASS="<password root servidor>"  # (Opcional) fija aquí la contraseña si prefieres no preguntar
PUPPET_SSH_PASS=""
read -s -p "🔐 Introduce contraseña SSH para ${PUPPET_SSH_USER}@${PUPPET_SSH_HOST}: " PUPPET_SSH_PASS; echo

CREATE_ESC_20=true
RUN_PUPPET_AGENT=true
HARDEN_EXISTING_HOMES_PERMS=true

FIX_PKG_SYNC=true
PKGSYNC_VER="2.57-1"
PKGSYNC_URL="https://github.com/algodelinux/pkgsync/releases/download/v2.57-1/pkgsync_2.57-1_all.deb"

SET_GRUB_TIMEOUT=true
GRUB_TIMEOUT_VALUE="1"

COPY_XFCE_PROFILE_FROM_LINEX_TO_SKEL=true
DISABLE_XFCE_SCREENSAVER=true

INSTALL_FIREFOX_FROM_MOZILLA_PPA=true
APPLY_PUPPET_SNIPPET=true

CONFIG_EDUCAREX_WIFI=true
EDUCAREX_SSID="educarex"
read -p "👤 Introduce identidad EDUCAREX (ej: saenzdeburuaga): " EDUCAREX_IDENTITY
# EDUCAREX_IDENTITY="saenzdeburuaga"  # (Opcional) fija aquí la identidad si prefieres no preguntar
EDUCAREX_PASSWORD=""
read -s -p "📶 Introduce contraseña WiFi EDUCAREX (${EDUCAREX_SSID}): " EDUCAREX_PASSWORD; echo
# EDUCAREX_PASSWORD="<password>"  # (Opcional) fija aquí la contraseña si prefieres no preguntar

LOG="/var/log/config_hp465g11.log"
exec > >(tee -a "$LOG") 2>&1

### =============================
### [01] UTILIDADES COMUNES
### =============================
TOTAL_STEPS=16
STEP=0

ts(){ date +'%F %T'; }
ok(){ STEP=$((STEP+1)); echo "[$(ts)] ✅ [$STEP/$TOTAL_STEPS] $*"; }
info(){ echo "[$(ts)] $*"; }
warn(){ echo "[$(ts)] ⚠️ $*"; }
err(){ echo "[$(ts)] ❌ $*"; }
ensure_dir(){ mkdir -p "$1"; chmod "${2:-755}" "$1"; chown ${3:-root:root} "$1"; }
get_mac_file(){ local i="$1"; [ -e "/sys/class/net/${i}/address" ] && cat "/sys/class/net/${i}/address"; }
get_ipv4_of(){ ip -4 -o addr show dev "$1" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1; }
file_contains(){ [[ -f "$1" ]] && grep -qE "$2" "$1"; }

enforce_pam_mkhomedir_umask(){
  local pam_file="/etc/pam.d/common-session"
  local desired_line="session optional        pam_mkhomedir.so umask=0027 skel=/etc/skel"

  if [ ! -f "$pam_file" ]; then
    warn "No existe ${pam_file}; se omite ajuste de pam_mkhomedir"
    return 0
  fi

  if grep -qE '^[[:space:]]*session[[:space:]]+optional[[:space:]]+pam_mkhomedir\.so' "$pam_file"; then
    sed -ri 's|^[[:space:]]*session[[:space:]]+optional[[:space:]]+pam_mkhomedir\.so.*$|session optional        pam_mkhomedir.so umask=0027 skel=/etc/skel|' "$pam_file"
  else
    printf '\n%s\n' "$desired_line" >> "$pam_file"
  fi

  info "Ajustado pam_mkhomedir con umask=0027 en ${pam_file}"
}

harden_existing_homes_permissions(){
  local user uid home shell desktop_dir

  while IFS=: read -r user _ uid _ _ home shell; do
    [ "${uid}" -ge 1000 ] || continue
    [ "${uid}" -eq 65534 ] && continue
    case "${shell}" in
      */false|*/nologin) continue ;;
    esac

    home="$(normalize_home_dir_path "$home")"
    [ -d "$home" ] || continue

    chown "$user:$user" "$home" 2>/dev/null || warn "No se pudo ajustar propietario de ${home}"
    chmod 700 "$home" 2>/dev/null || warn "No se pudo aplicar chmod 700 a ${home}"

    for desktop_dir in "$home/Desktop" "$home/Escritorio"; do
      [ -d "$desktop_dir" ] || continue
      chown -R "$user:$user" "$desktop_dir" 2>/dev/null || warn "No se pudo ajustar propietario en ${desktop_dir}"
      chmod -R go-rwx "$desktop_dir" 2>/dev/null || warn "No se pudieron restringir permisos en ${desktop_dir}"
    done
  done < <(getent passwd)

  info "Permisos de homes existentes endurecidos (home=700 y Desktop/Escritorio sin acceso de grupo/otros)"
}

normalize_home_dir_path(){
  local p="${1:-}"
  p="${p%/}"
  case "$p" in
    /var/home/*) echo "/home/${p#/var/home/}" ;;
    /var7home/*) echo "/home/${p#/var7home/}" ;;
    /va7home/*) echo "/home/${p#/va7home/}" ;;
    *) echo "$p" ;;
  esac
}

get_user_home_dir(){
  local u="$1" passwd_home="" normalized_home="" cand=""
  passwd_home="$(getent passwd "$u" | awk -F: '{print $6}' 2>/dev/null || true)"
  normalized_home="$(normalize_home_dir_path "$passwd_home")"

  for cand in "$passwd_home" "$normalized_home" "/home/${u}" "/var/home/${u}"; do
    [ -n "${cand:-}" ] || continue
    if [ -d "$cand" ]; then
      echo "$cand"
      return 0
    fi
  done

  if [ -n "$normalized_home" ]; then
    echo "$normalized_home"
  elif [ -n "$passwd_home" ]; then
    echo "$passwd_home"
  else
    echo "/home/${u}"
  fi
}

repair_user_home_if_needed(){
  local u="$1" passwd_home="" normalized_home=""
  passwd_home="$(getent passwd "$u" | awk -F: '{print $6}' 2>/dev/null || true)"
  [ -n "$passwd_home" ] || return 0

  normalized_home="$(normalize_home_dir_path "$passwd_home")"
  [ -n "$normalized_home" ] || return 0
  [ "$normalized_home" != "$passwd_home" ] || return 0

  info "Corrigiendo home de ${u} en /etc/passwd: ${passwd_home} -> ${normalized_home}"
  ensure_dir "$(dirname "$normalized_home")" 755 root:root
  if [ -d "$passwd_home" ] && [ ! -e "$normalized_home" ]; then
    usermod -d "$normalized_home" -m "$u" 2>/dev/null || warn "No se pudo mover home de ${u} a ${normalized_home}"
  else
    usermod -d "$normalized_home" "$u" 2>/dev/null || warn "No se pudo actualizar home de ${u} a ${normalized_home}"
  fi
}

ssh_run(){
  sshpass -p "$PUPPET_SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "${PUPPET_SSH_USER}@${PUPPET_SSH_HOST}" "$1"
}

trap 'err "Fallo en línea $LINENO: $BASH_COMMAND"' ERR

### =============================
### [02] INICIO
### =============================
info "Iniciando configuración HP 465 G11 (v2.6)..."

if grep -q "SECLEVEL=2" /etc/ssl/openssl.cnf; then
    sed -i 's/SECLEVEL=2/SECLEVEL=1/g' /etc/ssl/openssl.cnf
    info "Seguridad OpenSSL ajustada a SECLEVEL=1."
fi

### =============================
### [03] Repositorios y herramientas
### =============================
for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
  [ -f "$f" ] && sed -ri 's|^(deb\s+[^#]*linex\.educarex\.es/ubuntu/noble\b.*)$|# \1|g' "$f"
done

apt-get update -y || true
# Reparación de base para evitar bloqueos
DEBIAN_FRONTEND=noninteractive apt-get install -f -y
DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades \
  software-properties-common apt-transport-https ca-certificates \
  openssl wget curl openssh-client sshpass jq network-manager uuid-runtime rsync net-tools || true
ok "Herramientas base instaladas."

### =============================
### [04] Hostname único
### =============================
# Generamos un nombre único y reproducible basado en UUID/MAC. Si ya existe
# un hostname con prefijo hp465g11-*, se considera válido y no se altera.
uuid="$(tr '[:upper:]' '[:lower:]' </sys/class/dmi/id/product_uuid 2>/dev/null | tr -d '\n' || true)"
if [[ -z "${uuid:-}" || "${uuid}" = "ffffffff-ffff-ffff-ffff-ffffffffffff" ]]; then
  fallback=""
  for i in /sys/class/net/*; do
    [ -d "$i" ] || continue
    iface="$(basename "$i")"; [ "$iface" = "lo" ] && continue
    mac="$(get_mac_file "$iface" | tr -d '\n')"
    [[ -n "$mac" && "$mac" != "00:00:00:00:00:00" ]] && { fallback="${mac//:/}"; break; }
  done
  uuid="${fallback:-$(tr -dc 'a-f0-9' </dev/urandom | head -c8)}"
fi
short="${uuid//-/}"
newhost="hp465g11-${short:0:8}"
current_host="$(hostname)"

if [[ "$current_host" =~ ^hp465g11-[0-9a-fA-F]+$ ]]; then
  info "Hostname actual válido: ${current_host}"
else
  hostnamectl set-hostname "$newhost"
  if grep -q '^127\.0\.1\.1' /etc/hosts; then
    sed -ri "s|^127\.0\.1\.1\s+.*$|127.0.1.1 ${newhost}|" /etc/hosts
  else
    echo "127.0.1.1 ${newhost}" >> /etc/hosts
  fi
  ok "Hostname configurado: ${newhost}"
fi

### =============================
### [05] Usuarios (root/linex) y sudo
### =============================
echo "root:${ROOT_PW}" | chpasswd
id "${LINUX_USER}" &>/dev/null || useradd -m -s /bin/bash "${LINUX_USER}"
echo "${LINUX_USER}:${LINUX_PW}" | chpasswd
repair_user_home_if_needed "${LINUX_USER}"
LINEX_HOME="$(get_user_home_dir "${LINUX_USER}")"
info "Home detectado para ${LINUX_USER}: ${LINEX_HOME}"
if $HARDEN_EXISTING_HOMES_PERMS; then
  harden_existing_homes_permissions
fi
ok "Usuarios root/linex configurados."

deluser "${LINUX_USER}" sudo 2>/dev/null || gpasswd -d "${LINUX_USER}" sudo 2>/dev/null || true

### =============================
### [06] Cliente LDAP
### =============================
DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall linex-config-ldapclient || true
enforce_pam_mkhomedir_umask
ok "Cliente LDAP configurado."

### =============================
### [07] /etc/hosts → puppetinstituto
### =============================
if grep -q 'puppetinstituto' /etc/hosts; then
  sed -i "s/^[0-9.\t ]*puppetinstituto/${PUPPET_HOST_IP} puppetinstituto/" /etc/hosts
else
  echo "${PUPPET_HOST_IP} puppetinstituto" >> /etc/hosts
fi
ok "Red puppetinstituto apuntando a ${PUPPET_HOST_IP}."

### =============================
### [08] Puppet: wrapper + facts
### =============================
[[ ! -x /usr/bin/puppet && -x /opt/puppetlabs/bin/puppet ]] && cp -v /opt/puppetlabs/bin/puppet /usr/bin/ || true
ensure_dir /opt/puppetlabs/facter/facts.d 755 root:root

cat >/opt/puppetlabs/facter/facts.d/leefichero.sh <<'__FACTER__'
#!/bin/bash
[ -f /etc/escuela2.0 ] && sed 's/[[:space:]]//g' /etc/escuela2.0 | grep "=" || true
__FACTER__
chmod 755 /opt/puppetlabs/facter/facts.d/leefichero.sh

if $CREATE_ESC_20; then
  echo -e "SISTEMA=ubuntu2404\nUSO=portatiles\nUSUARIO=alumno\nHARDWARE=notebookHPG11" > /etc/escuela2.0
fi
ok "Puppet y Facts listos."

### =============================
### [09] puppet.conf: limpiar 'pluginsync'
### =============================
PUPPET_CONF="/etc/puppetlabs/puppet/puppet.conf"
if [[ -f "$PUPPET_CONF" ]]; then
  if grep -qE '^[[:space:]]*pluginsync[[:space:]]*=' "$PUPPET_CONF"; then
    sed -i '/^[[:space:]]*pluginsync[[:space:]]*=/d' "$PUPPET_CONF"
    ok "Eliminado parámetro pluginsync de puppet.conf"
  else
    ok "Sin parámetro pluginsync en puppet.conf"
  fi
else
  ok "puppet.conf no encontrado; se omite limpieza de pluginsync"
fi

### =============================
### [11-13] PKI Puppet
### =============================
ssl_paths(){
  CN="$(/opt/puppetlabs/bin/puppet config print certname 2>/dev/null || hostname -f)"
  SSLDIR="$(/opt/puppetlabs/bin/puppet config print ssldir 2>/dev/null || echo /etc/puppetlabs/puppet/ssl)"
}
ssl_paths

### =============================
### [13] SSL: reset con CA sincronizada y reintentos
### =============================
# Sincronización CA
ensure_dir "/etc/puppetlabs/puppet/ssl/certs" 755 root:root
curl -fsS -k "https://${PUPPETSERVER_FQDN}:8140/puppet-ca/v1/certificate/ca" >"/etc/puppetlabs/puppet/ssl/certs/ca.pem" || warn "Fallo descarga CA"

# Reset SSL si es necesario
if /opt/puppetlabs/bin/puppet ssl verify --server ${PUPPETSERVER_FQDN} >/dev/null 2>&1; then
  ok "SSL Puppet ya es válido."
else
  info "Reseteando SSL Puppet..."
  if $PUPPET_CA_SSH; then
    ssh_run "/opt/puppetlabs/bin/puppetserver ca clean --certname ${CN} 2>/dev/null || true"
  fi
  rm -rf "$SSLDIR"/* 2>/dev/null || true
  /opt/puppetlabs/bin/puppet ssl bootstrap --server ${PUPPETSERVER_FQDN} --waitforcert 15 || true
  ok "SSL Puppet resincronizado."
fi

### =============================
### [14] Ejecutar puppet agent -tv
### =============================
if $RUN_PUPPET_AGENT; then /opt/puppetlabs/bin/puppet agent -tv || true; fi

### =============================
### [15] pkgsync (instalación + cron diario)
### =============================
if $FIX_PKG_SYNC; then
  wget -q -O /tmp/pkgsync.deb "$PKGSYNC_URL"
  apt-get install -y /tmp/pkgsync.deb || apt-get install -f -y
  ok "pkgsync configurado."
fi

### =============================
### [16] Firefox .deb desde repo oficial de Mozilla (no Snap)
### =============================
if $INSTALL_FIREFOX_FROM_MOZILLA_PPA; then
  info "Instalando Firefox .deb oficial..."
  snap remove --purge firefox || true

  install -d -m 0755 /usr/share/keyrings
  curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg | gpg --dearmor --yes -o /usr/share/keyrings/packages.mozilla.org.gpg
  echo "deb [signed-by=/usr/share/keyrings/packages.mozilla.org.gpg] https://packages.mozilla.org/apt mozilla main" > /etc/apt/sources.list.d/mozilla-official.list

  cat >/etc/apt/preferences.d/moz-official-firefox <<'EOF'
Package: firefox*
Pin: origin packages.mozilla.org
Pin-Priority: 1001
EOF
  # CLAVE: --allow-downgrades para evitar el fallo de versiones
  apt-get update -y && apt-get install -y --allow-downgrades firefox
  ok "Firefox .deb oficial instalado."
fi

### =============================
### [17] XFCE → /etc/skel
if $COPY_XFCE_PROFILE_FROM_LINEX_TO_SKEL; then
  if [[ -d "${LINEX_HOME}/.config/xfce4" ]]; then
    ensure_dir /etc/skel/.config 755 root:root
    rm -rf /etc/skel/.config/xfce4
    cp -a "${LINEX_HOME}/.config/xfce4" /etc/skel/.config/
    chown -R root:root /etc/skel/.config
    ok "Perfil XFCE copiado a /etc/skel"
  else
    ok "Perfil XFCE no existe en ${LINEX_HOME}; nada que copiar"
  fi
else
  ok "Copia de perfil XFCE omitida"
fi

### =============================
### [18] Deshabilitar xfce4-screensaver
if $DISABLE_XFCE_SCREENSAVER; then
  chmod -x /usr/bin/xfce4-screensaver 2>/dev/null || true
  ensure_dir /etc/xdg/autostart 755 root:root
  if [[ -f /etc/xdg/autostart/xfce4-screensaver.desktop ]]; then
    sed -i 's/^Hidden=.*/Hidden=true/; t; $aHidden=true' /etc/xdg/autostart/xfce4-screensaver.desktop
  fi
  pkill -x xfce4-screensaver 2>/dev/null || true
  ok "Salvapantallas deshabilitado"
else
  ok "Salvapantallas se deja sin cambios"
fi

### =============================
### [19] GRUB timeout
if $SET_GRUB_TIMEOUT && [[ -f /etc/default/grub ]]; then
  if file_contains /etc/default/grub '^GRUB_TIMEOUT='; then
    sed -i "s/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=${GRUB_TIMEOUT_VALUE}/" /etc/default/grub
  else
    echo "GRUB_TIMEOUT=${GRUB_TIMEOUT_VALUE}" >> /etc/default/grub
  fi
fi

if command -v update-grub >/dev/null 2>&1; then
  update-grub || true
  ok "GRUB regenerado"
elif command -v update-grub2 >/dev/null 2>&1; then
  update-grub2 || true
  ok "GRUB regenerado"
else
  ok "GRUB omitido (no existe update-grub/update-grub2)"
fi

### =============================
### [20] Reparar lanzador XFCE de Firefox (Snap → .deb)

# 1) Asegurar .desktop correcto del Firefox .deb
if [ -f /var/lib/snapd/desktop/applications/firefox_firefox.desktop ]; then
  rm -f /var/lib/snapd/desktop/applications/firefox_firefox.desktop || true
fi
if [ ! -f /usr/share/applications/firefox.desktop ]; then
  warn "No se encuentra /usr/share/applications/firefox.desktop (¿instalación de Firefox correcta?)."
fi

# 2) Función: reescribir lanzadores XFCE para un usuario dado
_fix_firefox_launcher_for_user() {
  local U="$1"
  local HOME_DIR
  HOME_DIR="$(get_user_home_dir "$U")"
  [ -d "$HOME_DIR/.config/xfce4/panel" ] || return 0

  # Borrar entradas obsoletas (snap/BAMF) de los launchers del panel
  for d in "$HOME_DIR/.config/xfce4/panel"/launcher-*; do
    [ -d "$d" ] || continue

    # Elimina ficheros .desktop problemáticos si existen (sin fallar si no hay coincidencias)
    find "$d" -maxdepth 1 -type f -name '*.desktop' -print0 \
      | xargs -0 -r grep -lZ -E 'BAMF_DESKTOP_FILE_HINT|snap/firefox|^Exec=.*snap|^TryExec=.*snap' 2>/dev/null \
      | xargs -0 -r rm -f || true

    # Si no queda ningún .desktop válido de Firefox, añádelo
    if ! grep -Rqs '^Exec=.*firefox' "$d" 2>/dev/null; then
      ln -sf /usr/share/applications/firefox.desktop "$d/firefox.desktop"
    fi
  done

  # Propietario correcto
  chown -R "$U:$U" "$HOME_DIR/.config/xfce4/panel" 2>/dev/null || true
}

# 3) Aplicar a usuarios existentes de interés (ajusta la lista si procede)
for usr in "linex" ; do
  id "$usr" &>/dev/null && _fix_firefox_launcher_for_user "$usr"
done
# Opcional: también para root si usas su panel
[ -d /root/.config/xfce4/panel ] && _fix_firefox_launcher_for_user "root"

# 4) Preparar el perfil por defecto (usuarios nuevos)
mkdir -p /etc/skel/.config/xfce4/panel
# Crear un launcher genérico si no existe ninguno para Firefox
if ! grep -Rqs '^Exec=.*firefox' /etc/skel/.config/xfce4/panel 2>/dev/null; then
  # Crea un directorio de lanzador si no existe
  skel_ldir="$(ls -d /etc/skel/.config/xfce4/panel/launcher-* 2>/dev/null | head -n1)"
  if [ -z "$skel_ldir" ]; then
    skel_ldir="/etc/skel/.config/xfce4/panel/launcher-$(date +%s)"
    mkdir -p "$skel_ldir"
  fi
  ln -sf /usr/share/applications/firefox.desktop "$skel_ldir/firefox.desktop"
fi

# 5) Fijar Firefox como navegador por defecto del sistema
if command -v update-alternatives >/dev/null 2>&1; then
  update-alternatives --install /usr/bin/x-www-browser x-www-browser /usr/bin/firefox 200 || true
  update-alternatives --set x-www-browser /usr/bin/firefox || true
fi
# Preferencia de escritorio (si hay sesión gráfica lo tomará en el próximo login)
command -v xdg-settings >/dev/null 2>&1 && xdg-settings set default-web-browser firefox.desktop 2>/dev/null || true

# 6) Actualizar caches de escritorio/íconos (evita icono roto)
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database /usr/share/applications 2>/dev/null || true
[ -x /usr/bin/gtk-update-icon-cache ] && gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true

ok "Lanzador XFCE de Firefox reparado (panel, navegador por defecto y skel). Se aplicará al volver a iniciar sesión."

### =============================
### [20.1] Reparar lanzador de Firefox para usuarios locales
PANEL_SRC_DIR="${LINEX_HOME}/.config/xfce4/panel"
PANEL_SRC_XML="${LINEX_HOME}/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml"

fix_firefox_user() {
  local U="$1" HOME_DIR
  HOME_DIR="$(get_user_home_dir "$U")"
  [ -d "$HOME_DIR" ] || return 0
  [ -f /usr/share/applications/firefox.desktop ] || return 0

  # Forzar panel igual que linex en usuarios existentes
  if [ -d "$PANEL_SRC_DIR" ]; then
    ensure_dir "$HOME_DIR/.config/xfce4/panel" 700 "$U:$U"
    rsync -a --delete "$PANEL_SRC_DIR/" "$HOME_DIR/.config/xfce4/panel/" 2>/dev/null || true
  fi
  if [ -f "$PANEL_SRC_XML" ]; then
    ensure_dir "$HOME_DIR/.config/xfce4/xfconf/xfce-perchannel-xml" 700 "$U:$U"
    cp -f "$PANEL_SRC_XML" "$HOME_DIR/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml" 2>/dev/null || true
  fi

  # Si el usuario no tiene perfil XFCE, sembrarlo desde /etc/skel
  if [ ! -d "$HOME_DIR/.config/xfce4" ] && [ -d /etc/skel/.config/xfce4 ]; then
    ensure_dir "$HOME_DIR/.config" 755 "$U:$U"
    cp -a /etc/skel/.config/xfce4 "$HOME_DIR/.config/" 2>/dev/null || true
    chown -R "$U:$U" "$HOME_DIR/.config/xfce4" 2>/dev/null || true
  fi

  # 1) Limpiar .desktop antiguos (snap/BAMF) en launchers del panel
  for d in "$HOME_DIR/.config/xfce4/panel"/launcher-*; do
    [ -d "$d" ] || continue
    find "$d" -maxdepth 1 -type f -name '*.desktop' -print0 \
      | xargs -0 -r grep -lZ -E 'BAMF_DESKTOP_FILE_HINT|snap/firefox|^Exec=.*snap|^TryExec=.*snap|firefox_firefox\.desktop' 2>/dev/null \
      | xargs -0 -r rm -f || true
    ln -sf /usr/share/applications/firefox.desktop "$d/firefox.desktop"
  done

  # 2) Corregir favoritos del Docklike Taskbar (si existe)
  find "$HOME_DIR/.config/xfce4/panel" -maxdepth 1 -type f -name 'docklike-*.rc' -print0 \
    | xargs -0 -r sed -i 's/firefox_firefox\.desktop/firefox.desktop/g'

  # 3) Navegador por defecto a nivel usuario
  runuser -l "$U" -c 'xdg-settings set default-web-browser firefox.desktop' 2>/dev/null || true

  # 4) Limpiar caché del plugin y permisos correctos
  rm -rf "$HOME_DIR/.cache/xfce4/docklike-plugin" 2>/dev/null || true
  chown -R "$U:$U" "$HOME_DIR/.config" "$HOME_DIR/.cache" 2>/dev/null || true

  # 5) Si el panel está corriendo, cerrarlo para que se regenere al próximo login
  pkill -u "$U" -x xfce4-panel 2>/dev/null || true
}

for usr in $(getent passwd | awk -F: -v src="$LINUX_USER" '$3>=1000 && $1!="nobody" && $1!=src && $7!~/(nologin|false)/{print $1}'); do
  fix_firefox_user "$usr"
done

ok "Lanzador de Firefox reparado para usuarios locales."


### =============================
### [XFCE] Clonar panel de 'linex' a 'root'
info "Clonando configuración de panel XFCE desde 'linex' hacia 'root'…"

SRC_HOME="${LINEX_HOME}"
SRC_DIR="${SRC_HOME}/.config/xfce4"
DST_DIR="/root/.config/xfce4"

# 1) Comprobaciones y herramientas mínimas
if [ ! -d "${SRC_DIR}" ]; then
  warn "No existe ${SRC_DIR}. ¿El usuario 'linex' tiene perfil XFCE creado? Se omite."
else
  DEBIAN_FRONTEND=noninteractive apt-get install -y rsync || true

  # 2) Copia de seguridad del perfil XFCE actual de root (por si hay que volver atrás)
  ts="$(date +%s)"
  if [ -d "${DST_DIR}" ]; then
    tar czf "/root/xfce4.root.backup.${ts}.tgz" -C /root .config/xfce4 2>/dev/null || true
    info "Backup del panel de root: /root/xfce4.root.backup.${ts}.tgz"
  fi

  # 3) Copiar perfil XFCE de 'linex' preservando estructura
  mkdir -p "${DST_DIR}"
  rsync -a --delete "${SRC_DIR}/" "${DST_DIR}/"

  # 4) Reescribir rutas absolutas del perfil de linex -> /root dentro del perfil
  #    (lançadores .desktop, configuraciones del panel, etc.)
  if command -v sed >/dev/null 2>&1; then
    find "${DST_DIR}" -maxdepth 4 -type f -print0 \
      | xargs -0 sed -ri \
          -e "s#/home/${LINUX_USER}#/root#g" \
          -e "s#/var/home/${LINUX_USER}#/root#g" \
          -e "s#/var7home/${LINUX_USER}#/root#g" \
          -e "s#/va7home/${LINUX_USER}#/root#g" || true
  fi

  # 5) Propiedad/permiso correctos para root
  chown -R root:root "${DST_DIR}" 2>/dev/null || true

  # 6) Si el panel de root está corriendo, cerrarlo para que se regenere al próximo login
  pkill -u root -x xfce4-panel 2>/dev/null || true

  ok "Panel de root clonado desde el perfil de 'linex'."
fi

### =============================
### [22] EDUCAREX (NetworkManager) — cambios diferidos
### =============================
if $CONFIG_EDUCAREX_WIFI; then
  cat >/etc/NetworkManager/system-connections/educarex.nmconnection <<EOF
[connection]
id=educarex
type=wifi
[wifi]
ssid=educarex
[wifi-security]
key-mgmt=wpa-eap
[802-1x]
eap=peap;
identity=${EDUCAREX_IDENTITY}
password=${EDUCAREX_PASSWORD}
phase2-auth=gtc
EOF
  chmod 600 /etc/NetworkManager/system-connections/educarex.nmconnection
  nmcli connection load /etc/NetworkManager/system-connections/educarex.nmconnection || true
  ok "WiFi EDUCAREX lista."
fi

info "Configuración finalizada. Revisa el log en $LOG"

### =============================
### [22] Informe final
### =============================
wifi_iface=""; for i in /sys/class/net/*; do [ -d "$i" ] || continue; b="$(basename "$i")"; [ -d "/sys/class/net/${b}/wireless" ] && { wifi_iface="$b"; break; }; done
wired_iface=""; for i in /sys/class/net/*; do [ -d "$i" ] || continue; b="$(basename "$i")"; [ -d "/sys/class/net/${b}/wireless" ] && continue; [ "$b" = "lo" ] && continue; if [ -f "/sys/class/net/${b}/type" ] && [ "$(cat /sys/class/net/${b}/type)" = "1" ]; then case "$b" in br*|vir*|vmnet*|veth*|docker*|tun*|tap*) continue;; esac; wired_iface="$b"; break; fi; done
wired_mac="$( [ -n "${wired_iface}" ] && get_mac_file "${wired_iface}" || echo "" )"
wifi_mac="$(  [ -n "${wifi_iface}"  ] && get_mac_file "${wifi_iface}"  || echo "" )"
wired_ip="$( [ -n "${wired_iface}" ] && get_ipv4_of "${wired_iface}" || echo "" )"
wifi_ip="$(  [ -n "${wifi_iface}"  ] && get_ipv4_of "${wifi_iface}"  || echo "" )"
CN_FINAL="$([ -x /opt/puppetlabs/bin/puppet ] && /opt/puppetlabs/bin/puppet config print certname 2>/dev/null || hostname -f)"

cat <<__RPT__
---------------------------------------------
🖥️  Hostname final: $(hostname)
📛 Certname Puppet: ${CN_FINAL}
🔍  Red:
    Interfaz cable: ${wired_iface:-no detectada}
    MAC cableada:   ${wired_mac:-no detectada}
    IP cableada:    ${wired_ip:-no detectada}
    Interfaz Wi‑Fi: ${wifi_iface:-no detectada}
    MAC Wi‑Fi:      ${wifi_mac:-no detectada}
    IP Wi‑Fi:       ${wifi_ip:-no detectada}
---------------------------------------------
🧪 ${PUPPETSERVER_FQDN} → $(getent hosts ${PUPPETSERVER_FQDN} | awk '{print $1; exit}') (esperado: ${PUPPET_HOST_IP})
🗂  Log: ${LOG}
✅  RECUERDA REINICIAR EL EQUIPO
__RPT__