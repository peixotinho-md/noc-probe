#!/bin/bash
# noc-pocket-probe - diagnostico independente do cloud-init
#
# Roda via systemd.run + systemd.unit=kernel-command-line.target, o mesmo
# mecanismo que o Raspberry Pi Imager usava para o firstrun.sh -- portanto
# comprovadamente funcional nesta imagem. Nao depende do cloud-init ter
# rodado, nem de rede, nem de console.
#
# Esse alvo minimo sobe o sistema de arquivos local mas NAO sobe rede nem
# servicos. Logo, o que ele mede sobre Wi-Fi e o estado *em repouso*: quais
# perfis existem, o que o boot anterior registrou. O que ele mede sobre o
# gadget USB e definitivo, porque dwc2 e g_ether sao carregados pelo kernel
# via modules-load, antes de qualquer servico.
#
# Ao terminar, restaura o cmdline.txt normal e desliga a placa.

FW=/boot/firmware
[ -d "$FW" ] || FW=/boot
OUT="$FW/noc-debug2.txt"

: >"$OUT"

sec() {
  local t="$1"; shift
  {
    echo
    echo "===== $t ====="
    "$@" 2>&1 | head -c 20000
  } >>"$OUT"
}

{
  echo "noc-pocket-probe - diagnostico standalone"
  echo "gerado em: $(date -Is)"
  echo "particao de boot montada em: $FW"
} >>"$OUT"

# --- a pergunta numero 1: o cloud-init existe nesta imagem? -------------
sec "cloud-init instalado?" bash -c "command -v cloud-init && cloud-init --version || echo 'NAO INSTALADO - o cloud-init nao existe nesta imagem'"
sec "pacote cloud-init"     bash -c "dpkg -l cloud-init 2>/dev/null | tail -n 3 || echo '(dpkg nao encontrou o pacote)'"
sec "instancias do cloud-init" bash -c "ls -la /var/lib/cloud/instances/ 2>&1; echo '--- seed ---'; ls -la /var/lib/cloud/seed/ 2>&1"
sec "instance-id efetivo"   bash -c "cat /var/lib/cloud/data/instance-id 2>&1; echo '--- previous ---'; cat /var/lib/cloud/data/previous-instance-id 2>&1"
sec "cloud-init.log (fim)"  bash -c "tail -n 200 /var/log/cloud-init.log 2>&1"
sec "cloud-init-output.log" bash -c "tail -n 120 /var/log/cloud-init-output.log 2>&1"

# --- a pergunta numero 2: o gadget USB carregou? ------------------------
sec "cmdline efetivo"       cat /proc/cmdline
sec "modulos carregados"    bash -c "lsmod | grep -Ei 'dwc2|g_ether|usb_f|libcomposite|udc' || echo 'NENHUM modulo de gadget carregado'"
sec "controlador UDC"       bash -c "ls -l /sys/class/udc/ 2>&1 | sed 's/^/  /'; [ -d /sys/class/udc ] && [ -n \"\$(ls -A /sys/class/udc 2>/dev/null)\" ] && echo 'UDC PRESENTE: o Pi esta em modo peripheral' || echo 'SEM UDC: dwc2 nao entrou em modo peripheral'"
sec "dmesg dwc2"            bash -c "dmesg | grep -Ei 'dwc2|udc|gadget|g_ether|usb0|3f980000' || echo '(nada sobre dwc2 no dmesg)'"
sec "modulo g_ether existe" bash -c "modinfo g_ether 2>&1 | head -n 5"
sec "carregar g_ether agora" bash -c "modprobe dwc2 2>&1; modprobe g_ether 2>&1; sleep 2; lsmod | grep -Ei 'dwc2|g_ether' || echo 'falhou ao carregar sob demanda'"
sec "interfaces apos modprobe" ip -br link

# --- a pergunta numero 3: o provisionamento chegou a acontecer? ---------
sec "usuarios reais"        bash -c "getent passwd | awk -F: '\$3>=1000 && \$3<65000' || true"
sec "arquivos que gravamos" bash -c "ls -la /usr/local/bin/noc-diag /usr/local/bin/probe-status /usr/local/sbin/noc-probe-setup.sh /usr/local/sbin/noc-debug.sh 2>&1"
sec "perfis NetworkManager" bash -c "ls -la /etc/NetworkManager/system-connections/ 2>&1"
sec "netplan"               bash -c "ls -la /etc/netplan/ 2>&1; echo '--- conteudo ---'; cat /etc/netplan/*.yaml 2>/dev/null"
sec "wpa_supplicant"        bash -c "ls -la /etc/wpa_supplicant/ 2>&1"
sec "servicos que criamos"  bash -c "ls -la /etc/systemd/system/noc-*.service 2>&1"
sec "ssh habilitado?"       bash -c "systemctl is-enabled ssh 2>&1; ls -la /etc/ssh/sshd_config 2>&1"
sec "log do setup"          bash -c "tail -n 80 /var/log/noc-probe-setup.log 2>&1"
sec "boot anterior: erros"  bash -c "journalctl -b -1 -p err --no-pager -n 100 2>&1 | head -c 15000"

# --- contexto ------------------------------------------------------------
sec "modelo"                cat /proc/device-tree/model
sec "os-release"            cat /etc/os-release
sec "espaco em disco"       df -h

# --- restaura o boot normal ---------------------------------------------
if [ -f "$FW/cmdline.txt.noc-normal" ]; then
  cp "$FW/cmdline.txt.noc-normal" "$FW/cmdline.txt"
  echo "" >>"$OUT"
  echo "===== cmdline.txt restaurado para o boot normal =====" >>"$OUT"
else
  echo "" >>"$OUT"
  echo "===== ATENCAO: cmdline.txt.noc-normal ausente, cmdline NAO restaurado =====" >>"$OUT"
fi

echo "" >>"$OUT"
echo "########## FIM - a placa vai desligar sozinha ##########" >>"$OUT"
sync
sleep 2
sync
exit 0
