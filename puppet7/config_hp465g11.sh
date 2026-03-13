#!/usr/bin/env bash
# =============================================================================
#  CONFIGURACIÓN HP ProBook 465 G11 — Xubuntu 24.04 / Linex Cole 2025
#  Autoría: Javier Alfonso de las Heras & ChatGPT & Cracks del grupo adminies
#  Mención: Víctor Martínez, José Manuel Carrero, Carlos Fernández Díaz, Cristina Tapias, Fernando Barrena, Juan Alfonso Pastor y todos los compañeros de adminies
#  Versión: v2.3 (nueva versión) · Fecha: 11/03/26
#  Requiere Puppet 7 o posterior
#
#  Funcionalidades
#  ─ Hostname único y /etc/hosts → puppetinstituto
#  ─ Usuarios base (root/linex) y cliente LDAP
#  ─ Puppet preparado (wrapper + facts) y saneado de puppet.conf (pluginsync)
#  ─ **PKI robusta Puppet**:
#       · Sincroniza CA/CRL desde el puppetserver (API HTTPS)
#       · Limpieza determinista local de SSL
#       · Limpieza en **CA remota** por SSH con verificación JSON (jq)
#       · Reintentos ante conflictos y verificación cert↔clave (OpenSSL)
#  ─ pkgsync diario; Firefox desde PPA mozillateam (sin snap)
#  ─ Ajustes XFCE, deshabilitar salvapantallas, timeout GRUB
#  ─ Perfil Wi‑Fi EDUCAREX (NetworkManager) con cambios diferidos a reinicio
#  ─ Informe final de red y estado Puppet
#
#  Uso: sudo -i && bash /root/config_hp465g11.sh
# =============================================================================

set -Eeuo pipefail

### =============================
### [00] PARÁMETROS GLOBALES
### =============================

ROOT_USER="root"
read -s -p "🔑 Introduce contraseña para root local: " ROOT_PW; echo
LINUX_USER="linex"
read -s -p "👤 Introduce contraseña para usuario linex local: " LINUX_PW; echo

read -p "🌐 Introduce IP del puppetserver (ej: 172.2.60.2): " PUPPET_HOST_IP
# PUPPET_HOST_IP="172.2.60.2"     # (Opcional) fija aquí la IP si prefieres no preguntar
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

read -s -p "📶 Introduce contraseña WiFi EDUCAREX (${EDUCAREX_SSID}): " EDUCAREX_PASSWORD; echo
# EDUCAREX_PASSWORD="<contraseña>"  # (Opcional) fija aquí la contraseña si prefieres no preguntar


LOG="/var/log/config_hp465g11.log"
exec > >(tee -a "$LOG") 2>&1

### =============================
### [01] UTILIDADES COMUNES
### =============================
TOTAL_STEPS=21
STEP=0

ts(){ date +'%F %T'; }
ok(){ STEP=$((STEP+1)); echo "[$(ts)] ✅ [$STEP/$TOTAL_STEPS] $*"; }
info(){ echo "[$(ts)] $*"; }
warn(){ echo "[$(ts)] ⚠️ $*"; }
err(){ echo "[$(ts)] ❌ $*"; }
require_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || { err "Ejecuta como root"; exit 1; }; }
ensure_dir(){ mkdir -p "$1"; chmod "${2:-755}" "$1"; chown ${3:-root:root} "$1"; }
file_contains(){ [[ -f "$1" ]] && grep -qE "$2" "$1"; }
get_mac_file(){ local i="$1"; [ -e "/sys/class/net/${i}/address" ] && cat "/sys/class/net/${i}/address"; }
get_ipv4_of(){ ip -4 -o addr show dev "$1" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1; }
ssh_run(){  # ssh_run "comando"
  sshpass -p "$PUPPET_SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "${PUPPET_SSH_USER}@${PUPPET_SSH_HOST}" "$1"
}
# Abort controlado
trap 'err "Fallo en línea $LINENO: $BASH_COMMAND"' ERR

### =============================
### [02] INICIO
### =============================
require_root
info "Iniciando configuración HP 465 G11 (v2.3)…"

### =============================
### [03] Repos y herramientas base
### =============================
info "Revisando repos y herramientas…"
for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
  [ -f "$f" ] || continue
  sed -ri 's|^(deb\s+[^#]*linex\.educarex\.es/ubuntu/noble\b.*)$|# \1|g' "$f"
done
apt-get update -y || true
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  software-properties-common apt-transport-https ca-certificates \
  openssl wget curl openssh-client sshpass jq network-manager uuid-runtime || true
ok "Repos y herramientas listos"

### =============================
### [04] Hostname único
### =============================
uuid="$(tr '[:upper:]' '[:lower:]' </sys/class/dmi/id/product_uuid 2>/dev/null | tr -d '\n' || true)"
if [[ -z "${uuid:-}" || "${uuid}" = "ffffffff-ffff-ffff-ffff-ffffffffffff" ]]; then
  fallback=""
  for i in /sys/class/net/*; do
    [ -d "$i" ] || continue; iface="$(basename "$i")"; [ "$iface" = "lo" ] && continue
    mac="$(get_mac_file "$iface" | tr -d '\n')"
    [[ -n "$mac" && "$mac" != "00:00:00:00:00:00" ]] && { fallback="${mac//:/}"; break; }
  done
  uuid="${fallback:-$(tr -dc 'a-f0-9' </dev/urandom | head -c8)}"
fi
short="${uuid//-/}"
newhost="hp465g11-${short:0:8}"
current_host="$(hostname)"
if [[ "$current_host" != "$newhost" ]]; then
  hostnamectl set-hostname "$newhost"
  if grep -q '^127\.0\.1\.1' /etc/hosts; then
    sed -ri "s|^127\.0\.1\.1\s+.*$|127.0.1.1 ${newhost}|" /etc/hosts
  else
    echo "127.0.1.1 ${newhost}" >> /etc/hosts
  fi
  ok "Hostname aplicado: $(hostname)"
else
  ok "Hostname ya correcto: ${newhost}"
fi

### =============================
### [05] Usuarios (root/linex) y sudo
### =============================
passwd -u root 2>/dev/null || true
echo "${ROOT_USER}:${ROOT_PW}" | chpasswd
if ! id "${LINUX_USER}" &>/dev/null; then useradd -m -s /bin/bash "${LINUX_USER}"; fi
if ! echo "${LINUX_USER}:${LINUX_PW}" | chpasswd 2>/dev/null; then
  HASH="$(openssl passwd -6 "${LINUX_PW}")"; usermod --password "${HASH}" "${LINUX_USER}"
fi
deluser "${LINUX_USER}" sudo 2>/dev/null || gpasswd -d "${LINUX_USER}" sudo 2>/dev/null || true
ok "Usuarios listos"

### =============================
### [06] Cliente LDAP
### =============================
DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall linex-config-ldapclient || true
ok "LDAP client reinstalado (o ya estaba)"

### =============================
### [07] /etc/hosts → puppetinstituto
### =============================
if grep -q 'puppetinstituto' /etc/hosts 2>/dev/null; then
  sed -i "s/^[0-9.\t ]*puppetinstituto/${PUPPET_HOST_IP} puppetinstituto/" /etc/hosts
else
  echo "${PUPPET_HOST_IP} puppetinstituto" >> /etc/hosts
fi
ok "/etc/hosts ajustado (${PUPPETSERVER_FQDN} → ${PUPPET_HOST_IP})"

### =============================
### [08] Puppet: wrapper + facts
### =============================
[[ ! -x /usr/bin/puppet && -x /opt/puppetlabs/bin/puppet ]] && cp -v /opt/puppetlabs/bin/puppet /usr/bin/ || true
ensure_dir /opt/puppetlabs/facter/facts.d 755 root:root
cat >/opt/puppetlabs/facter/facts.d/leefichero.sh <<'__FACTER__'
#!/bin/bash
if [ -e /etc/escuela2.0 ]; then
  while read -r linea; do
    LLIMPIA=$(echo "$linea" | tr -d " \t")
    VAR=$(echo "$LLIMPIA" | cut -f1 -d "=")
    VALOR=$(echo "$LLIMPIA" | cut -f2 -d "=")
    [ -n "$VAR" ] && [ -n "$VALOR" ] && echo "$VAR=$VALOR"
  done < /etc/escuela2.0
fi
__FACTER__
chmod 755 /opt/puppetlabs/facter/facts.d/leefichero.sh
ok "Puppet preparado (wrapper + facts)"

### =============================
### [09] puppet.conf: limpiar 'pluginsync'
### =============================
PUPPET_CONF="/etc/puppetlabs/puppet/puppet.conf"
if [[ -f "$PUPPET_CONF" ]]; then
  if grep -qE '^[[:space:]]*pluginsync\s*=\s*false' "$PUPPET_CONF"; then
    sed -i '/^[[:space:]]*pluginsync\s*=\s*false/d' "$PUPPET_CONF"
    ok "Eliminado 'pluginsync=false' de puppet.conf"
  elif grep -qE '^[[:space:]]*pluginsync\s*=\s*true' "$PUPPET_CONF"; then
    sed -i 's/^[[:space:]]*pluginsync\s*=\s*true/# & (comentado)/' "$PUPPET_CONF"
    ok "Comentado 'pluginsync=true' (deprecated)"
  else
    ok "Sin parámetro pluginsync en puppet.conf"
  fi
else
  warn "No se encontró puppet.conf en ${PUPPET_CONF}"
fi

### =============================
### [10] /etc/escuela2.0
### =============================
if $CREATE_ESC_20; then
cat >/etc/escuela2.0 <<'__ESC20__'
SISTEMA=ubuntu2404
USO=portatiles
USUARIO=alumno
HARDWARE=notebookHPG11
__ESC20__
chmod 644 /etc/escuela2.0; chown root:root /etc/escuela2.0
ok "/etc/escuela2.0 presente"
else
ok "/etc/escuela2.0 omitido"
fi

### =============================
### [11] Detectar puppetserver remoto y comando CA
### =============================
REMOTE_PUPPETSERVER_CMD=""
if $PUPPET_CA_SSH; then
  if ! getent hosts "${PUPPET_SSH_HOST}" >/dev/null 2>&1; then
    warn "No se puede resolver ${PUPPET_SSH_HOST}; desactivo CA remota."
    PUPPET_CA_SSH=false
  fi
fi

if $PUPPET_CA_SSH; then
  REMOTE_PUPPETSERVER_CMD="$(ssh_run 'if [ -x /opt/puppetlabs/bin/puppetserver ]; then echo /opt/puppetlabs/bin/puppetserver; elif command -v puppetserver >/dev/null 2>&1; then command -v puppetserver; else echo ""; fi' 2>/dev/null || true)"
  if [[ -z "$REMOTE_PUPPETSERVER_CMD" ]]; then
    warn "No se encontró 'puppetserver' o no hay conectividad SSH con ${PUPPET_SSH_HOST}; desactivo CA remota."
    PUPPET_CA_SSH=false
  else
    ok "CA remota detectada en ${PUPPET_SSH_HOST} (${REMOTE_PUPPETSERVER_CMD})"
  fi
else
  ok "CA remota desactivada por configuración"
fi

### =============================
### [12] FUNCIONES SSL/PKI
### =============================
ssl_paths(){
  CN="$(/opt/puppetlabs/bin/puppet config print certname 2>/dev/null || hostname -f)"
  SSLDIR="$([ -x /opt/puppetlabs/bin/puppet ] && /opt/puppetlabs/bin/puppet config print ssldir 2>/dev/null || echo /etc/puppetlabs/puppet/ssl)"
  HOSTCERT="$([ -x /opt/puppetlabs/bin/puppet ] && /opt/puppetlabs/bin/puppet config print hostcert 2>/dev/null || echo "${SSLDIR}/certs/${CN}.pem")"
  HOSTPRIVKEY="$([ -x /opt/puppetlabs/bin/puppet ] && /opt/puppetlabs/bin/puppet config print hostprivkey 2>/dev/null || echo "${SSLDIR}/private_keys/${CN}.pem")"
  HOSTCSR="${SSLDIR}/certificate_requests/${CN}.pem"
}

cert_matches_key(){
  ssl_paths
  [ -s "$HOSTCERT" ] && [ -s "$HOSTPRIVKEY" ] || return 1
  local m1 m2
  m1="$(openssl x509 -noout -modulus -in "$HOSTCERT" 2>/dev/null || true)"
  m2="$(openssl rsa  -noout -modulus -in "$HOSTPRIVKEY" 2>/dev/null || true)"
  [ -n "$m1" ] && [ -n "$m2" ] && [ "$m1" = "$m2" ]
}

remote_ca_state_json(){
  $PUPPET_CA_SSH || { echo '{}' ; return 0; }
  ssh_run "'${REMOTE_PUPPETSERVER_CMD}' ca list --all --format json 2>/dev/null" || echo '{}'
}

remote_ca_clean(){
  $PUPPET_CA_SSH || { warn "CA remota no disponible"; return 0; }
  ssl_paths
  info "CA remoto (${PUPPET_SSH_HOST}): estado PREVIO de ${CN}…"
  ssh_run "'${REMOTE_PUPPETSERVER_CMD}' ca list --all --format json 2>/dev/null | jq -r '.[] | select(.name==\"${CN}\")' || true" || true
  # Revocar y limpiar
  ssh_run "'${REMOTE_PUPPETSERVER_CMD}' ca revoke --certname '${CN}' 2>/dev/null || true" || true
  ssh_run "'${REMOTE_PUPPETSERVER_CMD}' ca clean  --certname '${CN}' 2>/dev/null || true" || true
  # Barrido defensivo
  ssh_run "rm -f /etc/puppetlabs/puppetserver/ca/signed/${CN}.pem /opt/puppetlabs/puppet/ssl/ca/signed/${CN}.pem 2>/dev/null || true" || true
  ssh_run "rm -f /etc/puppetlabs/puppetserver/ca/requests/${CN}.pem /opt/puppetlabs/puppet/ssl/ca/requests/${CN}.pem 2>/dev/null || true" || true
  info "CA remoto (${PUPPET_SSH_HOST}): estado POSTERIOR de ${CN}…"
  ssh_run "'${REMOTE_PUPPETSERVER_CMD}' ca list --all --format json 2>/dev/null | jq -r '.[] | select(.name==\"${CN}\")' || true" || true
}

full_local_ssl_clean(){
  ssl_paths
  systemctl stop puppet 2>/dev/null || true
  /opt/puppetlabs/bin/puppet ssl clean 2>/dev/null || true
  rm -rf "$SSLDIR" 2>/dev/null || true
}

submit_and_fetch(){
  # Envia CSR y descarga cert; devuelve 0 si verify OK; 2 si hay CONFLICT
  local out; out=$(mktemp)
  /opt/puppetlabs/bin/puppet ssl submit_request 2>&1 | tee -a "$out" || true
  if grep -q "due to a conflict on the server" "$out"; then
    rm -f "$out"; echo CONFLICT; return 2
  fi
  rm -f "$out"
  sleep 2
  /opt/puppetlabs/bin/puppet ssl download_cert 2>&1 | tee -a "$LOG" || true
  /opt/puppetlabs/bin/puppet ssl verify && return 0 || return 1
}

sync_ca_from_server(){
  # Descarga CA+CRL desde el puppetserver institucional y verifica TLS
  local cert_dir="/etc/puppetlabs/puppet/ssl/certs" crl_file="/etc/puppetlabs/puppet/ssl/crl.pem"
  ensure_dir "$cert_dir" 755 root:root
  curl -fsS -k "https://${PUPPETSERVER_FQDN}:8140/puppet-ca/v1/certificate/ca" >"${cert_dir}/ca.pem"
  curl -fsS -k "https://${PUPPETSERVER_FQDN}:8140/puppet-ca/v1/certificate_revocation_list/ca" >"${crl_file}"
  if id puppet >/dev/null 2>&1; then
    chown puppet:puppet "${cert_dir}/ca.pem" "${crl_file}"
  else
    chown root:root "${cert_dir}/ca.pem" "${crl_file}"
  fi
  chmod 644 "${cert_dir}/ca.pem" "${crl_file}"
  if openssl s_client -quiet -connect ${PUPPETSERVER_FQDN}:8140 -CAfile "${cert_dir}/ca.pem" </dev/null 2>/dev/null | grep -q "Verify return code: 0 (ok)"; then
    ok "CA/CRL sincronizadas desde ${PUPPETSERVER_FQDN}"
  else
    info "No se pudo validar TLS con la CA descargada en esta comprobación; se continúa con el flujo Puppet."
  fi
}

### =============================
### [13] SSL: reset con CA sincronizada y reintentos
### =============================
ssl_paths
# 13.0) Sincroniza CA/CRL antes de empezar
sync_ca_from_server
# 13.1) Limpieza previa en CA remota si procede
if $PUPPET_CA_SSH && [[ -n "${REMOTE_PUPPETSERVER_CMD:-}" ]]; then
  info "CA remoto: revoke+clean previos para ${CN}…"
  remote_ca_clean
fi
# 13.2) Limpieza total local
full_local_ssl_clean
ok "SSL local purgado (claves/certs anteriores eliminados)"
# 13.3) submit + download + verify con gestión de conflictos
case "$(submit_and_fetch || true)" in
  "")
    if cert_matches_key; then
      ok "Certificado descargado y emparejado con la clave (intento 1)"
    else
      warn "Intento 1: verificación fallida; paso a reintento defensivo…"
    fi
    ;;
  "CONFLICT")
    warn "Conflicto en CA: ya existe cert para ${CN}. Limpio en CA y reintento…"
    remote_ca_clean
    full_local_ssl_clean
    ;&
  *)
    info "Reintento tras limpieza…"
    if [[ "$(submit_and_fetch || true)" = "CONFLICT" ]]; then
      warn "La CA sigue informando de conflicto. Repito clean y fuerzo descarga de CA/CRL"
      remote_ca_clean
      sync_ca_from_server
      full_local_ssl_clean
      submit_and_fetch || true
    fi
    ;;
  esac

# 13.4) Verificación explícita par cert/clave
if cert_matches_key; then
  info "Verificación OpenSSL: el certificado del cliente corresponde a su clave privada."
else
  warn "Verificación OpenSSL: MISMATCH cert/clave en el cliente. Revisión manual puede ser necesaria."
fi

### =============================
### [14] Ejecutar puppet agent -tv
### =============================
if $RUN_PUPPET_AGENT && [[ -x /opt/puppetlabs/bin/puppet ]]; then
  /opt/puppetlabs/bin/puppet agent -tv || true
  ok "puppet agent ejecutado (o intentado)"
else
  ok "puppet agent omitido por configuración"
fi

### =============================
### [15] pkgsync (instalación + cron diario)
### =============================
if $FIX_PKG_SYNC; then
  CUR=$(dpkg-query -W -f='${Version}\n' pkgsync 2>/dev/null || echo "noinst")
  if [[ "$CUR" != "$PKGSYNC_VER" ]]; then
    wget -O /tmp/pkgsync_${PKGSYNC_VER}_all.deb "$PKGSYNC_URL"
    apt install -f -y /tmp/pkgsync_${PKGSYNC_VER}_all.deb || apt -f install -y
  fi
  ensure_dir /etc/pkgsync 755 root:root
  : > /etc/pkgsync/musthave; : > /etc/pkgsync/mayhave; : > /etc/pkgsync/maynothave; : > /etc/pkgsync/extra
  chmod 644 /etc/pkgsync/* || true
  if [[ ! -x /etc/cron.daily/pkgsync ]]; then
    cat >/etc/cron.daily/pkgsync <<'__CRON__'
#!/bin/sh
LOCK="/var/lock/pkgsync.daily.lock"
(
  flock -n 9 || exit 0
  if command -v pkgsync >/dev/null 2>&1; then
    pkgsync -y >/var/log/pkgsync.daily.log 2>&1 || true
  fi
) 9>"$LOCK"
__CRON__
    chmod 755 /etc/cron.daily/pkgsync
  fi
  ok "pkgsync ${PKGSYNC_VER} instalado y programado"
else
  ok "pkgsync omitido por configuración"
fi

### =============================
### [16] XFCE → /etc/skel
### =============================
if $COPY_XFCE_PROFILE_FROM_LINEX_TO_SKEL; then
  if [[ -d /home/${LINUX_USER}/.config/xfce4 ]]; then
    ensure_dir /etc/skel/.config 755 root:root
    rm -rf /etc/skel/.config/xfce4
    cp -a /home/${LINUX_USER}/.config/xfce4 /etc/skel/.config/
    chown -R root:root /etc/skel/.config
    ok "Perfil XFCE copiado a /etc/skel"
  else
    ok "Perfil XFCE no existe en /home/${LINUX_USER}; nada que copiar"
  fi
else
  ok "Copia de perfil XFCE omitida"
fi

### =============================
### [17] Deshabilitar xfce4-screensaver
### =============================
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
### [18] GRUB timeout
### =============================
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
### [19] Firefox .deb desde repo oficial de Mozilla (no Snap)
### =============================
if $INSTALL_FIREFOX_FROM_MOZILLA_PPA; then
  info "Firefox: quitar Snap/PPAs e instalar .deb oficial de Mozilla (sin paquetes de idioma de Ubuntu)…"

  export DEBIAN_FRONTEND=noninteractive

  # 1) Cerrar y quitar Snap si existe
  pkill -9 firefox 2>/dev/null || true
  if command -v snap >/dev/null 2>&1 && snap list 2>/dev/null | grep -q '^firefox\s'; then
    snap stop firefox 2>/dev/null || true
    snap remove --purge firefox || true
  fi
  rm -f /var/lib/snapd/desktop/applications/firefox_firefox.desktop 2>/dev/null || true

  # 2) Limpiar PPA/pins antiguos
  rm -f /etc/apt/sources.list.d/mozillateam-ubuntu-ppa*.list 2>/dev/null || true
  rm -f /etc/apt/preferences.d/mozillateamppa /etc/apt/preferences.d/firefox-nosnap-ubuntu 2>/dev/null || true

  # 3) Dependencias APT/HTTPS
  apt-get update -y || true
  apt-get install -y ca-certificates curl gnupg apt-transport-https || true

  # 4) Clave y repo Mozilla (sin preguntar)
  install -d -m 0755 /usr/share/keyrings
  curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg \
    | gpg --dearmor --yes --batch -o /usr/share/keyrings/packages.mozilla.org.gpg

  cat >/etc/apt/sources.list.d/mozilla-official.list <<'EOF'
deb [signed-by=/usr/share/keyrings/packages.mozilla.org.gpg] https://packages.mozilla.org/apt mozilla main
EOF

  # 5) Pin para preferir Mozilla
  cat >/etc/apt/preferences.d/moz-official-firefox <<'EOF'
Package: firefox firefox-locale-*
Pin: origin packages.mozilla.org
Pin-Priority: 1001
EOF

  # 6) Instalar SOLO firefox (sin firefox-locale-es de Ubuntu)
  apt-get update -y || true
  apt-get install -y --allow-downgrades firefox

  info "apt-cache policy firefox:"; apt-cache policy firefox | sed 's/^/  /'

  # 7) Forzar español por políticas (sin depender de paquetes Ubuntu)
  install -d -m 0755 /usr/lib/firefox/distribution
  cat >/usr/lib/firefox/distribution/policies.json <<'JSON'
{
  "policies": {
    "Preferences": {
      "intl.locale.requested": "es-ES",
      "intl.accept_languages": "es-ES,es,en-US,en"
    }
  }
}
JSON
  chmod 0644 /usr/lib/firefox/distribution/policies.json

  if command -v firefox >/dev/null 2>&1 && dpkg -s firefox 2>/dev/null | grep -q '^Status: install ok installed'; then
    ok "Firefox instalado como .deb desde packages.mozilla.org y configurado en español (preferencias)."
  else
    warn "No se pudo instalar Firefox desde Mozilla; revisa conectividad/clave."
  fi
else
  ok "Instalación de Firefox omitida por configuración"
fi

### =============================
### [20] Reparar lanzador XFCE de Firefox (Snap → .deb)
### =============================

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
  HOME_DIR="$(getent passwd "$U" | awk -F: '{print $6}')" || return 0
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
### =============================
PANEL_SRC_DIR="/home/${LINUX_USER}/.config/xfce4/panel"
PANEL_SRC_XML="/home/${LINUX_USER}/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml"

fix_firefox_user() {
  local U="$1" HOME_DIR
  HOME_DIR="$(getent passwd "$U" | awk -F: '{print $6}')" || return 0
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
### [21] Recurso Puppet local (ejemplo mínimo)
### =============================
touch /usr/bin/gnome-keyring-daemon 2>/dev/null || true
chmod 0644 /usr/bin/gnome-keyring-daemon 2>/dev/null || true
if $APPLY_PUPPET_SNIPPET && [[ -x /opt/puppetlabs/bin/puppet ]]; then
  /opt/puppetlabs/bin/puppet apply <<'__PP__' || true
file { '/usr/bin/gnome-keyring-daemon':
  ensure => file,
  mode   => '0644',
}
__PP__
  ok "Recurso Puppet local aplicado para /usr/bin/gnome-keyring-daemon (0644)"
else
  ok "Archivo /usr/bin/gnome-keyring-daemon asegurado (0644)"
fi

### =============================
### [22] EDUCAREX (NetworkManager) — cambios diferidos
### =============================
if $CONFIG_EDUCAREX_WIFI; then
  ensure_dir /etc/NetworkManager/system-connections 700 root:root
  if [[ -f /root/educarex.nmconnection ]]; then
    cp -a /root/educarex.nmconnection /etc/NetworkManager/system-connections/educarex.nmconnection
  else
    cat >/etc/NetworkManager/system-connections/educarex.nmconnection <<EOF
[connection]
id=educarex
uuid=510173e1-ba58-40fe-83ff-6bc5c417602a
type=wifi
autoconnect-priority=128
permissions=

[wifi]
mac-address=
mac-address-blacklist=
mode=infrastructure
ssid=educarex

[wifi-security]
key-mgmt=wpa-eap

[802-1x]
eap=peap;
identity=${EDUCAREX_IDENTITY}
password=${EDUCAREX_PASSWORD}
phase2-auth=gtc

[ipv4]
dns-search=
method=auto

[ipv6]
addr-gen-mode=stable-privacy
dns-search=
ip6-privacy=0
method=auto

EOF
  fi
  chown root:root /etc/NetworkManager/system-connections/educarex.nmconnection
  chmod 600 /etc/NetworkManager/system-connections/educarex.nmconnection
  moved_any=false; shopt -s nullglob
  for f in /etc/netplan/90*; do mv "$f" "/root/$(basename "$f").bak.$(date +%s)" && moved_any=true; done
  shopt -u nullglob
  if $moved_any; then info "Netplan 90* movido a /root/*.bak.* (efectivo tras reinicio)"; fi
  ok "Perfil EDUCAREX instalado (NM) — cambios diferidos al reinicio"
else
  ok "Configuración EDUCAREX omitida"
fi

### =============================
### [XFCE] Clonar panel de 'linex' a 'root'
### =============================
info "Clonando configuración de panel XFCE desde 'linex' hacia 'root'…"

SRC_HOME="/home/linex"
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

  # 4) Reescribir rutas absolutas /home/linex -> /root dentro del perfil
  #    (lançadores .desktop, configuraciones del panel, etc.)
  if command -v sed >/dev/null 2>&1; then
    find "${DST_DIR}" -maxdepth 4 -type f -print0 \
      | xargs -0 sed -ri 's#/home/linex#\/root#g' || true
  fi

  # 5) Propiedad/permiso correctos para root
  chown -R root:root "${DST_DIR}" 2>/dev/null || true

  # 6) Si el panel de root está corriendo, cerrarlo para que se regenere al próximo login
  pkill -u root -x xfce4-panel 2>/dev/null || true

  ok "Panel de root clonado desde el perfil de 'linex'."
fi


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
