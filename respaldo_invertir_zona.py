#!/usr/bin/env python3
"""
Script para generar ficheros de zona DNS inversa a partir de una zona directa.
Extrae registros A y genera los correspondientes registros PTR.
"""

import re
import sys
from collections import defaultdict
from datetime import datetime
from ipaddress import IPv4Address, IPv4Network

def parse_zone_file(filename):
    """
    Parsea un fichero de zona DNS directa y extrae registros A.
    Retorna un diccionario con direcciones IP y hostnames.
    """
    records = {}
    soa_record = None
    ns_records = []
    
    try:
        with open(filename, 'r') as f:
            lines = f.readlines()
    except FileNotFoundError:
        print(f"Error: No se encontró el fichero '{filename}'")
        sys.exit(1)
    
    # Eliminar comentarios y líneas vacías
    cleaned_lines = []
    for line in lines:
        # Eliminar comentarios
        if ';' in line:
            line = line[:line.index(';')]
        line = line.strip()
        if line:
            cleaned_lines.append(line)
    
    # Procesar líneas
    content = ' '.join(cleaned_lines)
    
    # Buscar registros SOA
    soa_pattern = r'@\s+IN\s+SOA\s+(\S+)\s+(\S+)\s+\(\s*(\d+)'
    soa_match = re.search(soa_pattern, content)
    if soa_match:
        soa_record = {
            'ns': soa_match.group(1),
            'email': soa_match.group(2),
            'serial': soa_match.group(3)
        }
    
    # Buscar registros NS
    ns_pattern = r'@?\s+IN\s+NS\s+(\S+)'
    ns_matches = re.findall(ns_pattern, content)
    ns_records = ns_matches
    
    # Buscar registros A
    a_pattern = r'(\S+)\s+IN\s+A\s+(\d+\.\d+\.\d+\.\d+)'
    a_matches = re.findall(a_pattern, content)
    
    for hostname, ip in a_matches:
        if hostname != '@':
            records[ip] = hostname
    
    return records, soa_record, ns_records

def group_by_subnet(records):
    """
    Agrupa los registros por subred.
    Retorna un diccionario donde la clave es la subred /24
    """
    subnets = defaultdict(dict)
    
    for ip, hostname in records.items():
        try:
            ip_obj = IPv4Address(ip)
            # Asumir /24 por defecto
            subnet = f"{ip_obj.version}.{ip_obj.packed[0]}.{ip_obj.packed[1]}.{ip_obj.packed[2]}"
            subnet_addr = f"{ip_obj.packed[0]}.{ip_obj.packed[1]}.{ip_obj.packed[2]}.0/24"
            subnets[subnet_addr][ip] = hostname
        except ValueError:
            print(f"Advertencia: IP inválida '{ip}', omitida")
            continue
    
    return subnets

def generate_reverse_zone(subnet, records, soa_record, ns_records, origin_domain):
    """
    Genera el contenido de un fichero de zona inversa.
    """
    # Parsear la subred
    network = IPv4Network(subnet)
    
    # Crear el nombre de la zona inversa
    octets = str(network.network_address).split('.')[:3]
    reverse_zone_name = f"{'.'.join(reversed(octets))}"
    
    # Extraer el dominio principal del SOA
    if soa_record:
        soa_ns = soa_record['ns']
        soa_email = soa_record['email']
        serial = int(soa_record['serial'])
    else:
        soa_ns = "ns1.ejemplo.com."
        soa_email = "admin.ejemplo.com."
        serial = int(datetime.now().strftime('%Y%m%d01'))
    
    # Generar contenido del fichero
    content = f"; Zona inversa para {subnet}\n"
    content += f"; Nombre de zona: {reverse_zone_name}\n"
    content += f"; Generado automáticamente\n"
    content += f";\n"
    content += f"$TTL 3600\n"
    content += f"@   IN  SOA {soa_ns} {soa_email} (\n"
    content += f"            {serial}  ; Serial\n"
    content += f"            3600        ; Refresh\n"
    content += f"            1800        ; Retry\n"
    content += f"            604800      ; Expire\n"
    content += f"            86400 )     ; Minimum TTL\n"
    content += f"\n"
    
    # Añadir registros NS
    if ns_records:
        for ns in ns_records:
            content += f"    IN  NS  {ns}\n"
    else:
        content += f"    IN  NS  ns1.ejemplo.com.\n"
    
    content += f"\n; Registros PTR\n"
    
    # Añadir registros PTR
    for ip in sorted(records.keys(), key=lambda x: IPv4Address(x)):
        hostname = records[ip]
        if not hostname.endswith('.'):
            hostname += '.'
        
        # Extraer el último octeto de la IP
        last_octet = str(IPv4Address(ip)).split('.')[-1]
        content += f"{last_octet}   IN  PTR {hostname}\n"
    
    return reverse_zone_name, content

def main():
    """
    Función principal.
    """
    if len(sys.argv) < 2:
        print("Uso: python3 generate_reverse_zone.py <fichero_zona_directa> [output_dir]")
        print("\nEjemplo:")
        print("  python3 generate_reverse_zone.py zona_ejemplo.com.txt")
        print("  python3 generate_reverse_zone.py zona_ejemplo.com.txt ./zonas_inversas/")
        sys.exit(1)
    
    input_file = sys.argv[1]
    output_dir = sys.argv[2] if len(sys.argv) > 2 else "."
    
    # Extraer dominio del nombre del fichero
    origin_domain = input_file.replace('zona_', '').replace('.txt', '')
    
    print(f"[*] Leyendo fichero de zona: {input_file}")
    records, soa_record, ns_records = parse_zone_file(input_file)
    
    if not records:
        print("Error: No se encontraron registros A en el fichero")
        sys.exit(1)
    
    print(f"[+] Se encontraron {len(records)} registros A")
    
    # Agrupar por subred
    subnets = group_by_subnet(records)
    
    if not subnets:
        print("Error: No se pudieron procesar los registros")
        sys.exit(1)
    
    print(f"[+] Se identificaron {len(subnets)} subred(es)")
    
    # Generar ficheros de zona inversa
    print(f"\n[*] Generando ficheros de zona inversa...\n")
    
    for subnet, subnet_records in sorted(subnets.items()):
        reverse_zone_name, content = generate_reverse_zone(
            subnet, subnet_records, soa_record, ns_records, origin_domain
        )
        
        # Crear nombre del fichero
        output_filename = f"{output_dir}/db.{reverse_zone_name}"
        
        try:
            with open(output_filename, 'w') as f:
                f.write(content)
            print(f"[+] Creado: {output_filename}")
            print(f"    Subred: {subnet}")
            print(f"    Registros PTR: {len(subnet_records)}")
            print()
        except IOError as e:
            print(f"[-] Error al escribir {output_filename}: {e}")
    
    print("[*] Proceso completado")

if __name__ == "__main__":
    main()