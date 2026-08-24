#!/bin/bash
# noc-share - transforma o probe em placa de rede para o computador ligado na USB
#
# Por padrao o probe e NEUTRO: o dnsmasq entrega um endereco ao computador mas
# nao anuncia gateway nem DNS (dhcp-option=3 e 6 vazios). Isso e proposital --
# o probe e plugado numa maquina que ja tem rede propria, e roubar a rota
# padrao dela estragaria justamente o diagnostico que se foi fazer.
#
# Com 'noc-share on' o comportamento se inverte: o probe passa a anunciar-se
# como gateway e servidor DNS, liga o encaminhamento e faz NAT da usb0 para o
# uplink (normalmente wlan0). O computador passa a navegar pela rede do probe.
#
# O valor disso para NOC e o teste inverso do noc-diag: se a maquina funciona
# pela rede do probe mas nao pela tomada dela, o defeito esta na tomada, no
# cabo ou na porta do switch -- nao na maquina.

set -u

FLAG=/var/lib/noc-probe/share.enabled
CONF=/etc/dnsmasq.d/noc-usb0.conf
LAN=usb0
SELF=10.55.0.1
NET=10.55.0.0/29
POOL=10.55.0.2,10.55.0.6,255.255.255.248,12h

if [ "$(id -u)" -ne 0 ]; then exec sudo "$0" "$@"; fi

uplink() {
  # a interface que hoje carrega a rota padrao; nao chuta wlan0 a toa
  ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'
}

conf_neutro() {
  cat >"$CONF" <<EOF
# NEUTRO: entrega endereco, nao anuncia gateway nem DNS.
port=0
interface=$LAN
bind-dynamic
except-interface=lo
dhcp-range=$POOL
dhcp-option=3
dhcp-option=6
EOF
}

conf_share() {
  cat >"$CONF" <<EOF
# COMPARTILHANDO: o probe se anuncia como gateway e como DNS.
interface=$LAN
bind-dynamic
except-interface=lo
dhcp-range=$POOL
dhcp-option=3,$SELF
dhcp-option=6,$SELF
EOF
}

# Tabela nft propria: criar e destruir a tabela inteira nao encosta em nenhuma
# regra de terceiros, e o 'off' fica trivial e sem residuo.
nat_on() {
  local up="$1"
  sysctl -qw net.ipv4.ip_forward=1
  nft delete table ip noc 2>/dev/null
  nft add table ip noc || return 1
  nft add chain ip noc post '{ type nat hook postrouting priority 100 ; }' || return 1
  nft add rule ip noc post ip saddr "$NET" oifname "$up" masquerade || return 1
}

nat_off() {
  nft delete table ip noc 2>/dev/null
  sysctl -qw net.ipv4.ip_forward=0
}

ligar() {
  local up
  up="$(uplink)"
  if [ -z "$up" ]; then
    echo "ERRO: o probe nao tem rota padrao - nao ha rede para compartilhar."
    echo "      conecte-o primeiro:  noc-wifi --list"
    return 1
  fi
  if [ "$up" = "$LAN" ]; then
    echo "ERRO: a rota padrao ja sai pela $LAN. Nao da para compartilhar consigo mesmo."
    return 1
  fi
  command -v nft >/dev/null 2>&1 || { echo "ERRO: nftables nao instalado."; return 1; }

  conf_share
  if ! systemctl restart dnsmasq; then
    echo "ERRO: dnsmasq nao subiu. Motivo, direto do journal:"
    journalctl -u dnsmasq -n 12 --no-pager 2>/dev/null | sed 's/^/  /'
    echo
    echo "  Voltando ao modo neutro para nao deixar o probe num estado quebrado."
    conf_neutro
    systemctl restart dnsmasq 2>/dev/null
    return 1
  fi
  nat_on "$up" || { echo "ERRO: nao consegui montar o NAT"; return 1; }

  mkdir -p "$(dirname "$FLAG")"
  printf '%s\n' "$up" >"$FLAG"

  echo "compartilhamento LIGADO  ($LAN  ->  $up)"
  echo
  echo "No computador ligado pelo cabo, renove o endereco para receber o"
  echo "gateway novo. No Windows:   ipconfig /release && ipconfig /renew"
  echo "Se ele estiver com IP fixo, use 10.55.0.2/255.255.255.248,"
  echo "gateway $SELF, DNS $SELF."
}

desligar() {
  conf_neutro
  systemctl restart dnsmasq 2>/dev/null
  nat_off
  rm -f "$FLAG"
  echo "compartilhamento DESLIGADO - o probe voltou a ser neutro."
  echo "No computador:  ipconfig /release && ipconfig /renew"
}

# chamado pelo systemd no boot: reaplica o estado anterior, sem falar nada
aplicar() {
  if [ -f "$FLAG" ]; then ligar >/dev/null 2>&1 || exit 0
  else conf_neutro; fi
  exit 0
}

estado() {
  local up fwd
  up="$(uplink)"
  fwd="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)"
  if [ -f "$FLAG" ]; then echo "modo            : COMPARTILHANDO"; else echo "modo            : neutro (padrao)"; fi
  echo "uplink atual    : ${up:-nenhum}"
  echo "ip_forward      : ${fwd:-?}"
  if nft list table ip noc >/dev/null 2>&1; then echo "NAT             : ativo"; else echo "NAT             : inativo"; fi
  echo "dnsmasq         : $(systemctl is-active dnsmasq 2>/dev/null)"
  echo "$LAN            : $(ip -br addr show "$LAN" 2>/dev/null | tr -s ' ' || echo 'ausente')"
  echo
  echo "anunciado por DHCP ao computador:"
  grep -E '^dhcp-option=(3|6)' "$CONF" 2>/dev/null | sed 's/^/  /' \
    || echo "  (arquivo $CONF ausente)"
}

case "${1:-status}" in
  on|ligar)      ligar ;;
  off|desligar)  desligar ;;
  apply)         aplicar ;;
  status|estado) estado ;;
  *)
    echo "uso: noc-share on       compartilha a rede do probe com o computador"
    echo "     noc-share off      volta ao modo neutro (padrao)"
    echo "     noc-share status   mostra o estado atual"
    exit 2
    ;;
esac
