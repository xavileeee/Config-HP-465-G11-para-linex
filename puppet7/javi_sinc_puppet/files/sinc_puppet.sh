#!/usr/bin/env bash
# =============================================================================
# sinc_puppet.sh — Sincronización Puppet (cliente)
# -----------------------------------------------------------------------------
# Autor: Javier Alfonso de las Heras (Administrador Informático — IES Sáenz de Buruaga)
# Colaboración: ChatGPT (asistente IA)
# Versión: v1 (nueva versión) · Fecha: 11/03/26
#
# OBJETIVO:
#   - Dejar el cliente Puppet operativo contra el puppetserver institucional:
#     * Limpia certificados locales si procede
#     * Sincroniza CA/CRL desde el server
#     * Resuelve conflictos típicos (CSR existente, cert en CA, mismatch cert/clave)
#     * Ejecuta `puppet agent -tv` y termina
#
# REQUISITOS:
#   - Ejecutar como root
#   - `puppet-agent` instalado (binario en /opt/puppetlabs/bin/puppet)
#   - Conectividad TCP 8140 contra el puppetserver
# =============================================================================

set -Eeuo pipefail

# =============================
# [00] PARÁMETROS GLOBALES
# =============================
PUPPETSERVER_FQDN="puppetinstituto"          # FQDN resolvible desde el cliente
RUN_PUPPET_AGENT=true                        # Ejecutar puppet agent al final
LOG="/var/log/sinc_puppet.log"               # Log de esta ejecución

# Limpieza/Firma remota en la CA local del centro (vía SSH al servidor Puppet local)
PUPPET_CA_SSH=true
PUPPET_SSH_USER="root"

# Solicitar host SSH del puppetserver
read -p "🖧 Introduce el host SSH del puppetserver (ej: servidor.saenzdeburuaga): " PUPPET_SSH_HOST
# PUPPET_SSH_HOST="servidor.saenzdeburuaga"    # (Opcional) fija aquí el hostname si prefieres no preguntar

# Solicitar contraseña SSH de forma segura
read -s -p "🔐 Introduce contraseña SSH para ${PUPPET_SSH_USER}@${PUPPET_SSH_HOST}: " PUPPET_SSH_PASS; echo
#PUPPET_SSH_PASS=""  # No almacenar contraseñas en el script

# =============================
# [01] UTILIDADES COMUNES
# =============================
ts(){ date +'%F %T'; }
info(){ echo "[$(ts)] $*"; }
ok(){   echo "[$(ts)] ✅ $*"; }
warn(){ echo "[$(ts)] ⚠️  $*"; }
err(){  echo "[$(ts)] ❌ $*"; }
require_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || { err "Ejecuta como root"; exit 1; }; }
ensure_dir(){ mkdir -p "$1"; chmod "${2:-755}" "$1"; chown ${3:-root:root} "$1"; }

# Instalación mínima de dependencias si faltan
install_if_missing() {
  local pkgs=()
  command -v curl     >/dev/null 2>&1 || pkgs+=("curl")
  command -v openssl  >/dev/null 2>&1 || pkgs+=("openssl")
  command -v sshpass  >/dev/null 2>&1 || $PUPPET_CA_SSH && pkgs+=("sshpass")
  if (( ${#pkgs[@]} )); then
    DEBIAN_FRONTEND=noninteractive apt-get update -y || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" || true
  fi
}

# Wrapper SSH sencillo
ssh_run(){  # uso: ssh_run "comando"
  sshpass -p "$PUPPET_SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "${PUPPET_SSH_USER}@${PUPPET_SSH_HOST}" "$1"
}

# Abort controlado
trap 'err "Fallo en línea $LINENO: $BASH_COMMAND"' ERR

# Redirección de log
exec > >(tee -a "$LOG") 2>&1

# =============================
# [02] INICIO
# =============================
require_root
install_if_missing
info "Iniciando sincronización Puppet…"

# =============================
# [03] puppet.conf: limpiar 'pluginsync' (deprecated)
# =============================
PUPPET_CONF="/etc/puppetlabs/puppet/puppet.conf"
if [[ -f "$PUPPET_CONF" ]]; then
  if grep -qE '^[[:space:]]*pluginsync\s*=\s*false' "$PUPPET_CONF"; then
    sed -i '/^[[:space:]]*pluginsync\s*=\s*false/d' "$PUPPET_CONF"
    ok "Eliminado 'pluginsync=false' de puppet.conf"
  elif grep -qE '^[[:space:]]*pluginsync\s*=\s*true' "$PUPPET_CONF"; then
    sed -i 's/^[[:space:]]*pluginsync\s*=\s*true/# & (comentado)/' "$PUPPET_CONF"
    ok "Comentado 'pluginsync=true' (deprecated)"
  else
    info "Sin parámetro pluginsync en puppet.conf"
  fi
else
  warn "No se encontró puppet.conf en ${PUPPET_CONF}"
fi

# =============================
# [04] Detectar puppetserver remoto (para limpiar CA si hace falta)
# =============================
REMOTE_PUPPETSERVER_CMD=""
if $PUPPET_CA_SSH; then
  REMOTE_PUPPETSERVER_CMD="$(ssh_run 'if [ -x /opt/puppetlabs/bin/puppetserver ]; then echo /opt/puppetlabs/bin/puppetserver; elif command -v puppetserver >/dev/null 2>&1; then command -v puppetserver; else echo ""; fi')"
  if [[ -z "$REMOTE_PUPPETSERVER_CMD" ]]; then
    warn "No se encontró 'puppetserver' en ${PUPPET_SSH_HOST}; desactivo CA remota."
    PUPPET_CA_SSH=false
  else
    ok "CA remota detectada en ${PUPPET_SSH_HOST} (${REMOTE_PUPPETSERVER_CMD})"
  fi
else
  info "CA remota desactivada por configuración"
fi

# =============================
# [05] FUNCIONES SSL/PKI
# =============================
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
  [[ -n "$m1" && -n "$m2" && "$m1" = "$m2" ]]
}

remote_ca_clean(){
  $PUPPET_CA_SSH || { warn "CA remota no disponible"; return 0; }
  ssl_paths
  # Revoca/limpia en la CA remota y purga artefactos defensivamente
  ssh_run "'${REMOTE_PUPPETSERVER_CMD}' ca revoke --certname '${CN}' 2>/dev/null || true"
  ssh_run "'${REMOTE_PUPPETSERVER_CMD}' ca clean  --certname '${CN}' 2>/dev/null || true"
  ssh_run "rm -f /etc/puppetlabs/puppetserver/ca/signed/${CN}.pem /opt/puppetlabs/puppet/ssl/ca/signed/${CN}.pem 2>/dev/null || true"
  ssh_run "rm -f /etc/puppetlabs/puppetserver/ca/requests/${CN}.pem /opt/puppetlabs/puppet/ssl/ca/requests/${CN}.pem 2>/dev/null || true"
  ok "CA remota limpiada para ${CN} (si existía)"
}

full_local_ssl_clean(){
  ssl_paths
  systemctl stop puppet 2>/dev/null || true
  /opt/puppetlabs/bin/puppet ssl clean 2>/dev/null || true
  rm -rf "$SSLDIR" 2>/dev/null || true
  ok "SSL local purgado"
}

submit_and_fetch(){
  # Envía CSR, intenta descargar y verificar. Devuelve:
  #   0 -> OK,            1 -> fallo genérico,           2 -> conflicto en CA
  local out; out=$(mktemp)
  /opt/puppetlabs/bin/puppet ssl submit_request 2>&1 | tee -a "$out" || true
  if grep -q "due to a conflict on the server" "$out"; then
    rm -f "$out"; echo "CONFLICT"; return 2
  fi
  rm -f "$out"
  sleep 2
  /opt/puppetlabs/bin/puppet ssl download_cert 2>&1 || true
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
    warn "No se pudo verificar TLS con la CA descargada; revisa conectividad/cert."
  fi
}

# =============================
# [06] RESET SSL + REINTENTOS
# =============================
ssl_paths
sync_ca_from_server

# Limpieza previa en CA remota si procede
if $PUPPET_CA_SSH && [[ -n "${REMOTE_PUPPETSERVER_CMD:-}" ]]; then
  info "Limpieza previa en CA remota para ${CN}…"
  remote_ca_clean
fi

# Limpieza local
full_local_ssl_clean

# Primer intento normal
case "$(submit_and_fetch || true)" in
  "")
    if cert_matches_key; then
      ok "Certificado descargado y emparejado con la clave (intento 1)"
    else
      warn "Intento 1: mismatch cert/clave; reintento defensivo…"
      remote_ca_clean || true
      full_local_ssl_clean
      sync_ca_from_server
      submit_and_fetch || true
    fi
    ;;
  "CONFLICT")
    warn "Conflicto en CA; limpio en remota y reintento…"
    remote_ca_clean
    full_local_ssl_clean
    sync_ca_from_server
    submit_and_fetch || true
    ;;
esac

# Verificación explícita final
if cert_matches_key; then
  ok "Verificación OpenSSL: el certificado del cliente corresponde a su clave privada."
else
  warn "Persisten problemas de emparejamiento cert/clave para ${CN}."
fi

# =============================
# [07] EJECUTAR PUPPET AGENT
# =============================
if $RUN_PUPPET_AGENT && [[ -x /opt/puppetlabs/bin/puppet ]]; then
  info "Ejecutando: /opt/puppetlabs/bin/puppet agent -tv"
  /opt/puppetlabs/bin/puppet agent -tv || true
  ok "puppet agent ejecutado (o intentado)"
else
  info "Ejecución de puppet agent omitida por configuración o binario no disponible"
fi
