# HP465 G11 / Puppet Sync Scripts

## NOTAS IMPORTANTES

> **Importante sobre credenciales:** si no se modifica nada en los scripts, **no hay persistencia de credenciales en el cliente**.

> En el modo interactivo por defecto, las contraseñas y datos sensibles que se piden por pantalla **se usan solo durante esa ejecucion** y **no se guardan en disco** ni quedan almacenados de forma persistente.

> **Solo pasan a persistirse** si alguien edita manualmente la seccion `[00] PARÁMETROS GLOBALES` y deja valores fijos dentro del script.

> **Recomendacion:** si vas a usar `sinc_puppet`, conviene **configurar antes el modulo Puppet en el servidor** para que el propio script de configuracion inicial deje instalado `sinc_puppet` durante la ejecucion del `puppet agent`.

Este repositorio contiene dos tipos de artefactos:

1. **Scripts de configuración inicial** para equipos HP ProBook 465 G11 con Xubuntu 24.04 / Linex.
2. **Módulo Puppet** que despliega el script `sinc_puppet.sh` en los clientes y automatiza la limpieza/sincronización de certificados y el agente Puppet.

---

## 1) Scripts de configuración inicial (HP465 G11)

La carpeta raíz contiene los scripts `config_hp465g11.sh` (en las subcarpetas `puppet6/` y `puppet7/`) destinados a ejecutar una configuración inicial del equipo:

- Actualiza el hostname (formato `hp465g11-<xxx>`).
- Crea/actualiza usuarios `root` y `linex` (contraseñas solicitadas interactivamente).
- Configura un cliente LDAP y asegura que el sistema use los repositorios adecuados.
- Ajusta `/etc/hosts` para resolver `puppetinstituto` al servidor Puppet.
- Prepara Puppet (wrapper, facts, sanea `puppet.conf`, instala dependencias).
- Genera el fichero `/etc/escuela2.0` con datos del entorno (Ubuntu 24.04, portátil, etc.).
- Descarga/instala herramientas auxiliares (pkgsync, etc.).
- Ajusta valores de GRUB, XFCE, salvapantallas y Wi‑Fi EDUCAREX (configuración interactiva).
- Ejecuta `puppet agent` al final (según configuración).

### Uso

1. Copiar el script adecuado (`puppet6/` o `puppet7/`) al equipo.
2. Ejecutar:

```bash
sudo bash config_hp465g11.sh
```

### Descargar y ejecutar directamente (curl)

Puedes descargar y ejecutar los scripts directamente desde este repositorio (versiones `puppet6` y `puppet7`) sin clonar el proyecto.

> **Importante:** no uses `curl ... | bash` en estos scripts, porque perderas los prompts interactivos de la seccion [00].

> 💡 Recomendado: actualiza los paquetes antes de ejecutar la configuración.

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl

# Puppet 6
curl -fsSL https://raw.githubusercontent.com/xavileeee/Config-HP-465-G11-para-linex/master/puppet6/config_hp465g11.sh -o /tmp/config_hp465g11_puppet6.sh
sudo bash /tmp/config_hp465g11_puppet6.sh

# Puppet 7
curl -fsSL https://raw.githubusercontent.com/xavileeee/Config-HP-465-G11-para-linex/master/puppet7/config_hp465g11.sh -o /tmp/config_hp465g11_puppet7.sh
sudo bash /tmp/config_hp465g11_puppet7.sh
```

#### Opción: borrar los scripts al acabar

Si quieres eliminar los scripts descargados al finalizar:

```bash
rm -f /tmp/config_hp465g11_puppet6.sh /tmp/config_hp465g11_puppet7.sh
```

### Modo no interactivo (sin preguntas en [00])

Las secciones **[00] PARÁMETROS GLOBALES** de los scripts `config_hp465g11.sh` son las que piden datos por teclado (contraseñas, IP, SSH, etc.). Para evitar que el script pregunte, basta con fijar las variables directamente en esa sección (antes de ejecutar el script).

Ejemplo (en `config_hp465g11.sh`):

```bash
ROOT_PW="MiRootSecret"
LINUX_PW="MiLinexSecret"
PUPPET_HOST_IP="172.19.10.2"
PUPPET_SSH_HOST="servidor.saenzdeburuaga"
PUPPET_SSH_PASS="MiPssw0rdSeguro"
EDUCAREX_IDENTITY="saenzdeburuaga"
EDUCAREX_PASSWORD="MiWifiSecret"
```

> **Nota:** solo estas variables se piden por teclado. Si no se definen, el script preguntará durante la ejecución.

---

## 2) Módulo Puppet para desplegar `sinc_puppet.sh`

El módulo Puppet está en:

- `javi_sinc_puppet/`

### ¿Qué hace?

El script `sinc_puppet.sh` (contenido en `files/sinc_puppet.sh`) realiza estas acciones en un cliente Puppet:

- Limpia certificados locales de Puppet (si detecta inconsistencias).
- Sincroniza la CA/CRL desde el puppetserver (descarga remota).
- Resuelve conflictos típicos (CSR existente, certificado ya en CA, desajuste entre certificado y clave privada).
- Ejecuta `puppet agent -tv` al final para garantizar que el agente se registra y el catálogo se aplica.

### Instalación del módulo

Coloca el módulo en el servidor Puppet en:

```
/etc/puppetlabs/code/environments/production/modules/
```

De forma que la carpeta quede así:

```
/etc/puppetlabs/code/environments/production/modules/javi_sinc_puppet/
```


> **Nota:** el módulo debe tener la estructura estándar de Puppet (manifests/, files/, etc.).

### Incluir el módulo en la configuración del entorno

En el módulo que configura tus equipos (por ejemplo `especifica_xubuntu2404`), añade una línea `include` en:

```
/etc/puppetlabs/code/environments/production/modules/especifica_xubuntu2404/manifests/init.pp
```

Ejemplo:

```puppet
include javi_sinc_puppet
```

Esto hará que, al ejecutar Puppet en los clientes, se despliegue y ejecute el script `sinc_puppet.sh`.

### Configuración obligatoria previa (opcional y con riesgos)

El script `sinc_puppet.sh` **pide por defecto** los datos de conexión al servidor Puppet (host SSH y contraseña). Puedes mantenerlo tal cual y responder a esas preguntas en tiempo de ejecución.

> **Nota importante:** en ese modo por defecto, las credenciales introducidas **no se almacenan en el cliente**: se usan durante la ejecucion y no se persisten salvo que el script se edite manualmente para fijarlas.

Si prefieres no introducir datos interactivos, **puedes preconfigurar las variables** en la sección `[00] PARÁMETROS GLOBALES` del script; sin embargo, **no se recomienda** porque implica almacenar credenciales en el cliente.

#### **Riesgos de preconfigurar credenciales en el script**

- Cualquier usuario con acceso al equipo podrá leer la contraseña de root del servidor Puppet.
- Si el script se comparte (por ejemplo, por repositorio, copia USB o backup), las credenciales pueden filtrarse.
- Cualquier cambio de contraseña exige editar el script manualmente.

> **Solo usa esta opcion si sabes lo que haces y lo haces bajo tu propia responsabilidad.**

Variables principales que puedes ajustar en `files/sinc_puppet.sh` (si decides hacerlo):

```bash
PUPPET_SSH_HOST="servidor.saenzdeburuaga"    # host donde está el puppetserver
PUPPET_SSH_PASS="MiPssw0rdSeguro"            # contraseña de root del servidor
```
> **Nota:** si no configuras estas variables y optas por la ejecución interactiva, el script te pedirá los valores al arrancar.

---