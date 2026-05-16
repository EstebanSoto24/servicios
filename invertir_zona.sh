#!/bin/bash

# ============================================
# Script: genera_zona_inversa.sh
# Descripción: Genera ficheros de zona inversa
#              a partir de una zona directa.
#              Extrae registros A y genera PTR.
# Uso: sudo ./genera_zona_inversa.sh <fichero_zona> [directorio_salida]
# Ejemplo:
#   ./genera_zona_inversa.sh db.dominio.org
#   ./genera_zona_inversa.sh db.dominio.org ./zonas_inversas/
# ============================================

# ---- Colores ----
VERDE='\033[0;32m'
ROJO='\033[0;31m'
AMARILLO='\033[1;33m'
NC='\033[0m'

# ---- Verificar argumentos ----
if [ $# -lt 1 ]; then
    echo "Uso: $0 <fichero_zona_directa> [directorio_salida]"
    echo ""
    echo "Ejemplo:"
    echo "  $0 db.dominio.org"
    echo "  $0 db.dominio.org ./zonas_inversas/"
    exit 1
fi

INPUT_FILE="$1"
OUTPUT_DIR="${2:-.}"

# ---- Verificar que el fichero existe ----
if [ ! -f "$INPUT_FILE" ]; then
    echo -e "${ROJO}Error: No se encontró el fichero '$INPUT_FILE'${NC}"
    exit 1
fi

echo "[*] Leyendo fichero de zona: $INPUT_FILE"

# ---- Eliminar comentarios y unir en una sola linea (igual que Python) ----
# Esto resuelve el problema del SOA multilínea
CONTENT=$(sed 's/;[^$]*//' "$INPUT_FILE" | tr -s ' \t\n' ' ')

# ---- Extraer campos del SOA ----
SOA_NS=$(echo "$CONTENT" | awk '{
    for(i=1;i<=NF;i++) {
        if($i=="SOA") { print $(i+1); break }
    }
}')

SOA_EMAIL=$(echo "$CONTENT" | awk '{
    for(i=1;i<=NF;i++) {
        if($i=="SOA") { print $(i+2); break }
    }
}')

# El serial es el primer número después del "(" del SOA
SOA_SERIAL=$(echo "$CONTENT" | grep -oP 'SOA\s+\S+\s+\S+\s+\(\s*\K[0-9]+')

# ---- Valores por defecto si no se encontró el SOA ----
SOA_NS="${SOA_NS:-ns1.ejemplo.com.}"
SOA_EMAIL="${SOA_EMAIL:-admin.ejemplo.com.}"
SOA_SERIAL="${SOA_SERIAL:-$(date +%Y%m%d)01}"

# ---- Extraer registros NS ----
mapfile -t NS_RECORDS < <(
    sed 's/;.*//' "$INPUT_FILE" | \
    awk '/IN[[:space:]]+NS[[:space:]]/ { print $NF }'
)

# ---- Extraer registros A ----
declare -A A_RECORDS

while read -r HOSTNAME IP; do
    # Saltar si hostname es @ o vacío
    [ -z "$HOSTNAME" ] || [ "$HOSTNAME" = "@" ] && continue

    # Validar que sea una IP válida
    if [[ "$IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        A_RECORDS["$IP"]="$HOSTNAME"
    else
        echo -e "${AMARILLO}Advertencia: IP inválida '$IP', omitida${NC}"
    fi
done < <(
    sed 's/;.*//' "$INPUT_FILE" | \
    awk '/IN[[:space:]]+A[[:space:]]+[0-9]/ { print $1, $NF }'
)

# ---- Verificar que se encontraron registros A ----
if [ ${#A_RECORDS[@]} -eq 0 ]; then
    echo -e "${ROJO}Error: No se encontraron registros A en el fichero${NC}"
    exit 1
fi

echo "[+] Se encontraron ${#A_RECORDS[@]} registros A"

# ---- Agrupar IPs por subred /24 ----
declare -A SUBNETS

for IP in "${!A_RECORDS[@]}"; do
    # Extraer los primeros 3 octetos (subred /24)
    SUBNET=$(echo "$IP" | cut -d'.' -f1-3)
    if [ -z "${SUBNETS[$SUBNET]}" ]; then
        SUBNETS[$SUBNET]="$IP"
    else
        SUBNETS[$SUBNET]="${SUBNETS[$SUBNET]} $IP"
    fi
done

echo "[+] Se identificaron ${#SUBNETS[@]} subred(es)"
echo ""
echo "[*] Generando ficheros de zona inversa..."
echo ""

# ---- Crear directorio de salida si no existe ----
mkdir -p "$OUTPUT_DIR"

# ---- Generar fichero de zona inversa por cada subred ----
for SUBNET in "${!SUBNETS[@]}"; do

    # Extraer octetos
    OCT1=$(echo "$SUBNET" | cut -d'.' -f1)
    OCT2=$(echo "$SUBNET" | cut -d'.' -f2)
    OCT3=$(echo "$SUBNET" | cut -d'.' -f3)

    # Nombre de zona inversa: invertir los octetos (igual que Python)
    REVERSE_ZONE="${OCT3}.${OCT2}.${OCT1}"

    # Fichero de salida
    OUTPUT_FILE="${OUTPUT_DIR}/db.${REVERSE_ZONE}"

    # IPs de esta subred
    IPS="${SUBNETS[$SUBNET]}"

    # Contar registros
    RECORD_COUNT=$(echo "$IPS" | wc -w)

    # ---- Generar el contenido del fichero de zona inversa ----
    {
        echo "; Zona inversa para ${SUBNET}.0/24"
        echo "; Nombre de zona: ${REVERSE_ZONE}.in-addr.arpa"
        echo "; Generado automaticamente: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ";"
        echo '$TTL 3600'
        echo "@   IN  SOA ${SOA_NS} ${SOA_EMAIL} ("
        echo "            ${SOA_SERIAL}  ; Serial"
        echo "            3600        ; Refresh"
        echo "            1800        ; Retry"
        echo "            604800      ; Expire"
        echo "            86400 )     ; Minimum TTL"
        echo ""

        # Registros NS
        if [ ${#NS_RECORDS[@]} -gt 0 ]; then
            for NS in "${NS_RECORDS[@]}"; do
                echo "    IN  NS  ${NS}"
            done
        else
            echo "    IN  NS  ns1.ejemplo.com."
        fi

        echo ""
        echo "; Registros PTR"

        # Registros PTR ordenados por último octeto (igual que Python)
        for IP in $(echo "$IPS" | tr ' ' '\n' | sort -t'.' -k4 -n); do
            HOSTNAME="${A_RECORDS[$IP]}"

            # Añadir punto final si no lo tiene (igual que Python)
            [[ "$HOSTNAME" != *. ]] && HOSTNAME="${HOSTNAME}."

            # Extraer último octeto
            LAST_OCTET=$(echo "$IP" | cut -d'.' -f4)

            echo "${LAST_OCTET}   IN  PTR ${HOSTNAME}"
        done

    } > "$OUTPUT_FILE"

    echo -e "[+] Creado: ${VERDE}${OUTPUT_FILE}${NC}"
    echo "    Subred:        ${SUBNET}.0/24"
    echo "    Registros PTR: ${RECORD_COUNT}"
    echo ""
done

echo "[*] Proceso completado"
exit 0