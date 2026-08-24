#!/bin/bash
# noc-diag - motor de diagnostico do noc-pocket-probe
#
# Roda uma cascata de testes da camada fisica ate a aplicacao e emite um
# VEREDITO: em qual camada a rede quebra. A tese do aparelho e simples --
# se o probe, plugado no mesmo ponto que o computador do usuario, passa em
# tudo, entao a rede esta boa e o problema e do computador.
#
# uso: noc-diag [--quick|--full] [--iface IF] [--json] [--report ARQ]
set -u

VERSION=1.1
MODE=normal
IFACE=""
JSON=0
REPORT=""
ANCHORS="1.1.1.1 8.8.8.8"
DNS_PROBE=cloudflare.com
CAPTIVE_URL=http://connectivitycheck.gstatic.com/generate_204

[ -r /etc/noc-probe/diag.conf ] && . /etc/noc-probe/diag.conf

while [ $# -gt 0 ]; do
  case "$1" in
    --quick)  MODE=quick ;;
    --full)   MODE=full ;;
    --iface)  IFACE="${2:-}"; shift ;;
    --json)   JSON=1 ;;
    --report) REPORT="${2:-}"; shift ;;
    -h|--help)
      sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "argumento desconhecido: $1" >&2; exit 2 ;;
  esac
  shift
done

# ------------------------------------------------------------------ saida
if [ -t 1 ] && [ "$JSON" = "0" ]; then
  B=$(tput bold 2>/dev/null); N=$(tput sgr0 2>/dev/null); D=$(tput dim 2>/dev/null)
  C_OK=$(tput setaf 2 2>/dev/null); C_WARN=$(tput setaf 3 2>/dev/null)
  C_FAIL=$(tput setaf 1 2>/dev/null); C_SKIP=$(tput setaf 8 2>/dev/null)
else
  B=""; N=""; D=""; C_OK=""; C_WARN=""; C_FAIL=""; C_SKIP=""
fi

RESULTS=""      # linhas "status<TAB>id<TAB>titulo<TAB>detalhe<TAB>dica"
declare -A ST   # ST[id]=status, consumido pelo motor de veredito
declare -A VAL  # VAL[id]=valor bruto

have() { command -v "$1" >/dev/null 2>&1; }

res() { # res STATUS ID TITULO DETALHE [DICA]
  local st="$1" id="$2" tt="$3" dt="${4:-}" hn="${5:-}"
  ST["$id"]="$st"
  RESULTS="${RESULTS}${st}"$'\t'"${id}"$'\t'"${tt}"$'\t'"${dt}"$'\t'"${hn}"$'\n'
  [ "$JSON" = "1" ] && return 0
  local mark col
  case "$st" in
    OK)   mark="ok "; col="$C_OK" ;;
    WARN) mark=" ! "; col="$C_WARN" ;;
    FAIL) mark=" X "; col="$C_FAIL" ;;
    *)    mark=" - "; col="$C_SKIP" ;;
  esac
  printf '  %s%s%s %-24s %s\n' "$col" "$mark" "$N" "$tt" "$dt"
  [ -n "$hn" ] && printf '      %s%s%s\n' "$D" "$hn" "$N"
  return 0
}

sec() { [ "$JSON" = "1" ] || printf '\n%s%s%s\n' "$B" "$1" "$N"; }

json_esc() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/ }"
  printf '%s' "$s"
}

# --------------------------------------------------------------- contexto
sec "contexto"
HOST=$(hostname)
UP=$(uptime -p 2>/dev/null | sed 's/^up //')
TEMP=$(vcgencmd measure_temp 2>/dev/null | cut -d= -f2)
res OK ctx.host "probe" "$HOST · up ${UP:-?} · ${TEMP:-temp n/d} · noc-diag v$VERSION"

# interface alvo: a da rota default, salvo se o usuario mandou outra
if [ -z "$IFACE" ]; then
  IFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
fi
if [ -z "$IFACE" ]; then
  IFACE=$(ip -br link show up 2>/dev/null | awk '$1!="lo"{print $1; exit}')
fi
if [ -z "$IFACE" ]; then
  res FAIL link.iface "interface" "nenhuma interface ativa" \
      "Nada esta up alem de lo. Wi-Fi bloqueado (rfkill) ou cabo fora."
  IFACE="-"
else
  res OK link.iface "interface em uso" "$IFACE"
fi

# ------------------------------------------------------------ camada 1/2
sec "camada 1-2 · enlace"
MTU=""
if [ "$IFACE" != "-" ]; then
  OPER=$(cat "/sys/class/net/$IFACE/operstate" 2>/dev/null)
  CARR=$(cat "/sys/class/net/$IFACE/carrier" 2>/dev/null)
  MAC=$(cat "/sys/class/net/$IFACE/address" 2>/dev/null)
  MTU=$(cat "/sys/class/net/$IFACE/mtu" 2>/dev/null)
  if [ "$CARR" = "1" ]; then
    res OK link.carrier "portadora" "$IFACE up · mac $MAC · mtu $MTU"
  else
    res FAIL link.carrier "portadora" "$IFACE sem link (operstate=${OPER:-?})" \
        "Cabo desconectado, porta do switch desligada ou Wi-Fi sem associacao."
  fi

  if have ethtool && [ -d "/sys/class/net/$IFACE/device" ]; then
    ETH=$(ethtool "$IFACE" 2>/dev/null)
    SPD=$(printf '%s\n' "$ETH" | awk -F': ' '/Speed:/{print $2; exit}')
    DUP=$(printf '%s\n' "$ETH" | awk -F': ' '/Duplex:/{print $2; exit}')
    if [ -n "$SPD" ]; then
      case "${SPD}${DUP}" in
        10Mb/s*|*Half)
          res WARN link.speed "velocidade/duplex" "$SPD $DUP" \
              "Negociacao ruim. Suspeite do cabo (par partido) ou porta forcada no switch." ;;
        *) res OK link.speed "velocidade/duplex" "$SPD $DUP" ;;
      esac
    fi
  fi

  RX_ERR=$(cat "/sys/class/net/$IFACE/statistics/rx_errors" 2>/dev/null || echo 0)
  TX_ERR=$(cat "/sys/class/net/$IFACE/statistics/tx_errors" 2>/dev/null || echo 0)
  RX_DRP=$(cat "/sys/class/net/$IFACE/statistics/rx_dropped" 2>/dev/null || echo 0)
  RX_PKT=$(cat "/sys/class/net/$IFACE/statistics/rx_packets" 2>/dev/null || echo 0)
  ERRS=$(( RX_ERR + TX_ERR ))
  # relevante = >= 0.1% dos quadros recebidos
  if [ "$ERRS" -gt 0 ] && [ $(( ERRS * 1000 / (RX_PKT + 1) )) -ge 1 ]; then
    res WARN link.errors "erros de quadro" "rx_err=$RX_ERR tx_err=$TX_ERR drop=$RX_DRP" \
        "Taxa de erro relevante: cabo/conector ou interferencia. Troque o patch cord."
  else
    res OK link.errors "erros de quadro" "rx_err=$RX_ERR tx_err=$TX_ERR drop=$RX_DRP"
  fi
fi

# ----------------------------------------------------------------- wi-fi
if [ -d "/sys/class/net/$IFACE/wireless" ]; then
  SSID=$(iwgetid -r 2>/dev/null)
  SIG=$(awk -v i="$IFACE:" '$1==i {sub(/\./,"",$4); print $4; exit}' /proc/net/wireless 2>/dev/null)
  if [ -z "$SSID" ]; then
    res FAIL wifi.assoc "associacao" "nao associado" \
        "Radio ligado mas sem AP. SSID errado, PSK errado ou fora de alcance."
  else
    WDET="ssid $SSID · sinal ${SIG:-?} dBm"
    if have iw; then
      WLINK=$(iw dev "$IFACE" link 2>/dev/null)
      RATE=$(printf '%s\n' "$WLINK" | awk '/rx bitrate/{print $3" "$4; exit}')
      FREQ=$(printf '%s\n' "$WLINK" | awk '/freq/{print $2; exit}')
      [ -n "$RATE" ] && WDET="$WDET · $RATE"
      [ -n "$FREQ" ] && WDET="$WDET · ${FREQ}MHz"
    fi
    if [ -n "$SIG" ] && [ "$SIG" -le -75 ] 2>/dev/null; then
      res WARN wifi.assoc "associacao" "$WDET" \
          "Sinal fraco (<= -75 dBm): perda e retransmissao sao esperadas neste ponto."
    else
      res OK wifi.assoc "associacao" "$WDET"
    fi
  fi
fi

# --------------------------------------------------------- camada 3 · ip
sec "camada 3 · endereco"
IP4=$(ip -4 -br addr show dev "$IFACE" scope global 2>/dev/null | awk '{print $3; exit}')
if [ -z "$IP4" ]; then
  APIPA=$(ip -4 -br addr show dev "$IFACE" 2>/dev/null | grep -o '169\.254\.[0-9.]*/[0-9]*' | head -1)
  if [ -n "$APIPA" ]; then
    res FAIL ip.addr "endereco IPv4" "APIPA $APIPA" \
        "O DHCP nao respondeu. Servidor fora, pool esgotado, VLAN errada ou porta sem servico."
  else
    res FAIL ip.addr "endereco IPv4" "sem endereco" \
        "Interface sem IP: DHCP mudo e sem fallback. Verifique a porta/VLAN do switch."
  fi
else
  res OK ip.addr "endereco IPv4" "$IP4"
  VAL[ip]="${IP4%%/*}"
fi

# IP duplicado na LAN - causa classica de "cai e volta sem padrao"
if [ -n "${VAL[ip]:-}" ] && have arping && [ "$MODE" != "quick" ]; then
  DUPOUT=$(timeout 8 arping -D -I "$IFACE" -c 2 "${VAL[ip]}" 2>&1)
  if printf '%s\n' "$DUPOUT" | grep -qiE 'reply from|conflict'; then
    res FAIL ip.dup "IP duplicado" "outro host responde por ${VAL[ip]}" \
        "Conflito de IP na LAN. Sintoma tipico: conexao intermitente sem padrao."
  else
    res OK ip.dup "IP duplicado" "nenhum conflito detectado"
  fi
fi

GW=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
if [ -z "$GW" ]; then
  res FAIL ip.gw "rota default" "ausente" \
      "Sem gateway: nada sai da LAN. Lease DHCP incompleta ou rota estatica faltando."
else
  GWMAC=$(ip neigh show "$GW" 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="lladdr") print $(i+1)}' | head -1)
  if timeout 6 ping -n -c 2 -W 1 -I "$IFACE" "$GW" >/dev/null 2>&1; then
    res OK ip.gw "gateway" "$GW responde${GWMAC:+ · $GWMAC}"
  else
    res FAIL ip.gw "gateway" "$GW nao responde" \
        "Tem IP mas nao alcanca o gateway: VLAN/port-security, isolamento de cliente ou ACL."
  fi
fi

# ------------------------------------------------------------------ mtu
if [ "$MODE" != "quick" ] && [ "${ST[ip.gw]:-}" = "OK" ]; then
  BEST=0
  for sz in 1472 1464 1442 1422 1372 1272; do
    if timeout 4 ping -n -c 1 -W 1 -M do -s "$sz" -I "$IFACE" "$GW" >/dev/null 2>&1; then
      BEST=$sz; break
    fi
  done
  if [ "$BEST" -eq 0 ]; then
    res WARN mtu.path "MTU ate o gateway" "nao determinada" \
        "ICMP com bit DF pode estar filtrado no caminho."
  else
    PMTU=$(( BEST + 28 ))
    if [ "$PMTU" -ge 1500 ]; then
      res OK mtu.path "MTU ate o gateway" "$PMTU"
    else
      res WARN mtu.path "MTU ate o gateway" "$PMTU (esperado 1500)" \
          "MTU reduzida: PPPoE (1492) ou tunel/VPN. Quebra HTTPS e SMB de forma seletiva."
    fi
  fi
fi

# ------------------------------------------------------- camada 3 · wan
sec "camada 3 · internet"
NET_OK=0
for a in $ANCHORS; do
  OUT=$(timeout 20 ping -n -c 5 -i 0.3 -W 2 "$a" 2>/dev/null)
  LOSS=$(printf '%s\n' "$OUT" | awk '/packet loss/{for(i=1;i<=NF;i++) if($i=="packet"){gsub(/%/,"",$(i-1)); print $(i-1); exit}}')
  RTT=$(printf '%s\n' "$OUT" | awk -F'/' '/^(rtt|round-trip)/{printf "%.0f", $5; exit}')
  JIT=$(printf '%s\n' "$OUT" | awk -F'/' '/^(rtt|round-trip)/{printf "%.0f", $7; exit}')
  LOSS=${LOSS:-100}; LOSS=${LOSS%%.*}
  if [ "$LOSS" -eq 0 ] 2>/dev/null; then
    NET_OK=1
    if [ -n "$RTT" ] && [ "$RTT" -gt 150 ] 2>/dev/null; then
      res WARN "wan.$a" "icmp $a" "0% perda · ${RTT}ms · jitter ${JIT}ms" \
          "Latencia alta para um anycast: link saturado ou rota ruim."
    elif [ -n "$JIT" ] && [ "$JIT" -gt 30 ] 2>/dev/null; then
      res WARN "wan.$a" "icmp $a" "0% perda · ${RTT}ms · jitter ${JIT}ms" \
          "Jitter alto: ruim para voz e video. Suspeite de saturacao do uplink."
    else
      res OK "wan.$a" "icmp $a" "0% perda · ${RTT}ms · jitter ${JIT}ms"
    fi
  elif [ "$LOSS" -ge 100 ] 2>/dev/null; then
    res FAIL "wan.$a" "icmp $a" "100% perda"
  else
    NET_OK=1
    res WARN "wan.$a" "icmp $a" "${LOSS}% perda · ${RTT}ms" \
        "Perda parcial no caminho - rode 'mtr -rwc 50 $a' para achar o hop culpado."
  fi
done
if [ "$NET_OK" = "1" ]; then ST[wan]=OK; else ST[wan]=FAIL; fi

# ----------------------------------------------------------------- dns
sec "camada 7 · dns"
NS_LIST=$(grep -h '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}')
if [ -z "$NS_LIST" ]; then
  res FAIL dns.conf "resolvers" "nenhum em /etc/resolv.conf" \
      "Sem DNS configurado - o DHCP entregou uma lease incompleta."
  ST[dns]=FAIL
else
  DNS_OK=0
  if have dig; then
    for ns in $NS_LIST; do
      T0=$(date +%s%N)
      ANS=$(timeout 6 dig +time=2 +tries=1 +short @"$ns" "$DNS_PROBE" A 2>/dev/null | head -1)
      T1=$(date +%s%N)
      MS=$(( (T1 - T0) / 1000000 ))
      if [ -n "$ANS" ]; then
        DNS_OK=1
        if [ "$MS" -gt 500 ]; then
          res WARN "dns.$ns" "resolver $ns" "$DNS_PROBE -> $ANS (${MS}ms)" \
              "Resolucao lenta: da a sensacao de 'internet travando' mesmo com link bom."
        else
          res OK "dns.$ns" "resolver $ns" "$DNS_PROBE -> $ANS (${MS}ms)"
        fi
      else
        res FAIL "dns.$ns" "resolver $ns" "sem resposta em 2s" \
            "Resolver mudo ou filtrado. Compare com 'dig @1.1.1.1' para separar DNS de conectividade."
      fi
    done
  else
    if timeout 6 getent hosts "$DNS_PROBE" >/dev/null 2>&1; then
      DNS_OK=1; res OK dns.sys "resolucao do sistema" "$DNS_PROBE resolve"
    else
      res FAIL dns.sys "resolucao do sistema" "falhou"
    fi
  fi
  if [ "$DNS_OK" = "1" ]; then ST[dns]=OK; else ST[dns]=FAIL; fi

  # sequestro de NXDOMAIN: dominio inexistente NAO pode devolver um A
  if have dig && [ "$MODE" != "quick" ]; then
    BOGUS="nxd-$$-probe.invalid"
    HJ=$(timeout 6 dig +time=2 +tries=1 +short "$BOGUS" A 2>/dev/null | head -1)
    if [ -n "$HJ" ]; then
      res WARN dns.hijack "sequestro de NXDOMAIN" "$BOGUS -> $HJ" \
          "O resolver inventa respostas. Quebra deteccao de portal e clientes que confiam em NXDOMAIN."
    else
      res OK dns.hijack "sequestro de NXDOMAIN" "NXDOMAIN honesto"
    fi
  fi
fi

# ------------------------------------------------- portal / http / relogio
sec "camada 7 · http, portal e relogio"
if have curl; then
  CODE=$(timeout 10 curl -sS -m 6 -o /dev/null -w '%{http_code}' "$CAPTIVE_URL" 2>/dev/null)
  case "$CODE" in
    204)     res OK   http.captive "portal cativo" "resposta 204 - saida limpa" ;;
    000|"")  res FAIL http.captive "portal cativo" "sem resposta HTTP" ;;
    *)       res WARN http.captive "portal cativo" "esperado 204, veio $CODE" \
                 "Ha portal cativo ou proxy interceptando. Autentique antes de culpar a rede."
             ST[captive]=PORTAL ;;
  esac

  HDR=$(timeout 15 curl -sSI -m 10 https://www.google.com 2>/dev/null)
  if [ -n "$HDR" ]; then
    res OK http.tls "https" "handshake ok com www.google.com"
    RDATE=$(printf '%s\n' "$HDR" | awk -F': ' 'tolower($1)=="date"{print $2; exit}' | tr -d '\r')
    if [ -n "$RDATE" ]; then
      RS=$(date -d "$RDATE" +%s 2>/dev/null)
      if [ -n "$RS" ]; then
        SKEW=$(( $(date +%s) - RS )); SKEW=${SKEW#-}
        if [ "$SKEW" -gt 300 ]; then
          res FAIL time.skew "relogio" "${SKEW}s de diferenca" \
              "Relogio errado quebra TLS, Kerberos e login de dominio. Causa numero 1 de 'certificado invalido'."
        else
          res OK time.skew "relogio" "${SKEW}s de diferenca"
        fi
      fi
    fi
  else
    res FAIL http.tls "https" "handshake falhou" \
        "Porta 443 bloqueada, inspecao TLS com CA propria, ou MTU quebrando o handshake."
  fi
else
  res SKIP http.captive "portal cativo" "curl ausente"
fi

# --------------------------------------------------------- saida de portas
if [ "$MODE" = "full" ] && have nc; then
  sec "egresso de portas"
  while read -r ehost eport ename; do
    [ -z "$ehost" ] && continue
    if timeout 8 nc -z -w 4 "$ehost" "$eport" >/dev/null 2>&1; then
      res OK "egress.$eport" "$ename ($ehost:$eport)" "aberto"
    else
      res WARN "egress.$eport" "$ename ($ehost:$eport)" "bloqueado" \
          "Firewall ou proxy filtra esta porta na saida."
    fi
  done <<'EGRESS'
1.1.1.1 53 dns
1.1.1.1 443 https
8.8.8.8 853 dns-over-tls
github.com 22 ssh
smtp.gmail.com 587 smtp
EGRESS
fi

# ------------------------------------------------------------- vizinhanca
if [ "$MODE" = "full" ]; then
  sec "vizinhanca e capacidade"
  if have lldpctl; then
    SW=$(lldpctl -f keyvalue 2>/dev/null | grep -E '\.(chassis\.name|port\.descr|vlan\.vlan-id)=' | head -6 | tr '\n' ' ')
    if [ -n "$SW" ]; then
      res OK lan.lldp "switch (LLDP)" "$SW" \
          "Isso identifica switch e porta exatos onde o probe esta plugado."
    else
      res SKIP lan.lldp "switch (LLDP)" "nenhum anuncio recebido" \
          "LLDP desligado no switch, ou porta access sem lldp-med."
    fi
  fi
  if have arp-scan && [ -n "${VAL[ip]:-}" ]; then
    HOSTS=$(timeout 60 arp-scan -q -l -I "$IFACE" 2>/dev/null | grep -cE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
    res OK lan.hosts "hosts na LAN" "${HOSTS:-0} respondendo a ARP" \
        "Zero hosts numa rede corporativa = isolamento de cliente ou VLAN vazia."
  fi
  if have speedtest-cli; then
    SPT=$(timeout 180 speedtest-cli --simple 2>/dev/null | tr '\n' ' ')
    [ -n "$SPT" ] && res OK wan.speed "banda" "$SPT"
  fi
  if [ -n "${IPERF_SERVER:-}" ] && have iperf3; then
    IP3=$(timeout 90 iperf3 -c "$IPERF_SERVER" -t 10 -f m 2>/dev/null | awk '/receiver/{print $7" "$8; exit}')
    [ -n "$IP3" ] && res OK wan.iperf "iperf3 -> $IPERF_SERVER" "$IP3"
  fi
fi

# ------------------------------------------------------------------ veredito
# Cascata: a primeira camada que quebra e a culpada; as de baixo ja passaram.
verdict() {
  if [ "${ST[link.carrier]:-OK}" = "FAIL" ] || [ "${ST[link.iface]:-OK}" = "FAIL" ]; then
    echo "CAMADA 1 - SEM ENLACE|O probe nao tem portadora em $IFACE. O problema esta antes de qualquer configuracao: cabo, conector, porta do switch desligada ou Wi-Fi sem associacao. Se o computador do usuario tambem nao linka nesta mesma tomada, a tomada e a culpada."
    return
  fi
  if [ "${ST[ip.addr]:-OK}" = "FAIL" ]; then
    echo "CAMADA 3 - DHCP NAO ENTREGA|Ha enlace mas o probe nao recebeu IP. Servidor DHCP fora do ar, pool esgotado, porta na VLAN errada ou DHCP snooping bloqueando. Um computador nesta porta mostraria 'sem internet' com endereco 169.254.x.x."
    return
  fi
  if [ "${ST[ip.dup]:-OK}" = "FAIL" ]; then
    echo "CAMADA 3 - IP DUPLICADO|Outro host na LAN responde pelo mesmo IP. Sintoma classico de queda intermitente sem padrao aparente. Procure reserva DHCP conflitando com um IP estatico."
    return
  fi
  if [ "${ST[ip.gw]:-OK}" = "FAIL" ]; then
    echo "CAMADA 2/3 - GATEWAY INALCANCAVEL|O probe tem IP valido mas nao fala com o gateway. Aponta para VLAN incorreta, port-security, isolamento de cliente no AP ou ACL no proprio gateway. Nao e problema do computador."
    return
  fi
  if [ "${ST[captive]:-}" = "PORTAL" ]; then
    echo "CAMADA 7 - PORTAL CATIVO|A rede intercepta HTTP e exige autenticacao. Tudo abaixo esta saudavel. O computador so navega depois que o portal for aceito."
    return
  fi
  if [ "${ST[wan]:-OK}" = "FAIL" ] && [ "${ST[http.captive]:-}" = "OK" ]; then
    echo "OK COM RESSALVA - ICMP FILTRADO|Ping para a internet falha mas HTTP sai normalmente. Isso e politica de firewall, nao falha. Nao use ping como criterio nesta rede."
    return
  fi
  if [ "${ST[wan]:-OK}" = "FAIL" ]; then
    echo "CAMADA 3 - UPLINK OU ISP|O gateway responde mas nada passa dele para fora. O defeito esta no roteador de borda ou no link do provedor. Confirme com 'mtr -rwc 50 1.1.1.1': o ultimo hop que responde marca a fronteira do problema."
    return
  fi
  if [ "${ST[dns]:-OK}" = "FAIL" ]; then
    echo "CAMADA 7 - DNS|A internet esta acessivel por IP mas a resolucao de nomes falha. Resolver fora do ar ou filtrado. No computador isso aparece como 'sem internet' no navegador enquanto o ping por IP funciona."
    return
  fi
  if [ "${ST[time.skew]:-OK}" = "FAIL" ]; then
    echo "APLICACAO - RELOGIO FORA|A rede esta boa, mas o relogio esta muito defasado. Isso quebra TLS, Kerberos e autenticacao de dominio, e quase sempre e lido como 'problema de rede'."
    return
  fi
  local warns
  warns=$(printf '%s' "$RESULTS" | awk -F'\t' '$1=="WARN"{print $3}' | paste -sd '; ' -)
  if [ -n "$warns" ]; then
    echo "REDE FUNCIONAL COM DEGRADACAO|Toda a cascata passa, mas com ressalvas: ${warns}. Se o computador do usuario falha aqui, comece pela degradacao acima; se ela nao explica o sintoma, o defeito e do computador."
    return
  fi
  echo "REDE SAUDAVEL - SUSPEITE DO COMPUTADOR|Da camada fisica ate DNS e HTTPS, tudo passou nesta mesma tomada. A rede nao e a causa. Investigue no computador: driver ou adaptador, proxy configurado, VPN presa, firewall local, antivirus interceptando TLS, ou DNS fixado manualmente."
}

V=$(verdict)
V_TITLE="${V%%|*}"
V_BODY="${V#*|}"

emit_json() {
  printf '{\n  "version": "%s",\n  "host": "%s",\n  "iface": "%s",\n  "mode": "%s",\n  "timestamp": "%s",\n' \
    "$VERSION" "$(json_esc "$HOST")" "$(json_esc "$IFACE")" "$MODE" "$(date -Is)"
  printf '  "verdict": { "title": "%s", "body": "%s" },\n  "checks": [\n' \
    "$(json_esc "$V_TITLE")" "$(json_esc "$V_BODY")"
  local first=1 st id tt dt hn
  while IFS=$'\t' read -r st id tt dt hn; do
    [ -z "${id:-}" ] && continue
    [ "$first" -eq 0 ] && printf ',\n'
    first=0
    printf '    { "status": "%s", "id": "%s", "title": "%s", "detail": "%s", "hint": "%s" }' \
      "$st" "$(json_esc "$id")" "$(json_esc "$tt")" "$(json_esc "$dt")" "$(json_esc "${hn:-}")"
  done <<< "$RESULTS"
  printf '\n  ]\n}\n'
}

if [ "$JSON" = "1" ]; then
  emit_json
else
  case "$V_TITLE" in
    "REDE SAUDAVEL"*|OK*)   VC="$C_OK" ;;
    "REDE FUNCIONAL"*)      VC="$C_WARN" ;;
    *)                      VC="$C_FAIL" ;;
  esac
  printf '\n%s%s== VEREDITO: %s ==%s\n' "$B" "$VC" "$V_TITLE" "$N"
  printf '%s\n' "$V_BODY" | fold -s -w 76 | sed 's/^/  /'
  printf '\n'
fi

if [ -n "$REPORT" ]; then
  emit_json > "$REPORT"
  [ "$JSON" = "1" ] || echo "relatorio json: $REPORT"
fi

case "$V_TITLE" in
  "REDE SAUDAVEL"*|OK*) exit 0 ;;
  "REDE FUNCIONAL"*)    exit 1 ;;
  *)                    exit 2 ;;
esac
