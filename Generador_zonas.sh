#!/usr/bin/env bash
#===============================================================================
#  gen_zonas_dns.sh
#-------------------------------------------------------------------------------
#  Generador interactivo de ficheros de zona para BIND9.
#
#  - Crea el fichero de ZONA DIRECTA (db.<dominio>) de forma completamente
#    automatica a partir de los datos introducidos por el usuario.
#  - Crea automaticamente el/los fichero(s) de ZONA INVERSA (db.x.y.z) a partir
#    de los registros A introducidos, deduciendo la zona in-addr.arpa y el PTR.
#  - Soporta registros: NS, A, AAAA, CNAME, MX.
#  - Pide confirmacion antes de aplicar las opciones criticas.
#  - Permite elegir el directorio de destino.
#  - Control de errores meticuloso: valida TODO lo que introduce el usuario y
#    vuelve a preguntar mientras el dato no sea valido.
#
#  Uso:   ./gen_zonas_dns.sh
#  Requiere: bash >= 4 (arrays asociativos). named-checkzone es opcional.
#===============================================================================

set -uo pipefail

#-------------------------------------------------------------------------------
# 0. Variables globales y constantes
#-------------------------------------------------------------------------------
readonly SCRIPT_NAME="${0##*/}"

# Colores (se desactivan si la salida no es un terminal)
if [[ -t 1 ]]; then
    readonly C_RST=$'\e[0m'  C_ROJO=$'\e[31m'  C_VERDE=$'\e[32m'
    readonly C_AMAR=$'\e[33m' C_AZUL=$'\e[36m'  C_NEG=$'\e[1m'
else
    readonly C_RST='' C_ROJO='' C_VERDE='' C_AMAR='' C_AZUL='' C_NEG=''
fi

# Estructuras de datos que se van rellenando durante la ejecucion
declare -a NS_RECORDS=()        # "ns1.dominio.org."
declare -a A_RECORDS=()         # "nombre|ip"
declare -a AAAA_RECORDS=()      # "nombre|ipv6"
declare -a CNAME_RECORDS=()     # "alias|destino"
declare -a MX_RECORDS=()        # "prioridad|servidor"
declare -A REV_ZONES=()         # [zona_inversa] -> "octeto|fqdn\nocteto|fqdn..."

# Parametros de la zona (se piden al usuario)
DOMINIO=""          # ej: subdominio3.dominio.org
ADMIN=""            # ej: admin.dominio.org
NS_PRIMARIO=""      # ej: slavedns.subdominio3.dominio.org
DIR_DESTINO=""      # directorio donde se guardan los ficheros
TTL="604800"
SERIAL="1"
REFRESH="604800"
RETRY="86400"
EXPIRE="2419200"
NCTTL="604800"

#-------------------------------------------------------------------------------
# 1. Funciones de mensajes / logging
#-------------------------------------------------------------------------------
msg_info()  { printf '%s[INFO]%s  %s\n'  "$C_AZUL"  "$C_RST" "$*"; }
msg_ok()    { printf '%s[ OK ]%s  %s\n'  "$C_VERDE" "$C_RST" "$*"; }
msg_warn()  { printf '%s[WARN]%s  %s\n'  "$C_AMAR"  "$C_RST" "$*" >&2; }
msg_error() { printf '%s[ERR ]%s  %s\n'  "$C_ROJO"  "$C_RST" "$*" >&2; }
titulo()    { printf '\n%s== %s ==%s\n' "$C_NEG" "$*" "$C_RST"; }

# Trap: captura errores no controlados y cualquier interrupcion (Ctrl+C)
trap 'msg_error "Error inesperado en la linea $LINENO. Abortando."; exit 1' ERR
trap 'echo; msg_warn "Ejecucion cancelada por el usuario."; exit 130' INT TERM

#-------------------------------------------------------------------------------
# 2. Funciones de validacion
#    Todas devuelven 0 (valido) o 1 (no valido).
#-------------------------------------------------------------------------------

# Valida una direccion IPv4 con rango 0-255 en cada octeto
validar_ipv4() {
    local ip="$1" octeto
    [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    local IFS='.'
    for octeto in $ip; do
        # Sin ceros a la izquierda y dentro de rango
        (( octeto >= 0 && octeto <= 255 )) || return 1
        [[ "$octeto" == "0" || "$octeto" != 0* ]] || return 1
    done
    return 0
}

# Valida una direccion IPv6 (comprobacion razonable, admite formato comprimido ::)
validar_ipv6() {
    local ip="$1"
    # Debe contener al menos dos puntos
    [[ "$ip" == *:* ]] || return 1
    # Solo se permiten caracteres hexadecimales y ':'
    [[ "$ip" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
    # No mas de un "::"
    local dobles="${ip//[^:]/}"
    if [[ "$ip" == *"::"* ]]; then
        [[ "$(grep -o '::' <<< "$ip" | wc -l)" -le 1 ]] || return 1
    else
        # Sin "::" deben existir exactamente 7 ':' (8 grupos)
        [[ "${#dobles}" -eq 7 ]] || return 1
    fi
    # Cada grupo, como mucho 4 hexadecimales
    local grupo IFS=':'
    for grupo in $ip; do
        [[ -z "$grupo" ]] && continue
        [[ "${#grupo}" -le 4 ]] || return 1
    done
    return 0
}

# Valida una etiqueta de host simple (sin punto): letras, digitos y guion
validar_hostname() {
    local h="$1"
    [[ "$h" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
    return 0
}

# Valida un nombre de dominio / FQDN (varias etiquetas separadas por punto)
validar_dominio() {
    local d="$1"
    # Quitamos un posible punto final
    d="${d%.}"
    [[ -n "$d" ]] || return 1
    local etiqueta IFS='.'
    for etiqueta in $d; do
        validar_hostname "$etiqueta" || return 1
    done
    return 0
}

# Valida que un valor sea un entero no negativo
validar_entero() {
    [[ "$1" =~ ^[0-9]+$ ]] || return 1
    return 0
}

#-------------------------------------------------------------------------------
# 3. Funciones genericas de entrada de datos
#-------------------------------------------------------------------------------

# preguntar <variable_destino> <texto> <funcion_validadora> [valor_por_defecto]
#   Pregunta en bucle hasta que el dato sea valido.
preguntar() {
    local __var="$1" texto="$2" validador="$3" defecto="${4:-}"
    local entrada prompt

    while true; do
        if [[ -n "$defecto" ]]; then
            prompt="$texto [$C_VERDE$defecto$C_RST]: "
        else
            prompt="$texto: "
        fi
        printf '%b' "$prompt"
        IFS= read -r entrada || { msg_error "Entrada cerrada (EOF)."; exit 1; }

        # Si esta vacio y hay defecto, se usa el defecto
        if [[ -z "$entrada" && -n "$defecto" ]]; then
            entrada="$defecto"
        fi

        if [[ -z "$entrada" ]]; then
            msg_warn "El valor no puede estar vacio. Intentelo de nuevo."
            continue
        fi

        if "$validador" "$entrada"; then
            printf -v "$__var" '%s' "$entrada"
            return 0
        else
            msg_warn "Valor no valido para '$texto'. Intentelo de nuevo."
        fi
    done
}

# preguntar_si_no <texto>  -> devuelve 0 si SI, 1 si NO
preguntar_si_no() {
    local texto="$1" resp
    while true; do
        printf '%b' "$texto [s/n]: "
        IFS= read -r resp || { msg_error "Entrada cerrada (EOF)."; exit 1; }
        case "${resp,,}" in
            s|si|sí|y|yes) return 0 ;;
            n|no)          return 1 ;;
            *) msg_warn "Responda 's' (si) o 'n' (no)." ;;
        esac
    done
}

# confirmar_valor <descripcion> <valor>  -> 0 si lo confirma, 1 si quiere cambiarlo
confirmar_valor() {
    printf '  %s-> %s%s = %s%s%s\n' \
        "$C_AZUL" "$C_RST" "$1" "$C_NEG" "$2" "$C_RST"
    preguntar_si_no "  ¿Es correcto?"
}

# Acepta cualquier validador como un comando que siempre devuelve 0.
# Util para campos de texto libre que ya validamos de otra forma.
validar_libre() { [[ -n "$1" ]]; }

#-------------------------------------------------------------------------------
# 4. Funciones de logica de negocio
#-------------------------------------------------------------------------------

# Comprueba los requisitos del sistema
comprobar_requisitos() {
    titulo "Comprobacion de requisitos"
    if (( BASH_VERSINFO[0] < 4 )); then
        msg_error "Se requiere bash 4 o superior (arrays asociativos)."
        exit 1
    fi
    msg_ok "Version de bash compatible: ${BASH_VERSION}"

    if command -v named-checkzone >/dev/null 2>&1; then
        msg_ok "named-checkzone disponible: se validaran las zonas al final."
        TIENE_CHECKZONE=1
    else
        msg_warn "named-checkzone no encontrado (paquete bind9utils/bind9-utils)."
        msg_warn "Los ficheros se generaran igualmente pero NO se validaran."
        TIENE_CHECKZONE=0
    fi
}

# Pide y confirma los parametros generales de la zona
pedir_parametros_zona() {
    titulo "Datos generales de la zona"

    # --- Dominio --- (opcion critica: se confirma)
    while true; do
        preguntar DOMINIO "Nombre del dominio/subdominio (ej: subdominio3.dominio.org)" \
                  validar_dominio
        DOMINIO="${DOMINIO%.}"   # normaliza sin punto final
        confirmar_valor "Dominio de la zona" "$DOMINIO" && break
    done

    # --- Servidor de nombres primario --- (critico: se confirma)
    while true; do
        preguntar NS_PRIMARIO "FQDN del servidor DNS primario (ej: ns1.$DOMINIO)" \
                  validar_dominio "ns1.$DOMINIO"
        NS_PRIMARIO="${NS_PRIMARIO%.}"
        confirmar_valor "NS primario (SOA)" "$NS_PRIMARIO" && break
    done

    # --- Correo del administrador --- (critico: se confirma)
    while true; do
        local admin_raw
        preguntar admin_raw "Correo del administrador (formato admin.$DOMINIO o admin@$DOMINIO)" \
                  validar_libre "admin.$DOMINIO"
        # Si lo escriben con '@', lo convertimos al formato DNS (punto)
        admin_raw="${admin_raw/@/.}"
        admin_raw="${admin_raw%.}"
        if validar_dominio "$admin_raw"; then
            ADMIN="$admin_raw"
            confirmar_valor "Administrador (SOA)" "$ADMIN" && break
        else
            msg_warn "El correo no tiene un formato valido."
        fi
    done

    # --- Parametros SOA / TTL ---
    if preguntar_si_no "¿Desea usar los valores SOA/TTL estandar (TTL=$TTL, Serial=$SERIAL...)?"; then
        msg_info "Se usaran los valores SOA estandar."
    else
        preguntar TTL     "TTL de la zona (segundos)"        validar_entero "$TTL"
        preguntar SERIAL  "Serial inicial"                   validar_entero "$SERIAL"
        preguntar REFRESH "Refresh (segundos)"               validar_entero "$REFRESH"
        preguntar RETRY   "Retry (segundos)"                 validar_entero "$RETRY"
        preguntar EXPIRE  "Expire (segundos)"                validar_entero "$EXPIRE"
        preguntar NCTTL   "Negative Cache TTL (segundos)"    validar_entero "$NCTTL"
    fi
}

# Bucle interactivo de introduccion de registros NS
pedir_registros_ns() {
    titulo "Registros NS (servidores de nombres de la zona)"
    msg_info "Introduzca al menos un servidor NS. Deje vacio y pulse Intro para terminar."

    # El NS primario se anade automaticamente como primer NS
    NS_RECORDS+=("${NS_PRIMARIO}.")
    msg_ok "Anadido NS primario: ${NS_PRIMARIO}."

    while true; do
        printf '%b' "FQDN de NS adicional (Intro para terminar): "
        local ns
        IFS= read -r ns || break
        [[ -z "$ns" ]] && break
        ns="${ns%.}"
        if ! validar_dominio "$ns"; then
            msg_warn "FQDN no valido. Intentelo de nuevo."
            continue
        fi
        if confirmar_valor "Nuevo registro NS" "${ns}."; then
            NS_RECORDS+=("${ns}.")
            msg_ok "NS anadido."
        fi
    done
    msg_info "Total de registros NS: ${#NS_RECORDS[@]}"
}

# Anade (o acumula) un PTR a la zona inversa correspondiente, deducida de la IP
registrar_ptr_desde_ipv4() {
    local nombre="$1" ip="$2"
    local o1 o2 o3 o4
    IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
    local zona_inv="${o3}.${o2}.${o1}.in-addr.arpa"
    local fqdn="${nombre}.${DOMINIO}."
    # Acumulamos las lineas PTR por cada zona inversa detectada
    REV_ZONES["$zona_inv"]+="${o4}|${fqdn}"$'\n'
}

# Bucle interactivo de introduccion de registros A
pedir_registros_a() {
    titulo "Registros A (host -> IPv4)"
    msg_info "Por cada host se generara tambien su PTR en la zona inversa."
    msg_info "Deje el nombre vacio y pulse Intro para terminar."

    while true; do
        printf '%b' "Nombre del host (sin dominio, Intro para terminar): "
        local nombre
        IFS= read -r nombre || break
        [[ -z "$nombre" ]] && break
        if ! validar_hostname "$nombre"; then
            msg_warn "Nombre de host no valido (solo letras, digitos y guion)."
            continue
        fi

        local ip
        preguntar ip "  IPv4 para '$nombre'" validar_ipv4

        if confirmar_valor "Registro A" "$nombre  ->  $ip"; then
            A_RECORDS+=("${nombre}|${ip}")
            registrar_ptr_desde_ipv4 "$nombre" "$ip"
            msg_ok "Registro A y su PTR anadidos."
        fi
    done
    msg_info "Total de registros A: ${#A_RECORDS[@]}"
}

# Bucle interactivo de introduccion de registros AAAA
pedir_registros_aaaa() {
    titulo "Registros AAAA (host -> IPv6)"
    if ! preguntar_si_no "¿Desea anadir registros AAAA (IPv6)?"; then
        msg_info "Se omiten los registros AAAA."
        return 0
    fi
    msg_info "Nota: para IPv6 no se genera PTR automatico (zona ip6.arpa)."
    msg_info "Deje el nombre vacio y pulse Intro para terminar."

    while true; do
        printf '%b' "Nombre del host (sin dominio, Intro para terminar): "
        local nombre
        IFS= read -r nombre || break
        [[ -z "$nombre" ]] && break
        if ! validar_hostname "$nombre"; then
            msg_warn "Nombre de host no valido."
            continue
        fi

        local ip6
        preguntar ip6 "  IPv6 para '$nombre'" validar_ipv6

        if confirmar_valor "Registro AAAA" "$nombre  ->  $ip6"; then
            AAAA_RECORDS+=("${nombre}|${ip6}")
            msg_ok "Registro AAAA anadido."
        fi
    done
    msg_info "Total de registros AAAA: ${#AAAA_RECORDS[@]}"
}

# Bucle interactivo de introduccion de registros CNAME
pedir_registros_cname() {
    titulo "Registros CNAME (alias)"
    if ! preguntar_si_no "¿Desea anadir registros CNAME (alias)?"; then
        msg_info "Se omiten los registros CNAME."
        return 0
    fi
    msg_info "Deje el alias vacio y pulse Intro para terminar."

    while true; do
        printf '%b' "Alias (sin dominio, Intro para terminar): "
        local alias
        IFS= read -r alias || break
        [[ -z "$alias" ]] && break
        if ! validar_hostname "$alias"; then
            msg_warn "Alias no valido."
            continue
        fi

        local destino
        preguntar destino "  Destino del alias (host de esta zona o FQDN con punto final)" \
                  validar_libre
        # Si el destino no termina en punto, se asume host relativo de esta zona;
        # si termina en punto, se respeta tal cual (FQDN absoluto).
        if [[ "$destino" != *. ]]; then
            if ! validar_hostname "$destino"; then
                msg_warn "El destino relativo no es un nombre de host valido."
                continue
            fi
        else
            if ! validar_dominio "${destino%.}"; then
                msg_warn "El destino absoluto (FQDN) no es valido."
                continue
            fi
        fi

        if confirmar_valor "Registro CNAME" "$alias  ->  $destino"; then
            CNAME_RECORDS+=("${alias}|${destino}")
            msg_ok "Registro CNAME anadido."
        fi
    done
    msg_info "Total de registros CNAME: ${#CNAME_RECORDS[@]}"
}

# Bucle interactivo de introduccion de registros MX
pedir_registros_mx() {
    titulo "Registros MX (servidores de correo)"
    if ! preguntar_si_no "¿Desea anadir registros MX (correo)?"; then
        msg_info "Se omiten los registros MX."
        return 0
    fi
    msg_info "Deje la prioridad vacia y pulse Intro para terminar."

    while true; do
        printf '%b' "Prioridad MX (numero, Intro para terminar): "
        local prio
        IFS= read -r prio || break
        [[ -z "$prio" ]] && break
        if ! validar_entero "$prio"; then
            msg_warn "La prioridad debe ser un numero entero."
            continue
        fi

        local servidor
        preguntar servidor "  Servidor de correo (host de esta zona o FQDN con punto final)" \
                  validar_libre
        if [[ "$servidor" != *. ]]; then
            if ! validar_hostname "$servidor"; then
                msg_warn "El servidor relativo no es un nombre de host valido."
                continue
            fi
        else
            if ! validar_dominio "${servidor%.}"; then
                msg_warn "El servidor absoluto (FQDN) no es valido."
                continue
            fi
        fi

        if confirmar_valor "Registro MX" "prioridad $prio  ->  $servidor"; then
            MX_RECORDS+=("${prio}|${servidor}")
            msg_ok "Registro MX anadido."
        fi
    done
    msg_info "Total de registros MX: ${#MX_RECORDS[@]}"
}

# Pide y valida el directorio de destino de los ficheros
pedir_directorio_destino() {
    titulo "Directorio de destino"
    while true; do
        preguntar DIR_DESTINO "Directorio donde guardar los ficheros de zona" \
                  validar_libre "/etc/bind"
        # Expandir ~ manualmente
        DIR_DESTINO="${DIR_DESTINO/#\~/$HOME}"

        if [[ -d "$DIR_DESTINO" ]]; then
            if [[ -w "$DIR_DESTINO" ]]; then
                msg_ok "El directorio existe y se puede escribir en el."
                return 0
            else
                msg_warn "El directorio existe pero NO tiene permisos de escritura."
                msg_warn "Pruebe a ejecutar el script con sudo o elija otra ruta."
            fi
        else
            if preguntar_si_no "El directorio no existe. ¿Desea crearlo?"; then
                if mkdir -p "$DIR_DESTINO" 2>/dev/null; then
                    msg_ok "Directorio creado: $DIR_DESTINO"
                    return 0
                else
                    msg_error "No se pudo crear el directorio (¿permisos?)."
                fi
            fi
        fi
    done
}

# Construye y devuelve por stdout el bloque SOA (comun a directa e inversa)
generar_bloque_soa() {
    local nombre_zona="$1"
    cat <<EOF
\$TTL ${TTL}
@       IN      SOA     ${NS_PRIMARIO}. ${ADMIN}. (
                        ${SERIAL}        ; Serial
                        ${REFRESH}        ; Refresh
                        ${RETRY}        ; Retry
                        ${EXPIRE}        ; Expire
                        ${NCTTL} )      ; Negative Cache TTL
EOF
}

# Escribe el fichero de ZONA DIRECTA
escribir_zona_directa() {
    local fichero="$DIR_DESTINO/db.${DOMINIO}"
    titulo "Generando zona directa: $fichero"

    # Si ya existe, pedimos confirmacion para sobrescribir
    if [[ -e "$fichero" ]]; then
        if ! preguntar_si_no "El fichero '$fichero' ya existe. ¿Sobrescribir?"; then
            msg_warn "Zona directa NO generada (cancelado por el usuario)."
            return 1
        fi
    fi

    {
        echo ";"
        echo "; Fichero de zona DIRECTA: ${DOMINIO}"
        echo "; Generado por ${SCRIPT_NAME} el $(date '+%Y-%m-%d %H:%M:%S')"
        echo ";"
        generar_bloque_soa "$DOMINIO"
        echo ";"
        echo "; Servidores de nombres (NS)"
        local ns
        for ns in "${NS_RECORDS[@]}"; do
            printf '%-24s IN      NS      %s\n' "" "$ns"
        done

        if (( ${#A_RECORDS[@]} > 0 )); then
            echo ";"
            echo "; Registros A (IPv4)"
            local r nombre ip
            for r in "${A_RECORDS[@]}"; do
                IFS='|' read -r nombre ip <<< "$r"
                printf '%-24s IN      A       %s\n' "$nombre" "$ip"
            done
        fi

        if (( ${#AAAA_RECORDS[@]} > 0 )); then
            echo ";"
            echo "; Registros AAAA (IPv6)"
            local r nombre ip6
            for r in "${AAAA_RECORDS[@]}"; do
                IFS='|' read -r nombre ip6 <<< "$r"
                printf '%-24s IN      AAAA    %s\n' "$nombre" "$ip6"
            done
        fi

        if (( ${#CNAME_RECORDS[@]} > 0 )); then
            echo ";"
            echo "; Alias (CNAME)"
            local r alias destino
            for r in "${CNAME_RECORDS[@]}"; do
                IFS='|' read -r alias destino <<< "$r"
                printf '%-24s IN      CNAME   %s\n' "$alias" "$destino"
            done
        fi

        if (( ${#MX_RECORDS[@]} > 0 )); then
            echo ";"
            echo "; Servidores de correo (MX)"
            local r prio servidor
            for r in "${MX_RECORDS[@]}"; do
                IFS='|' read -r prio servidor <<< "$r"
                printf '%-24s IN      MX      %-4s %s\n' "@" "$prio" "$servidor"
            done
        fi
        echo ""   # BIND exige que el fichero termine con una linea vacia
    } > "$fichero" || { msg_error "No se pudo escribir '$fichero'."; return 1; }

    msg_ok "Zona directa generada correctamente."
    FICHEROS_GENERADOS+=("$DOMINIO|$fichero")
    return 0
}

# Escribe TODOS los ficheros de ZONA INVERSA detectados a partir de los A
escribir_zonas_inversas() {
    titulo "Generando zona(s) inversa(s)"

    if (( ${#REV_ZONES[@]} == 0 )); then
        msg_warn "No hay registros A: no se genera ninguna zona inversa."
        return 0
    fi

    local zona
    for zona in "${!REV_ZONES[@]}"; do
        # Nombre de fichero a partir de la red (in-addr.arpa -> db.x.y.z)
        local red="${zona%.in-addr.arpa}"          # ej: 17.15.13
        local o3 o2 o1
        IFS='.' read -r o3 o2 o1 <<< "$red"
        local fichero="$DIR_DESTINO/db.${o1}.${o2}.${o3}"

        msg_info "Zona inversa: $zona  ->  $fichero"

        if [[ -e "$fichero" ]]; then
            if ! preguntar_si_no "El fichero '$fichero' ya existe. ¿Sobrescribir?"; then
                msg_warn "Zona inversa '$zona' NO generada (cancelado)."
                continue
            fi
        fi

        {
            echo ";"
            echo "; Fichero de zona INVERSA: ${zona}"
            echo "; Generado por ${SCRIPT_NAME} el $(date '+%Y-%m-%d %H:%M:%S')"
            echo ";"
            generar_bloque_soa "$zona"
            echo ";"
            echo "; Servidores de nombres (NS)"
            local ns
            for ns in "${NS_RECORDS[@]}"; do
                printf '%-8s IN      NS      %s\n' "" "$ns"
            done
            echo ";"
            echo "; Registros PTR (resolucion inversa)"
            # Las lineas PTR de esta zona estan acumuladas en REV_ZONES[zona]
            local linea octeto fqdn
            while IFS='|' read -r octeto fqdn; do
                [[ -z "$octeto" ]] && continue
                printf '%-8s IN      PTR     %s\n' "$octeto" "$fqdn"
            done <<< "${REV_ZONES[$zona]}"
            echo ""   # linea vacia final obligatoria
        } > "$fichero" || { msg_error "No se pudo escribir '$fichero'."; continue; }

        msg_ok "Zona inversa '$zona' generada correctamente."
        FICHEROS_GENERADOS+=("$zona|$fichero")
    done
    return 0
}

# Valida con named-checkzone todos los ficheros generados
validar_ficheros() {
    titulo "Validacion de los ficheros generados"
    if (( TIENE_CHECKZONE == 0 )); then
        msg_warn "named-checkzone no disponible: se omite la validacion."
        return 0
    fi
    if (( ${#FICHEROS_GENERADOS[@]} == 0 )); then
        msg_warn "No se genero ningun fichero: nada que validar."
        return 0
    fi

    local item zona fichero fallos=0
    for item in "${FICHEROS_GENERADOS[@]}"; do
        IFS='|' read -r zona fichero <<< "$item"
        if named-checkzone "$zona" "$fichero" >/dev/null 2>&1; then
            msg_ok "Zona '$zona' valida."
        else
            msg_error "Zona '$zona' con ERRORES. Detalle:"
            named-checkzone "$zona" "$fichero" 2>&1 | sed 's/^/        /'
            (( fallos++ ))
        fi
    done

    if (( fallos > 0 )); then
        msg_error "Se detectaron $fallos fichero(s) con errores. Revise la salida."
        return 1
    fi
    msg_ok "Todos los ficheros han pasado la validacion."
    return 0
}

# Muestra un resumen final
mostrar_resumen() {
    titulo "Resumen final"
    if (( ${#FICHEROS_GENERADOS[@]} == 0 )); then
        msg_warn "No se genero ningun fichero."
        return 0
    fi
    echo "Se han generado los siguientes ficheros:"
    local item zona fichero
    for item in "${FICHEROS_GENERADOS[@]}"; do
        IFS='|' read -r zona fichero <<< "$item"
        printf '   %s%s%s   (zona: %s)\n' "$C_VERDE" "$fichero" "$C_RST" "$zona"
    done
    echo
    msg_info "Recuerde declarar estas zonas en /etc/bind/named.conf.local"
    msg_info "y reiniciar el servicio:  sudo systemctl restart bind9"
}

#-------------------------------------------------------------------------------
# 5. Funcion principal
#-------------------------------------------------------------------------------
main() {
    declare -a FICHEROS_GENERADOS=()
    declare -i TIENE_CHECKZONE=0

    printf '%s' "$C_NEG"
    cat <<'BANNER'
+--------------------------------------------------------------+
|       GENERADOR DE FICHEROS DE ZONA DNS PARA BIND9           |
|       Zona directa + zona(s) inversa(s) automaticas          |
+--------------------------------------------------------------+
BANNER
    printf '%s' "$C_RST"

    comprobar_requisitos
    pedir_parametros_zona
    pedir_registros_ns
    pedir_registros_a
    pedir_registros_aaaa
    pedir_registros_cname
    pedir_registros_mx
    pedir_directorio_destino

    # Confirmacion global antes de escribir nada en disco
    titulo "Confirmacion previa a la escritura"
    echo "  Dominio .............. $DOMINIO"
    echo "  NS primario .......... $NS_PRIMARIO"
    echo "  Administrador ........ $ADMIN"
    echo "  Directorio destino ... $DIR_DESTINO"
    echo "  Registros NS ......... ${#NS_RECORDS[@]}"
    echo "  Registros A .......... ${#A_RECORDS[@]}"
    echo "  Registros AAAA ....... ${#AAAA_RECORDS[@]}"
    echo "  Registros CNAME ...... ${#CNAME_RECORDS[@]}"
    echo "  Registros MX ......... ${#MX_RECORDS[@]}"
    echo "  Zonas inversas ....... ${#REV_ZONES[@]}"
    echo
    if ! preguntar_si_no "¿Generar los ficheros con estos datos?"; then
        msg_warn "Operacion cancelada por el usuario. No se ha escrito nada."
        exit 0
    fi

    escribir_zona_directa  || msg_warn "La zona directa no se genero."
    escribir_zonas_inversas

    validar_ficheros || true   # no abortamos: el resumen sigue siendo util
    mostrar_resumen

    msg_ok "Proceso finalizado."
}

# Punto de entrada
main "$@"