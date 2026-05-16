#!/bin/bash

# ============================================
# Script: crear_zonas_slave.sh
# Descripción: Agrega zona directa e inversa
#              al named.conf.local del SLAVE
# Uso: sudo ./crear_zonas_slave.sh
# ============================================

# ---- Colores ----
VERDE='\033[0;32m'
ROJO='\033[0;31m'
AMARILLO='\033[1;33m'
AZUL='\033[0;34m'
NC='\033[0m'

NAMED_LOCAL="/etc/bind/named.conf.local"

echo ""
echo -e "${AZUL}============================================${NC}"
echo -e "${AZUL}  Agregar zonas al SLAVE - named.conf.local${NC}"
echo -e "${AZUL}============================================${NC}"
echo ""

# ---- Verificar que se ejecuta como root ----
if [ "$EUID" -ne 0 ]; then
    echo -e "${ROJO}❌ Error: Ejecuta el script como root (sudo).${NC}"
    exit 1
fi

# ---- Verificar que existe named.conf.local ----
if [ ! -f "$NAMED_LOCAL" ]; then
    echo -e "${ROJO}❌ Error: No existe el fichero ${NAMED_LOCAL}${NC}"
    exit 1
fi

# ---- Pedir datos al usuario ----
echo -e "${AMARILLO}📌 Introduce los datos de la zona:${NC}"
echo ""

# Nombre del dominio
read -p "   Nombre del dominio (ej: dominio.org): " DOMINIO
if [ -z "$DOMINIO" ]; then
    echo -e "${ROJO}❌ Error: El dominio no puede estar vacío.${NC}"
    exit 1
fi

# Dirección de red con máscara
read -p "   Dirección de red (ej: 172.26.10.0/24): " RED_CIDR
if [ -z "$RED_CIDR" ]; then
    echo -e "${ROJO}❌ Error: La red no puede estar vacía.${NC}"
    exit 1
fi

# Validar formato de red CIDR
if ! echo "$RED_CIDR" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'; then
    echo -e "${ROJO}❌ Error: Formato incorrecto. Usa formato: 172.26.10.0/24${NC}"
    exit 1
fi

# IP del servidor MASTER
read -p "   IP del servidor MASTER (ej: 192.168.1.100): " IP_MASTER
if [ -z "$IP_MASTER" ]; then
    echo -e "${ROJO}❌ Error: La IP del master no puede estar vacía.${NC}"
    exit 1
fi

# ---- Calcular zona inversa ----
RED_BASE=$(echo "$RED_CIDR" | cut -d'/' -f1)
OCTETO1=$(echo "$RED_BASE" | cut -d'.' -f1)
OCTETO2=$(echo "$RED_BASE" | cut -d'.' -f2)
OCTETO3=$(echo "$RED_BASE" | cut -d'.' -f3)
MASCARA=$(echo "$RED_CIDR" | cut -d'/' -f2)

# Zona inversa: invertir los octetos
ZONA_INVERSA="${OCTETO3}.${OCTETO2}.${OCTETO1}.in-addr.arpa"

# Nombre del fichero zona inversa
FICHERO_INVERSO="db.${OCTETO1}.${OCTETO2}.${OCTETO3}"

# Rutas de los ficheros (slave guarda en /var/cache/bind)
RUTA_DIRECTA="/var/cache/bind/db.${DOMINIO}"
RUTA_INVERSA="/var/cache/bind/${FICHERO_INVERSO}"

# ---- Mostrar resumen ----
echo ""
echo -e "${AMARILLO}📋 Resumen de lo que se va a agregar:${NC}"
echo "--------------------------------------------"
echo -e "  Dominio:              ${VERDE}${DOMINIO}${NC}"
echo -e "  Red permitida:        ${VERDE}${RED_CIDR}${NC}"
echo -e "  IP Master:            ${VERDE}${IP_MASTER}${NC}"
echo -e "  Zona directa:         ${VERDE}${DOMINIO}${NC}"
echo -e "  Fichero zona directa: ${VERDE}${RUTA_DIRECTA}${NC}"
echo -e "  Zona inversa:         ${VERDE}${ZONA_INVERSA}${NC}"
echo -e "  Fichero zona inversa: ${VERDE}${RUTA_INVERSA}${NC}"
echo "--------------------------------------------"
read -p "¿Es correcto? (s/n): " CONFIRM
if [[ "$CONFIRM" != "s" && "$CONFIRM" != "S" ]]; then
    echo -e "${ROJO}❌ Operación cancelada.${NC}"
    exit 1
fi

# ---- Verificar si la zona directa ya existe ----
if grep -q "zone \"${DOMINIO}\"" "$NAMED_LOCAL"; then
    echo -e "${ROJO}❌ Error: La zona ${DOMINIO} ya existe en ${NAMED_LOCAL}${NC}"
    exit 1
fi

# ---- Verificar si la zona inversa ya existe ----
if grep -q "zone \"${ZONA_INVERSA}\"" "$NAMED_LOCAL"; then
    echo -e "${ROJO}❌ Error: La zona inversa ${ZONA_INVERSA} ya existe en ${NAMED_LOCAL}${NC}"
    exit 1
fi

# ---- Hacer backup del fichero ----
cp "$NAMED_LOCAL" "${NAMED_LOCAL}.bak"
echo -e "${VERDE}✅ Backup creado: ${NAMED_LOCAL}.bak${NC}"

# ---- Agregar zonas al named.conf.local ----
cat >> "$NAMED_LOCAL" << EOF

//Busqueda directa del dominio ${DOMINIO}
zone "${DOMINIO}"
{
        type slave;
        file "${RUTA_DIRECTA}";
        masters { ${IP_MASTER}; };
        allow-query { 127.0.0.1; ${RED_CIDR}; };
        allow-transfer { none; };
};

//Busqueda inversa del dominio ${DOMINIO}
zone "${ZONA_INVERSA}"
{
        type slave;
        file "${RUTA_INVERSA}";
        masters { ${IP_MASTER}; };
        allow-query { 127.0.0.1; ${RED_CIDR}; };
        allow-transfer { none; };
};
EOF

# ---- Verificar que se escribió correctamente ----
if [ $? -eq 0 ]; then
    echo -e "${VERDE}✅ Zonas agregadas correctamente a ${NAMED_LOCAL}${NC}"
else
    echo -e "${ROJO}❌ Error al escribir en ${NAMED_LOCAL}${NC}"
    echo -e "${AMARILLO}⚠️  Restaurando backup...${NC}"
    cp "${NAMED_LOCAL}.bak" "$NAMED_LOCAL"
    exit 1
fi

# ---- Validar la configuración ----
echo ""
echo -e "${AMARILLO}🔍 Validando la configuración...${NC}"
named-checkconf

if [ $? -eq 0 ]; then
    echo -e "${VERDE}✅ Configuración válida.${NC}"
else
    echo -e "${ROJO}❌ Error en la configuración. Restaurando backup...${NC}"
    cp "${NAMED_LOCAL}.bak" "$NAMED_LOCAL"
    exit 1
fi

# ---- Mostrar el resultado ----
echo ""
echo -e "${AMARILLO}📄 Zonas agregadas:${NC}"
echo "--------------------------------------------"
grep -A 8 "zone \"${DOMINIO}\"" "$NAMED_LOCAL"
echo "--------------------------------------------"

# ---- Recargar BIND9 ----
echo ""
read -p "¿Deseas recargar BIND9 ahora? (s/n): " RELOAD
if [[ "$RELOAD" == "s" || "$RELOAD" == "S" ]]; then
    systemctl reload bind9
    if [ $? -eq 0 ]; then
        echo -e "${VERDE}✅ BIND9 recargado correctamente.${NC}"
        echo -e "${AMARILLO}⚠️  El slave intentará transferir las zonas del master automáticamente.${NC}"
    else
        echo -e "${ROJO}❌ Error al recargar BIND9.${NC}"
    fi
fi

echo ""
echo -e "${AMARILLO}⚠️  El slave descargará los ficheros de zona automáticamente en:${NC}"
echo -e "   ${VERDE}${RUTA_DIRECTA}${NC}"
echo -e "   ${VERDE}${RUTA_INVERSA}${NC}"
echo ""

exit 0