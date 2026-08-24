# noc-pocket-probe

Um Raspberry Pi Zero 2 W que cabe no bolso, se pluga na USB do computador do
usuário e responde a pergunta que o NOC faz dez vezes por dia:

> **o problema é da rede ou é da máquina dele?**

O probe é plugado *no mesmo ponto* que o computador com defeito. Ele roda uma
cascata de testes da camada física até a aplicação e emite um veredito. Se o
probe passa em tudo naquela tomada, a rede está boa e o defeito é do
computador — e isso encerra a discussão em trinta segundos, não em uma hora.

---

## Como funciona

O Zero 2 W se apresenta ao computador como **placa de rede USB** (gadget
`g_ether`). Não precisa de driver e não precisa de Wi-Fi. O probe fica sempre
em `10.55.0.1`.

Ele entrega DHCP ao computador **sem anunciar gateway nem DNS**
(`dhcp-option=3` e `6` vazios), então plugar o probe nunca sequestra a rota do
usuário. O notebook continua saindo pela rede dele; o probe é só mais um
vizinho no cabo.

```
[ notebook ] --USB--> [ probe 10.55.0.1 ]
      |                       |
      +------ mesma tomada ---+---> [ switch ] --> [ gateway ] --> internet
```

Sem cabo USB também funciona: o probe entra pelo Wi-Fi configurado e você o
alcança pelo IP que ele receber, ou por `noc-probe.local` se o mDNS atravessar
o segmento.

### Modo placa de rede (`noc-share`)

O oposto do modo neutro, e opcional. Com `noc-share on` o probe passa a se
anunciar como gateway e DNS, liga o `ip_forward` e faz NAT da `usb0` para o
uplink. O computador passa a navegar pela rede do probe.

Isso é o **teste inverso** do `noc-diag`: se a máquina funciona pela rede do
probe mas não pela tomada dela, o defeito está na tomada, no cabo ou na porta
do switch — não na máquina. Os dois juntos fecham o diagnóstico pelos dois
lados.

```bash
noc-share status   # modo atual, uplink, NAT, o que está sendo anunciado
noc-share on       # compartilha
noc-share off      # volta ao neutro (padrão)
```

O estado sobrevive a reboots (`/var/lib/noc-probe/share.enabled` +
`noc-share.service`). O NAT vive numa tabela `nft` própria chamada `noc`, então
desligar é `nft delete table ip noc` — some tudo de uma vez, sem resíduo e sem
encostar em regra de terceiros. O uplink não é chutado como `wlan0`: o script
lê qual interface carrega a rota padrão no momento.

Depois de ligar ou desligar, o computador precisa renovar o DHCP
(`ipconfig /release && ipconfig /renew`) para pegar o gateway novo.

---

## O veredito

`noc-diag` percorre a cascata e para no **primeiro** ponto que quebra — as
camadas abaixo dele já passaram, então a culpa está ali.

| Veredito | O que significa |
|---|---|
| `CAMADA 1 - SEM ENLACE` | Sem portadora. Cabo, conector ou porta do switch. |
| `CAMADA 3 - DHCP NAO ENTREGA` | Tem link, não tem IP. Servidor, pool, VLAN ou DHCP snooping. |
| `CAMADA 3 - IP DUPLICADO` | Outro host responde pelo mesmo IP. Causa clássica de queda intermitente. |
| `CAMADA 2/3 - GATEWAY INALCANCAVEL` | Tem IP, não fala com o gateway. VLAN, port-security, isolamento de cliente. |
| `CAMADA 7 - PORTAL CATIVO` | A rede intercepta HTTP e pede autenticação. |
| `OK COM RESSALVA - ICMP FILTRADO` | Ping falha mas HTTP sai. É política de firewall, não defeito. |
| `CAMADA 3 - UPLINK OU ISP` | Gateway responde, nada passa dele. Roteador de borda ou provedor. |
| `CAMADA 7 - DNS` | Internet por IP funciona, nome não resolve. |
| `APLICACAO - RELOGIO FORA` | Relógio defasado quebra TLS e Kerberos, e todo mundo lê como "rede". |
| `REDE FUNCIONAL COM DEGRADACAO` | Tudo passa, mas com ressalvas (perda, jitter, MTU, sinal). |
| `REDE SAUDAVEL - SUSPEITE DO COMPUTADOR` | A rede não é a causa. O defeito é da máquina. |

Código de saída: `0` saudável, `1` degradado, `2` falha — dá para encadear em
script ou monitoramento.

### Uso

```bash
noc-diag                     # cascata completa, ~40s
noc-diag --quick             # só o essencial, ~10s
noc-diag --full              # + banda, LLDP, varredura da LAN, egresso de portas
noc-diag --json              # saída estruturada
noc-diag --report /tmp/r.json
noc-diag --iface eth0        # força uma interface
```

Ajustes em `/etc/noc-probe/diag.conf` (âncoras de ping, URL de portal cativo,
servidor iperf3 interno).

### O que ele mede

Enlace (portadora, velocidade/duplex, erros de quadro), Wi-Fi (SSID, sinal,
taxa, canal), endereço (APIPA, IP duplicado por ARP, gateway), **MTU do
caminho** por sondagem com bit DF, internet (perda e jitter em duas âncoras),
DNS (latência por resolver e detecção de **sequestro de NXDOMAIN**), portal
cativo, handshake TLS, **desvio de relógio** contra o header `Date`, egresso
de portas, LLDP e banda.

### Limitação de hardware: LLDP precisa de Ethernet

A checagem de LLDP identifica switch e porta exatos, e é a resposta mais
valiosa que um probe dá. Mas **o Zero 2 W não tem porta Ethernet** — é só
Wi-Fi, e ponto de acesso não anuncia LLDP para cliente wireless. Do jeito que
o aparelho está, essa checagem sempre retorna `SKIP`.

Isso afeta a premissa de plugar o probe na mesma tomada do computador: sem
porta de rede, ele não pluga em tomada nenhuma. Resolver exige um adaptador
OTG micro-USB mais um dongle USB-Ethernet. O custo é que a porta USB fica
ocupada e some o acesso pelo cabo — mas as duas coisas se complementam:
gerência pelo Wi-Fi, teste pela Ethernet.

---

## Ferramentas embarcadas

Além do `noc-diag`, o cartão traz o arsenal cru para quando o veredito diz
onde olhar mas você precisa cavar:

`mtr` `traceroute` `tracepath` `fping` `ndisc6` · `ethtool` `arping` `iw`
`arp-scan` `nmap` `lldpd` `avahi-utils` · `dig` `nslookup` · `tcpdump` ·
`iperf3` `speedtest-cli` `iftop` `nload` · `nc` `socat` `curl` `wget`
`openssl` `whois` · `snmpwalk` · `picocom` · `jq` `tmux` `htop` `chrony` ·
`nftables`

Com um adaptador USB-serial o probe também vira **console de switch/roteador**
via `picocom` — útil quando o equipamento perdeu a gerência pela rede.

Edite `PACKAGES` no `config.env` para cortar o que não usar. Só 8 pacotes são
exigidos pelo `noc-diag`; sem os outros os testes correspondentes viram `SKIP`
em vez de quebrar.

---

## Montando o cartão

Precisa de: Raspberry Pi Imager, um cartão microSD e Git for Windows (o script
usa o `openssl.exe` que vem com ele). Opcionalmente Python com PyYAML, que
habilita a validação do YAML gerado.

1. **Imager** → *Raspberry Pi OS (other)* → *Raspberry Pi OS Lite (64-bit)* →
   grave o cartão.

   A customização do Imager pode ser usada ou não — o que este script gera
   **substitui** o `user-data` dela por completo. Se você não preencher
   `PASSWORD` no `config.env`, ele até reaproveita o usuário e o hash que o
   Imager gravou, em vez de produzir um cartão sem login possível.

   Cartão: microSD 16 GB **A1 ou melhor**. Cartão ruim é a causa nº 1 de probe
   que trava sozinho.
2. O Imager ejeta o cartão ao terminar — remova e reinsira para o Windows
   montar a partição FAT32 (`bootfs`). A raiz é ext4 e o Windows não enxerga;
   tudo que o gerador escreve vai na FAT32.
3. Configure:
   ```powershell
   copy config.example.env config.env
   notepad config.env          # hostname, senha, Wi-Fi, fuso
   ```
4. Grave:
   ```powershell
   .\Write-ProbeCard.ps1 -DryRun        # renderiza em out\ para conferir
   .\Write-ProbeCard.ps1 -BootDrive D:
   ```
5. Ejete, ponha no Pi, ligue.

### Alimentação

**Alimente pela porta `PWR`, com carregador.** A porta USB de um PC pode não
sustentar o pico de corrente da inicialização: o LED acende fixo e a placa
nunca boota, o que se parece exatamente com cartão corrompido. Foi o primeiro
sintoma que tivemos, e custou tempo até ser identificado.

O LED verde segue a atividade do cartão SD. Piscar irregular é boot ou
trabalho de disco; estático é repouso. **Cuidado ao interpretar:** durante o
download do `apt` o gargalo é a rede, não o cartão, e o LED fica estático por
minutos sem que nada esteja travado.

### O que o gerador escreve

| Arquivo | Papel |
|---|---|
| `user-data` | cloud-config: hostname, fuso, usuário, e todos os scripts embutidos via `write_files` |
| `network-config` | Wi-Fi em formato netplan (mantido, mas **não** é o caminho principal — veja abaixo) |
| `meta-data` | `instance-id`, que sozinho **não** força reprovisionamento |
| `cmdline.txt` | `modules-load=dwc2,g_ether` e o `i=` do `ds=nocloud` sincronizado (backup em `cmdline.txt.noc-bak`) |
| `config.txt` | acrescenta `dtoverlay=dwc2,dr_mode=peripheral` na seção `[all]` |
| `ssh` | arquivo vazio que habilita o sshd |

### Wi-Fi: keyfile do NetworkManager, não netplan

O caminho netplan → NetworkManager se mostrou pouco confiável nesta imagem. Ela
referencia um módulo `cc_netplan_nm_patch` que o cloud-init instalado não
possui — o aviso aparece em todo boot — e o netplan ainda reescreve SSID
não-ASCII como lista de bytes decimais. Na prática a conexão Wi-Fi ora existia,
ora sumia entre boots.

O gerador passou a escrever um **keyfile do NetworkManager direto** em
`/etc/NetworkManager/system-connections/noc-wifiN.nmconnection`, com o SSID em
UTF-8 literal. Não depende do netplan nem do módulo ausente. O `network-config`
continua sendo gerado, mas é o caminho secundário.

Junto vão dois arquivos em `/etc/NetworkManager/conf.d/` marcando `wlan0` e
`usb0` como `managed=1`. Sem isso o `usb0` nasce **`unmanaged`** e o perfil
nunca é aplicado: quando o netplan é o renderizador, ele restringe o
NetworkManager aos dispositivos que o próprio netplan declara.

### Provisionamento: cloud-init, não `firstrun.sh`

As imagens de Raspberry Pi OS a partir de 2025 provisionam por **cloud-init**
(`ds=nocloud` no `cmdline.txt`), e não mais pelo `firstrun.sh` + `systemd.run`
da era Bookworm. O gerador confere o `ds=nocloud` e avisa se o cartão for de
uma imagem antiga.

A instalação dos pacotes **não** usa o `packages:` do cloud-init, que é tiro
único: se o probe nascer sem internet, ele falha e nunca mais tenta. Em vez
disso o `user-data` grava um `noc-probe-setup.service` que só cria o carimbo
`/var/lib/noc-probe/setup.done` no sucesso. Sem rede, ele sai com erro e o
systemd repete no boot seguinte — indefinidamente, até conseguir.

| Fase | O que acontece | Duração |
|---|---|---|
| cloud-init | Usuário, hostname, fuso, SSH e todos os scripts no lugar. | ~2 min |
| `noc-probe-setup` | Instala as ferramentas. **Precisa de internet.** | 10–25 min |

O segundo estágio é demorado mesmo: 512 MB de RAM e I/O de microSD instalando
a lista inteira. **Não corte a energia achando que travou.** Acompanhe com
`tail -f /var/log/noc-probe-setup.log`; o cloud-init deixa o dele em
`/var/log/cloud-init-output.log`.

### Trocar de Wi-Fi depois

Com o probe rodando, use o helper embarcado:

```bash
noc-wifi --list                    # redes visíveis
noc-wifi "SSID da rede" "senha"    # conecta e memoriza
noc-wifi --saved                   # o que já está guardado
```

### Acesso

```bash
ssh <usuario>@10.55.0.1         # pelo cabo USB (conector do meio, "USB", não o "PWR")
ssh <usuario>@<ip-do-wifi>      # pela rede
```

Enquanto os pacotes não instalaram não existe `dnsmasq` no probe, então o
Windows não recebe DHCP pela USB e cai em APIPA. O perfil do `usb0` traz
`link-local=enabled` justamente para os dois se enxergarem nesse intervalo. Se
mesmo assim não conectar, ponha o adaptador USB do Windows em
`10.55.0.2 / 255.255.255.248` na mão — isso sempre funciona.

No login o `probe-status` mostra sozinho onde o probe está plugado.

---

## Diagnosticar um probe que não responde

O Zero 2 W não tem console utilizável: sem mini-HDMI, sem adaptador serial e
sem rede, não há como ver o que aconteceu. `tools/add-boot-debug.py` resolve
isso injetando num cartão já gravado um serviço que despeja um relatório
completo em `noc-debug.txt` **na partição FAT32 de boot** — a única que o
Windows lê.

```powershell
python tools\add-boot-debug.py D:
```

Ligue o Pi, espere, desligue, e leia o cartão. O relatório traz módulos do
gadget carregados, presença do UDC, `dmesg` do `dwc2`, estado do
NetworkManager, varredura de redes Wi-Fi visíveis, uma tentativa real de
conexão com a mensagem de erro do `nmcli`, logs do cloud-init e do setup.

Para o caso em que nem o cloud-init roda, `payload/noc-debug2.sh` faz o mesmo
por `systemd.run` + `systemd.unit=kernel-command-line.target` — o mesmo
mecanismo que o Imager usava para o `firstrun.sh`, portanto independente de
tudo o mais. Ele restaura o `cmdline.txt` e desliga a placa sozinho ao
terminar.

---

## Segurança

`config.env` guarda senha e PSK de Wi-Fi em texto puro; está no `.gitignore`
junto com `out/` (que carrega o hash). **Nenhum dos dois pode ser versionado.**

A senha em texto nunca chega ao cartão: vira hash na sua máquina. O hash é
gerado via arquivo temporário com ACL restrita e sobrescrito antes de ser
apagado — não por argumento de linha de comando (visível na lista de
processos) nem por stdin (ver a nota abaixo).

O usuário recebe `sudo` sem senha, para as ferramentas que exigem root
(`tcpdump`, `nmap`) funcionarem em campo sem atrito. `ping` e `arping` levam
`cap_net_raw`, então o `noc-diag` roda sem `sudo`. Prefira `SSH_PUBKEY_FILE` a
senha: o probe visita redes de terceiros.

---

## Armadilhas que custaram caro

Ficam registradas porque nenhuma delas dá erro na hora — todas se manifestam
só com o Pi montado e inalcançável.

**O `instance-id` que vale é o do `cmdline.txt`, não o do `meta-data`.** Com
`ds=nocloud;i=rpi-imager-...` na linha de comando do kernel, o cloud-init toma
o `i=` como instance-id efetivo e ignora o `meta-data`. Incrementar só o
`meta-data` não faz nada: o cartão é tratado como já provisionado e todo
`write_files` e `runcmd` novo é silenciosamente pulado. Regravar o cartão não
surtia efeito algum. O gerador agora sincroniza o `i=` a cada gravação.

**SSID tem que bater byte a byte.** Uma rede chamada
`Grupo Imagetech -  Automação` — com **dois** espaços depois do hífen, ao
contrário das redes irmãs — não conecta se você configurar com um espaço. Não
há erro: o rádio simplesmente procura uma rede que não existe. Confirme com a
varredura do próprio Pi (`iw dev wlan0 scan | grep SSID`) antes de acusar
sinal, banda ou autenticação.

**Senha por stdin no PowerShell 5.1 gera hash errado.** O pipe nativo corrompe
a entrada de executáveis MSYS, e escrever direto no `BaseStream` também não
resolve: tocar em `.StandardInput` faz o .NET ligar `AutoFlush`, que já despeja
um BOM UTF-8 no pipe. O BOM entra na senha. O hash resultante não corresponde
a senha nenhuma. Por isso o script usa `openssl passwd -in <arquivo>` e ainda
reconfere o hash com o mesmo sal antes de gravar.

**`dtoverlay=dwc2` não é o que parece.** O `config.txt` é dividido em seções
por modelo, e as imagens de fábrica já trazem `dtoverlay=dwc2,dr_mode=host`
dentro de `[cm5]` — que não vale para o Zero 2 W e ainda é o modo *oposto* ao
que o gadget precisa. Procurar a linha solta pelo arquivo inteiro dá falso
positivo, o overlay correto não é acrescentado e o USB não sobe. O gerador
rastreia a seção corrente e só aceita `dr_mode=peripheral` em escopo que valha
para a placa.

**Reconstruir o `cmdline.txt` a partir do backup escreve um `root=` errado.**
Regravar a imagem troca o PARTUUID do cartão; partir de um `.noc-bak` antigo
produz um `root=` apontando para uma partição que não existe mais, e o Pi não
boota. O gerador lê sempre o arquivo vivo.

**BOM no `user-data` é fatal e silencioso.** O cloud-init descarta o arquivo
inteiro e o Pi boota cru. Todos os arquivos são gravados com
`WriteAllBytes` + `Encoding.UTF8.GetBytes`, que nunca emite preâmbulo.

**`bind-interfaces` derruba o dnsmasq quando não há cabo.** A `usb0` só ganha
endereço quando o cabo é plugado; com `bind-interfaces` o dnsmasq exige a
interface pronta no momento em que sobe, e aborta. A opção certa é
`bind-dynamic`, que passa a atender assim que a interface aparece.

---

## Estrutura

```
Write-ProbeCard.ps1        gerador do cartão (roda no Windows)
config.example.env         modelo de configuração
payload/
  user-data.tmpl           cloud-config: usuário, scripts, serviços
  network-config.tmpl      Wi-Fi em netplan (caminho secundário)
  noc-probe-setup.sh.tmpl  instalação das ferramentas, com retentativa
  noc-diag.sh              motor de diagnóstico e veredito
  probe-status.sh          resumo mostrado no login
  noc-share.sh             modo placa de rede (NAT usb0 -> uplink)
  noc-debug.sh             despejo de diagnóstico na partição de boot
  noc-debug2.sh            idem, independente do cloud-init (systemd.run)
tools/
  add-boot-debug.py        injeta o despejo num cartão já gravado
```

Os `.tmpl` usam marcadores `@@NOME@@`. O gerador aborta se sobrar algum sem
substituir, e valida o YAML resultante antes de gravar.

---

## Estado

**Validado em hardware real.** O probe boota, o cloud-init provisiona, o
usuário é criado, o SSH sobe, o Wi-Fi conecta e autoconecta nos boots
seguintes, o relógio sincroniza por NTP e a instalação de pacotes roda.

**Gadget USB: funcional do lado do Pi, não testado ponta a ponta.** O
diagnóstico confirmou `dwc2` em modo peripheral, UDC presente em
`/sys/class/udc/`, `g_ether` carregado e a interface `usb0` criada. O Windows
não enumerou nada em nenhuma tentativa — por eliminação, o cabo micro-USB
usado nos testes não tem as linhas de dados. Falta confirmar com um cabo de
dados.

**`noc-share` implementado, não exercitado.** Depende do cabo de dados para ter
um computador do outro lado recebendo endereço.

**LLDP inoperante por hardware**, conforme a seção acima.

Validado no Windows: sintaxe dos scripts; round-trip byte-idêntico (sha256) dos
scripts embutidos no YAML e extraídos de volta; `user-data` parseando como
cloud-config válido; ausência de BOM e CRLF em tudo que vai para o cartão;
conferência de que o hash gerado realmente valida a senha; e comparação byte a
byte do SSID gravado contra o que o rádio do Pi escaneou.
