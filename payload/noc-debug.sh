#!/bin/bash
# noc-pocket-probe - despejo de diagnostico na particao de boot
#
# Existe porque o Zero 2 W nao tem console utilizavel: sem mini-HDMI, sem
# adaptador serial e sem rede, a particao FAT32 de boot e o unico canal de
# saida que uma maquina Windows consegue ler. O arquivo e reescrito a cada
# boot, entao basta ligar o Pi, esperar, desligar e ler o cartao.
#
# Faz dois passes: um logo apos o boot e outro 90 s depois. O segundo existe
# porque associacao Wi-Fi e instalacao de pacotes chegam atrasadas, e um unico
# retrato tirado cedo demais mostraria a rede como ausente sem ela estar.

OUT=/boot/firmware/noc-debug.txt
: >"$OUT" 2>/dev/null || OUT=/boot/noc-debug.txt
: >"$OUT"

sec() {
  local t="$1"; shift
  {
    echo
    echo "===== $t ====="
    "$@" 2>&1 | head -c 20000
  } >>"$OUT"
}

passe() {
  {
    echo
    echo "##################################################"
    echo "########## PASSE $1 - $(date -Is)"
    echo "##################################################"
  } >>"$OUT"

  sec "uname"              uname -a
  sec "modelo"             cat /proc/device-tree/model
  sec "os-release"         cat /etc/os-release
  sec "uptime"             uptime

  # --- o que interessa para o gadget USB -------------------------------
  sec "modulos de gadget"  bash -c "lsmod | grep -Ei 'dwc2|g_ether|usb_f|libcomposite|udc' || echo '(NENHUM modulo de gadget carregado)'"
  sec "controlador UDC"    bash -c "ls -l /sys/class/udc/ 2>&1 || echo '(sem /sys/class/udc: o dwc2 nao esta em modo peripheral)'"
  sec "dmesg dwc2/usb"     bash -c "dmesg | grep -Ei 'dwc2|udc|gadget|g_ether|usb0' || echo '(nada sobre dwc2/gadget no dmesg)'"
  sec "cmdline efetivo"    cat /proc/cmdline
  sec "config.txt ativo"   bash -c "grep -n 'dwc2' /boot/firmware/config.txt 2>/dev/null || grep -n 'dwc2' /boot/config.txt 2>/dev/null"

  # --- rede --------------------------------------------------------------
  sec "interfaces"         ip -br addr
  sec "rotas"              ip route
  sec "nmcli devices"      nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status
  sec "nmcli conexoes"     nmcli -t -f NAME,TYPE,DEVICE connection show
  sec "wifi link"          iw dev wlan0 link
  sec "wifi: redes vistas" bash -c "iw dev wlan0 scan 2>/dev/null | grep -E 'SSID:|signal:' | head -60 || echo '(scan falhou ou wlan0 nao existe)'"
  sec "rfkill"             rfkill list
  sec "dns"                cat /etc/resolv.conf

  # --- por que a conexao nao sobe ----------------------------------------
  sec "perfis NM em /etc"  bash -c "ls -la /etc/NetworkManager/system-connections/ 2>&1"
  sec "perfis NM em /run"  bash -c "ls -la /run/NetworkManager/system-connections/ 2>&1"
  sec "conf.d do NM"       bash -c "ls -la /etc/NetworkManager/conf.d/ /run/NetworkManager/conf.d/ 2>&1; echo '--- conteudo ---'; cat /etc/NetworkManager/conf.d/*.conf /run/NetworkManager/conf.d/*.conf 2>/dev/null"
  sec "netplan"            bash -c "ls -la /etc/netplan/ 2>&1; echo '--- conteudo ---'; cat /etc/netplan/*.yaml 2>/dev/null"
  # a mensagem de erro do proprio NM vale mais que qualquer deducao nossa
  sec "tentativa de conexao" bash -c "nmcli -w 45 connection up noc-wifi1 2>&1 || nmcli -w 45 device wifi connect \"\$(nmcli -t -f SSID device wifi list | head -1)\" 2>&1"
  sec "estado apos tentar" bash -c "nmcli -t -f DEVICE,STATE,CONNECTION device status; ip -br addr show wlan0"
  sec "journal NetworkManager" bash -c "journalctl -u NetworkManager -b --no-pager -n 150 2>&1 | tail -c 15000"
  sec "journal wpa_supplicant" bash -c "journalctl -u wpa_supplicant -b --no-pager -n 80 2>&1 | tail -c 8000"

  # --- provisionamento ---------------------------------------------------
  sec "cloud-init status"  cloud-init status --long
  sec "cloud-init log"     tail -n 150 /var/log/cloud-init-output.log
  sec "setup do probe"     tail -n 80 /var/log/noc-probe-setup.log
  sec "carimbo de setup"   cat /var/lib/noc-probe/setup.done
  sec "usuarios"           bash -c "getent passwd | awk -F: '\$3>=1000 && \$3<65000'"
  sec "sshd"               systemctl is-active ssh
  sec "erros do boot"      journalctl -b -p err --no-pager -n 80

  sync
}

passe 1
sleep 90
passe 2

{
  echo
  echo "########## FIM - pode desligar o Pi e ler o cartao ##########"
} >>"$OUT"
sync
exit 0
