#!/bin/bash

# ============================================
# Script: crear_zona.sh
# Descripción: Genera un fichero de zona DNS
#              directa a partir de un dominio
# Uso: ./crear_zona.sh <dominio>
# Ejemplo: ./crear_zona.sh dominio.org
# ============================================

# ---- Colores para la salida ----
VERDE='\033[0;32m'
ROJO='\033[0;31m'
AMARILLO='\033[1;33m'
NC='\033[0m' # Sin color

# ---- Verificar que se pasó un argumento ----
if [ -z "$1" ]; then
    echo -e "${ROJO}❌ Error: Debes indicar un dominio.${NC}"
    echo -e "${AMARILLO}Uso: ./crear_zona.sh <dominio>${NC}"
    echo -e "${AMARILLO}Ejemplo: ./crear_zona.sh dominio.org${NC}"
    exit 1
fi

# ---- Variables ----
DOMINIO="$1"
FECHA=$(date +%Y%m%d)
SERIAL="${FECHA}01"
FICHERO="db.${DOMINIO}"
RUTA_SALIDA="/etc/bind/${FICHERO}"

# ---- Verificar si el fichero ya existe ----
if [ -f "$RUTA_SALIDA" ]; then
    echo -e "${AMARILLO}⚠️  El fichero ${RUTA_SALIDA} ya existe.${NC}"
    read -p "¿Deseas sobreescribirlo? (s/n): " RESPUESTA
    if [[ "$RESPUESTA" != "s" && "$RESPUESTA" != "S" ]]; then
        echo -e "${ROJO}❌ Operación cancelada.${NC}"
        exit 1
    fi
fi

# ---- Generar el fichero de zona ----
echo -e "${VERDE}🔧 Generando fichero de zona para: ${DOMINIO}${NC}"

cat > "$RUTA_SALIDA" << EOF
; ============================================
; Fichero de zona directa para ${DOMINIO}
; Generado automáticamente el $(date '+%Y-%m-%d %H:%M:%S')
; ============================================

\$TTL 3600
@   IN  SOA ns1.${DOMINIO}. admin.${DOMINIO}. (
            ${SERIAL}   ; Serial
            3600        ; Refresh  (1 hora)
            1800        ; Retry    (30 minutos)
            604800      ; Expire   (1 semana)
            86400 )     ; Minimum TTL (1 dia)

; ---- Servidores de nombres ----
    IN  NS  master.${DOMINIO}.
    IN  NS  slave.${DOMINIO}.

; ---- Registros A (nombre -> IP) ----
ns1         IN  A   192.168.1.10
ns2         IN  A   192.168.1.11
master      IN  A   192.168.1.10
slave       IN  A   192.168.1.11
mail        IN  A   192.168.1.20
www         IN  A   192.168.1.30
ftp         IN  A   192.168.1.40

; ---- Registros CNAME (alias) ----
blog        IN  CNAME   www.${DOMINIO}.
shop        IN  CNAME   www.${DOMINIO}.

; ---- Registros MX (correo) ----
@           IN  MX  10  mail.${DOMINIO}.
EOF

# ---- Verificar que se creó correctamente ----
if [ $? -eq 0 ]; then
    echo -e "${VERDE}✅ Fichero creado correctamente: ${RUTA_SALIDA}${NC}"
else
    echo -e "${ROJO}❌ Error al crear el fichero.${NC}"
    exit 1
fi

# ---- Dar permisos correctos ----
chown bind:bind "$RUTA_SALIDA"
chmod 644 "$RUTA_SALIDA"
echo -e "${VERDE}✅ Permisos aplicados correctamente.${NC}"

# ---- Mostrar el fichero generado ----
echo ""
echo -e "${AMARILLO}📄 Contenido del fichero generado:${NC}"
echo "--------------------------------------------"
cat "$RUTA_SALIDA"
echo "--------------------------------------------"

# ---- Validar la zona con named-checkzone ----
echo ""
echo -e "${AMARILLO}🔍 Validando la zona con named-checkzone...${NC}"
named-checkzone "${DOMINIO}" "$RUTA_SALIDA"

if [ $? -eq 0 ]; then
    echo -e "${VERDE}✅ Zona válida. Puedes añadirla a named.conf.local${NC}"
    echo ""
    echo -e "${AMARILLO}📋 Añade esto a /etc/bind/named.conf.local:${NC}"
    echo "--------------------------------------------"
    echo "zone \"${DOMINIO}\" {"
    echo "    type master;"
    echo "    file \"${RUTA_SALIDA}\";"
    echo "    allow-transfer { none; };"
    echo "    notify yes;"
    echo "};"
    echo "--------------------------------------------"
else
    echo -e "${ROJO}❌ La zona tiene errores. Revisa el fichero.${NC}"
    exit 1
fi

exit 0