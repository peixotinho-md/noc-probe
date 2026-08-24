#!/bin/bash
# Resumo de onde o probe esta plugado e como alcanca-lo.
b=$(tput bold 2>/dev/null); n=$(tput sgr0 2>/dev/null)
echo "${b}$(hostname) — noc-pocket-probe${n}   (mDNS: $(hostname).local)"
echo "uptime:$(uptime -p | sed 's/^up//')   temp: $(vcgencmd measure_temp 2>/dev/null | cut -d= -f2)   carga:$(cut -d' ' -f1-3 /proc/loadavg | sed 's/^/ /')"

echo "${b}interfaces${n}"
ip -br -4 addr show scope global | sed 's/^/  /'
ip -br -4 addr show scope link 2>/dev/null | grep -v '^lo' | sed 's/^/  /'

gw=$(ip route show default | awk '{print $3; exit}')
if [ -n "$gw" ]; then
  echo "${b}rota${n}"
  echo "  gateway: $gw  ($(ip route show default | awk '{print $5; exit}'))"
  echo "  dns:     $(grep -h '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')"
fi

if command -v iwgetid >/dev/null 2>&1 && iwgetid -r >/dev/null 2>&1; then
  ssid=$(iwgetid -r)
  if [ -n "$ssid" ]; then
    sig=$(awk 'NR==3 {print $4}' /proc/net/wireless 2>/dev/null)
    echo "${b}wi-fi${n}"
    echo "  ssid: $ssid   sinal: ${sig:-?} dBm"
  fi
fi

if [ ! -f /var/lib/noc-probe/setup.done ]; then
  echo "  ${b}!${n} setup de pacotes ainda pendente (ver /var/log/noc-probe-setup.log)"
elif command -v noc-diag >/dev/null 2>&1; then
  echo "${b}diagnostico${n}"
  echo "  noc-diag           cascata completa ate o veredito"
  echo "  noc-diag --quick   so o essencial, ~10s"
  echo "  noc-diag --full    inclui banda, LLDP e varredura da LAN"
fi
