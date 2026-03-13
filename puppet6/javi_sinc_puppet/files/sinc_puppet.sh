#!/usr/bin/env bash
# =============================================================================
# sinc_puppet.sh — Sincronización de cliente Puppet (compatibilidad Puppet 6)
# -----------------------------------------------------------------------------
# Autor: Javier Alfonso de las Heras (IES Sáenz de Buruaga)
# Edición: Ajustes para Puppet 6 / Ubuntu 24.04
# Fecha: 11/03/26
#
# OBJETIVO:
#   • Sincronizar certificados y CA/CRL desde el puppetserver
#   • Limpiar certificados locales y resolver conflictos comunes
#   • Ejecutar `puppet agent -tv` al final
#
# USO:
#   sudo bash sinc_puppet.sh
#
# REQUISITOS:
#   • Puppet Agent instalado (binario en /opt/puppetlabs/bin/puppet)
#   • Conectividad TCP/8140 al puppetserver
#   • Acceso SSH al servidor para limpieza remota (opcional)
# =============================================================================

set -Eeuo pipefail

# =============================
# [00] PARÁMETROS GLOBALES
# =============================
PUPPETSERVER_FQDN="puppetinstituto"
RUN_PUPPET_AGENT=true
LOG="/var/log/sinc_puppet.log"

# Configuración SSH para limpieza remota
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

install_if_missing() {
    local pkgs=()
    command -v curl     >/dev/null 2>&1 || pkgs+=("curl")
    command -v openssl  >/dev/null 2>&1 || pkgs+=("openssl")
    command -v sshpass  >/dev/null 2>&1 || pkgs+=("sshpass")
    if (( ${#pkgs[@]} )); then
        info "Instalando dependencias faltantes..."
        apt-get update -y || true
        apt-get install -y "${pkgs[@]}" || true
    fi
}

ssh_run(){
    sshpass -p "$PUPPET_SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "${PUPPET_SSH_USER}@${PUPPET_SSH_HOST}" "$1"
}

trap 'err "Fallo en línea $LINENO: $BASH_COMMAND"' ERR
exec > >(tee -a "$LOG") 2>&1

# =============================
# [02] INICIO Y COMPATIBILIDAD
# =============================
require_root
install_if_missing

# AJUSTE CRÍTICO: Bajar nivel de seguridad SSL para Puppetserver 6 antiguo
if grep -q "SECLEVEL=2" /etc/ssl/openssl.cnf; then
    sed -i 's/SECLEVEL=2/SECLEVEL=1/g' /etc/ssl/openssl.cnf
    info "Seguridad OpenSSL ajustada a SECLEVEL=1 para compatibilidad con servidor antiguo."
fi

info "Iniciando sincronización Puppet..."

# =============================
# [03] puppet.conf: limpiar 'pluginsync'
# =============================
PUPPET_CONF="/etc/puppetlabs/puppet/puppet.conf"
if [[ -f "$PUPPET_CONF" ]]; then
    sed -i '/^[[:space:]]*pluginsync\s*=\s*false/d' "$PUPPET_CONF"
    sed -i 's/^[[:space:]]*pluginsync\s*=\s*true/# & (comentado)/' "$PUPPET_CONF"
    ok "Configuración de puppet.conf saneada."
fi

# =============================
# [04] Configurar Comando Remoto (RUTA ABSOLUTA FORZADA)
# =============================
REMOTE_PUPPETSERVER_CMD="/opt/puppetlabs/bin/puppetserver"
if $PUPPET_CA_SSH; then
    # Verificación rápida de conexión
    if ssh_run "ls ${REMOTE_PUPPETSERVER_CMD}" >/dev/null 2>&1; then
        ok "Conexión SSH y comando Puppetserver detectados en ${PUPPET_SSH_HOST}"
    else
        warn "Fallo de conexión SSH o binario no encontrado en el servidor. Desactivando CA remota."
        PUPPET_CA_SSH=false
    fi
fi

# =============================
# [05] FUNCIONES SSL/PKI
# =============================
# Cambia la definición de SSLDIR en el script (línea 112 aprox)
ssl_paths(){
    CN="$(/opt/puppetlabs/bin/puppet config print certname 2>/dev/null || hostname -f)"
    # Detectamos dónde guarda Puppet realmente el SSL
    SSLDIR="$(/opt/puppetlabs/bin/puppet config print ssldir)"
    HOSTCERT="${SSLDIR}/certs/${CN}.pem"
    HOSTPRIVKEY="${SSLDIR}/private_keys/${CN}.pem"
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
    $PUPPET_CA_SSH || { warn "Limpieza remota omitida"; return 0; }
    ssl_paths
    info "Borrando rastro de ${CN} en el servidor..."

    # Único comando válido para Puppet 6/7/8
    ssh_run "/opt/puppetlabs/bin/puppetserver ca clean --certname ${CN} 2>/dev/null || true"

    # Borrado manual por si el comando anterior no tiene permisos totales
    ssh_run "rm -f /etc/puppetlabs/puppetserver/ca/signed/${CN}.pem /etc/puppetlabs/puppet/ssl/ca/signed/${CN}.pem 2>/dev/null || true"
    ssh_run "rm -f /etc/puppetlabs/puppetserver/ca/signed/${CN}.pem"

    ok "CA remota procesada para ${CN}"

}

full_local_ssl_clean(){
    ssl_paths
    # SI EL CERTIFICADO YA ES VÁLIDO, NO BORRAMOS NADA
    if cert_matches_key && /opt/puppetlabs/bin/puppet ssl verify --server ${PUPPETSERVER_FQDN} >/dev/null 2>&1; then
        ok "SSL local ya es válido. Saltando limpieza."
        return 0
    fi

    systemctl stop puppet 2>/dev/null || true
    # Borramos todo menos la CA que acabamos de bajar
    find "$SSLDIR" -mindepth 1 -not -path "$SSLDIR/certs*" -delete 2>/dev/null || true
    ok "SSL local saneado (preservando CA)."
}

submit_and_fetch(){
    info "Solicitando y descargando certificado (bootstrap)..."

    # Puppet 6 prefiere este comando único que gestiona todo el flujo
    if /opt/puppetlabs/bin/puppet ssl bootstrap --server ${PUPPETSERVER_FQDN} --waitforcert 10; then
        return 0
    else
        # Si falla, intentamos una vez más forzando la descarga
        /opt/puppetlabs/bin/puppet ssl download_cert --server ${PUPPETSERVER_FQDN} || true
        /opt/puppetlabs/bin/puppet ssl verify --server ${PUPPETSERVER_FQDN}
    fi
}

sync_ca_from_server(){
    local cert_dir="/etc/puppetlabs/puppet/ssl/certs"
    ensure_dir "$cert_dir" 755 root:root

    # Descarga
    curl -fsS -k "https://${PUPPETSERVER_FQDN}:8140/puppet-ca/v1/certificate/ca" >"${cert_dir}/ca.pem"

    # Forzamos a que Puppet use también la CA del sistema
    if [ -f /etc/ssl/certs/ca-certificates.crt ]; then
        export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
    fi

    # Verificación más permisiva
    if openssl s_client -quiet -connect ${PUPPETSERVER_FQDN}:8140 -CAfile "${cert_dir}/ca.pem" </dev/null 2>&1 | grep -q "verify return:1" || openssl s_client -quiet -connect ${PUPPETSERVER_FQDN}:8140 </dev/null 2>&1 | grep -q "verify return:1"; then
        ok "CA validada correctamente."
    else
        warn "La CA descargada tiene discrepancias de nombre, pero continuaremos."
    fi
}

# =============================
# [06] EJECUCIÓN DEL RESET
# =============================
ssl_paths

# COMPROBACIÓN PREVIA: Si ya funciona, salimos con éxito
if cert_matches_key && /opt/puppetlabs/bin/puppet ssl verify --server ${PUPPETSERVER_FQDN} >/dev/null 2>&1; then
    ok "El sistema ya está sincronizado y el SSL es válido. No es necesario re-sincronizar."

    if $RUN_PUPPET_AGENT; then
        info "Ejecutando agente de mantenimiento..."
        /opt/puppetlabs/bin/puppet agent -tv || true
    fi
    info "Proceso finalizado (sin cambios necesarios)."
    exit 0
fi

# Si llegamos aquí, es que el SSL está roto o no existe. Procedemos con la limpieza.
sync_ca_from_server

if $PUPPET_CA_SSH; then
    remote_ca_clean
fi

full_local_ssl_clean

# Intento de firma (bootstrap)
submit_and_fetch || true

# =============================
# [07] FINALIZACIÓN
# =============================
if cert_matches_key; then
    ok "Certificado e instalados correctamente."
    if $RUN_PUPPET_AGENT; then
        info "Lanzando primer agente Puppet..."
        /opt/puppetlabs/bin/puppet agent -tv || true
    fi
else
    err "No se ha podido emparejar el certificado. Revisar logs en el servidor."
fi

info "Proceso finalizado. Log en ${LOG}"