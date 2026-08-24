<#
.SYNOPSIS
    Grava a personalizacao do noc-pocket-probe na particao de boot de um
    cartao ja gravado com Raspberry Pi OS Lite (64-bit).

.DESCRIPTION
    As imagens de Raspberry Pi OS a partir de 2025 provisionam por cloud-init
    (arquivos user-data / meta-data / network-config na particao de boot), e
    nao mais pelo firstrun.sh + systemd.run da era Bookworm. Este script gera
    esses arquivos.

    Fluxo:
      1. Raspberry Pi Imager -> Raspberry Pi OS Lite (64-bit) -> grava o cartao.
         A customizacao do Imager pode ser usada ou nao: o que este script
         gerar substitui o user-data dela por completo.
      2. Reinsira o cartao. O Windows monta a particao FAT32 "bootfs".
      3. .\Write-ProbeCard.ps1 -BootDrive D:
      4. Ejete, ponha no Pi, ligue.

.PARAMETER BootDrive
    Letra da particao de boot (ex: D:). Se omitido, procura sozinho a unidade
    removivel que contenha cmdline.txt e config.txt.

.PARAMETER Config
    Arquivo de configuracao. Padrao: .\config.env

.PARAMETER DryRun
    Nao toca no cartao: renderiza tudo em .\out\ para inspecao.

.EXAMPLE
    .\Write-ProbeCard.ps1 -DryRun

.EXAMPLE
    .\Write-ProbeCard.ps1 -BootDrive D:
#>
[CmdletBinding()]
param(
    [string]$BootDrive,
    [string]$Config = "$PSScriptRoot\config.env",
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Info  { param($m) Write-Host "  $m" }
function Step  { param($m) Write-Host "`n$m" -ForegroundColor Cyan }
function Good  { param($m) Write-Host "  ok   $m" -ForegroundColor Green }
function Warn2 { param($m) Write-Host "  !    $m" -ForegroundColor Yellow }
function Die   { param($m) Write-Host "  X    $m" -ForegroundColor Red; exit 1 }

$LF = "`n"

function ReadTpl { param($p)
    if (-not (Test-Path $p)) { Die "template ausente: $p" }
    return (Get-Content -LiteralPath $p -Raw -Encoding UTF8) -replace "`r`n", $LF
}
function WriteLF { param($path, $text)
    $text = $text -replace "`r`n", $LF
    if ($text -ne '' -and -not $text.EndsWith($LF)) { $text += $LF }
    # WriteAllBytes + GetBytes nunca emite BOM. Um BOM no inicio do user-data
    # faz o cloud-init descartar o arquivo inteiro, e o Pi boota cru.
    [System.IO.File]::WriteAllBytes($path, [System.Text.Encoding]::UTF8.GetBytes($text))
}
# Indenta para caber num bloco literal YAML. Linhas vazias FICAM vazias:
# espaco em linha em branco nao quebra o bloco, mas suja o arquivo.
function Indent { param($text, $n)
    $pad = ' ' * $n
    $out = foreach ($l in ($text -replace "`r`n", $LF).Split("`n")) {
        if ($l.Trim() -eq '') { '' } else { $pad + $l }
    }
    return ($out -join $LF).TrimEnd()
}

# --------------------------------------------------------------- config
Step "configuracao"
if (-not (Test-Path $Config)) {
    Die "nao achei $Config. Copie config.example.env para config.env e edite."
}

$cfg = @{}
foreach ($line in Get-Content -LiteralPath $Config -Encoding UTF8) {
    $t = $line.Trim()
    if ($t -eq '' -or $t.StartsWith('#')) { continue }
    $i = $t.IndexOf('=')
    if ($i -lt 1) { continue }
    $k = $t.Substring(0, $i).Trim()
    $v = $t.Substring($i + 1).Trim()
    if ($v.Length -ge 2) {
        if (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'"))) {
            $v = $v.Substring(1, $v.Length - 2)
        }
    }
    $cfg[$k] = $v
}
function Cfg { param($k, $d = '') if ($cfg.ContainsKey($k) -and $cfg[$k] -ne '') { return $cfg[$k] } else { return $d } }

$HOSTNAME_    = Cfg HOSTNAME 'noc-probe'
$USERNAME_    = Cfg USERNAME 'noc'
$TIMEZONE_    = Cfg TIMEZONE 'America/Sao_Paulo'
$WIFI_COUNTRY = Cfg WIFI_COUNTRY 'BR'
$USB_GADGET   = (Cfg USB_GADGET 'true').ToLower() -eq 'true'
$ENABLE_ZRAM  = (Cfg ENABLE_ZRAM 'true').ToLower() -eq 'true'
$PACKAGES     = Cfg PACKAGES 'mtr-tiny dnsutils curl'

if ($HOSTNAME_ -notmatch '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$') {
    Die "HOSTNAME invalido: '$HOSTNAME_' (letras, numeros e hifen)"
}
if ($USERNAME_ -notmatch '^[a-z_][a-z0-9_-]{0,31}$') { Die "USERNAME invalido: '$USERNAME_'" }
if ($TIMEZONE_ -notmatch '^[A-Za-z]+/[A-Za-z_+-]+$')  { Die "TIMEZONE invalido: '$TIMEZONE_'" }
Good "hostname=$HOSTNAME_  usuario=$USERNAME_  tz=$TIMEZONE_  pais=$WIFI_COUNTRY"

# ------------------------------------------------------ achar o cartao
$boot = $null
if (-not $DryRun) {
    Step "cartao"
    if (-not $BootDrive) {
        $found = @()
        foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
            if (-not $d.IsReady -or $d.DriveType -ne 'Removable') { continue }
            $r = $d.RootDirectory.FullName
            if ((Test-Path (Join-Path $r 'cmdline.txt')) -and (Test-Path (Join-Path $r 'config.txt'))) { $found += $d }
        }
        if ($found.Count -eq 0) { Die "nao achei a particao de boot. Grave o cartao no Imager, reinsira, ou passe -BootDrive D:" }
        if ($found.Count -gt 1) { Die "mais de um candidato ($(($found | ForEach-Object { $_.Name }) -join ', ')). Escolha com -BootDrive." }
        $BootDrive = $found[0].Name.TrimEnd('\')
    }
    $boot = $BootDrive.TrimEnd('\', '/')
    if ($boot -notmatch ':$') { $boot = "$boot`:" }
    $boot = "$boot\"

    foreach ($f in 'cmdline.txt', 'config.txt') {
        if (-not (Test-Path (Join-Path $boot $f))) { Die "$boot nao e uma particao de boot do Raspberry Pi OS (falta $f)" }
    }
    $vol = New-Object System.IO.DriveInfo($boot)
    if ($vol.DriveType -ne 'Removable') {
        Warn2 "$boot nao e unidade removivel ($($vol.DriveType)). Confirme que e o cartao!"
        if ((Read-Host "  digite SIM para continuar") -ne 'SIM') { Die "abortado" }
    }
    Good "particao de boot: $boot ($([math]::Round($vol.TotalSize/1MB)) MB, $([math]::Round($vol.AvailableFreeSpace/1MB)) MB livres)"

    # Esta imagem provisiona por cloud-init? Se nao, o user-data seria ignorado
    # e o Pi bootaria sem nada configurado.
    $cmdlineNow = (Get-Content -LiteralPath (Join-Path $boot 'cmdline.txt') -Raw)
    if ($cmdlineNow -notmatch 'ds=nocloud') {
        Warn2 "o cmdline.txt nao tem 'ds=nocloud': esta imagem pode nao usar cloud-init."
        Warn2 "Imagens Bookworm e anteriores usam firstrun.sh, que este script nao gera mais."
        if ((Read-Host "  digite SIM para gravar assim mesmo") -ne 'SIM') { Die "abortado" }
    } else {
        Good "imagem provisiona por cloud-init (ds=nocloud)"
    }
    if (Test-Path (Join-Path $boot 'firstrun.sh')) {
        Warn2 "ha um firstrun.sh no cartao (customizacao antiga do Imager). Vou remove-lo para nao concorrer com o cloud-init."
    }
}

# ------------------------------------------------------- hash de senha
Step "senha"
$hash = Cfg PASSWORD_HASH ''
$plain = Cfg PASSWORD ''
if ($plain -eq 'trocar-esta-senha') { $plain = '' }

if ($hash -eq '' -and $plain -eq '' -and $boot) {
    # Sem senha no config.env: reaproveita a que o Imager ja gravou no cartao,
    # em vez de gerar um probe sem login possivel.
    # Aceita as duas formas: "user:\n  name:" (customizacao do Imager) e
    # "users:\n  - name:" (o que este script gera). Sem o "-?" opcional a
    # reexecucao sobre um cartao ja gravado por nos nao acharia nada.
    $ud = Join-Path $boot 'user-data'
    if (Test-Path $ud) {
        $udTxt = Get-Content -LiteralPath $ud -Raw
        $mName = [regex]::Match($udTxt, '(?m)^\s+-?\s*name:\s*(\S+)')
        $mPass = [regex]::Match($udTxt, '(?m)^\s+-?\s*passwd:\s*"?([^"\r\n]+?)"?\s*$')
        if ($mName.Success -and $mPass.Success) {
            $USERNAME_ = $mName.Groups[1].Value
            $hash      = $mPass.Groups[1].Value.Trim()
            Warn2 "config.env sem senha - reaproveitando o usuario '$USERNAME_' e o hash ja gravado no cartao."
            Info  "Para nao depender do cartao, cole em config.env:  PASSWORD_HASH=$hash"
        }
    }
}

if ($hash -eq '') {
    if ($plain -eq '') {
        Die "defina PASSWORD (ou PASSWORD_HASH) em $Config. Sem credencial nao da para entrar no probe."
    }
    if ($plain.Length -lt 8) { Warn2 "senha curta (< 8 caracteres)" }

    $opensslCandidates = @()
    $inPath = Get-Command openssl.exe -ErrorAction SilentlyContinue
    if ($inPath) { $opensslCandidates += $inPath.Source }
    $opensslCandidates += "$env:ProgramFiles\Git\usr\bin\openssl.exe"
    $opensslCandidates += "${env:ProgramFiles(x86)}\Git\usr\bin\openssl.exe"
    $opensslCandidates += "$env:LOCALAPPDATA\Programs\Git\usr\bin\openssl.exe"
    $openssl = $null
    foreach ($c in $opensslCandidates) { if ($c -and (Test-Path $c)) { $openssl = $c; break } }
    if (-not $openssl) { Die "openssl.exe nao encontrado. Instale o Git for Windows, ou gere o hash com 'openssl passwd -6' e cole em PASSWORD_HASH." }

    # A senha vai por arquivo temporario, nao por stdin nem por argumento:
    #   - argumento fica visivel na lista de processos;
    #   - stdin e uma armadilha no PowerShell 5.1. O pipe nativo corrompe a
    #     entrada de exe MSYS, e ir direto ao BaseStream tambem nao salva: ao
    #     tocar em .StandardInput o .NET liga AutoFlush, que ja escreve um BOM
    #     UTF-8 no pipe. O BOM entra na senha e o hash nao corresponde a senha
    #     nenhuma - o cartao sai com login impossivel.
    $pwFile = Join-Path ([System.IO.Path]::GetTempPath()) ("noc-pw-" + [guid]::NewGuid().ToString('N') + ".tmp")
    try {
        [System.IO.File]::WriteAllBytes($pwFile, [System.Text.Encoding]::UTF8.GetBytes($plain))
        & icacls.exe $pwFile /inheritance:r /grant:r "${env:USERNAME}:(R,W,D)" | Out-Null
        $hash = (& $openssl passwd -6 -in $pwFile) | Select-Object -First 1
        if ($LASTEXITCODE -ne 0 -or -not $hash) { Die "falha ao gerar o hash com $openssl" }
        $hash = $hash.Trim()
        # Reconfere com o mesmo sal: se divergir, algo entrou junto com a senha.
        $salt = ($hash -split '\$')[2]
        $chk  = (& $openssl passwd -6 -salt $salt -in $pwFile) | Select-Object -First 1
        if ("$chk".Trim() -ne $hash) {
            Die "verificacao do hash falhou - a senha chegou corrompida ao openssl. Gere o hash a mao e cole em PASSWORD_HASH."
        }
    } finally {
        if (Test-Path $pwFile) {
            [System.IO.File]::WriteAllBytes($pwFile, (New-Object byte[] 256))
            Remove-Item -LiteralPath $pwFile -Force -ErrorAction SilentlyContinue
        }
    }
}
# $y$ = yescrypt (padrao no Trixie), $6$ = sha512, $5$ = sha256
if ($hash -notmatch '^\$(y|6|5|2[aby])\$') { Die "PASSWORD_HASH nao parece um hash de senha crypt(3): '$hash'" }
Good "credencial pronta para '$USERNAME_' (senha em texto nunca vai ao cartao)"

# ------------------------------------------------------------- chave ssh
$sshKeyFile = Cfg SSH_PUBKEY_FILE ''
$sshBlock = ''
if ($sshKeyFile -ne '') {
    if (-not (Test-Path $sshKeyFile)) { Die "SSH_PUBKEY_FILE nao existe: $sshKeyFile" }
    $key = (Get-Content -LiteralPath $sshKeyFile -Raw).Trim()
    if ($key -match 'PRIVATE KEY') { Die "isso e uma chave PRIVADA. Use o arquivo .pub." }
    if ($key -notmatch '^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-)') { Die "SSH_PUBKEY_FILE nao parece uma chave publica." }
    $sshBlock = "    ssh_authorized_keys:$LF      - `"$key`""
    Good "chave publica: $(Split-Path -Leaf $sshKeyFile)"
} else {
    Warn2 "sem chave SSH - so senha. Preencha SSH_PUBKEY_FILE se puder."
}

# ----------------------------------------------------------------- wi-fi
Step "wi-fi"
$aps = @()
$wifiKeys = @()
foreach ($n in 1, 2) {
    $ssid = Cfg "WIFI${n}_SSID" ''
    if ($ssid -eq '') { continue }
    $psk = Cfg "WIFI${n}_PSK" ''
    if ($psk -ne '' -and ($psk.Length -lt 8 -or $psk.Length -gt 63)) {
        Die "WIFI${n}_PSK precisa ter de 8 a 63 caracteres (tem $($psk.Length))"
    }
    if ($ssid.Contains('"') -or $psk.Contains('"')) { Die "aspas duplas em SSID/PSK nao sao suportadas" }
    # O formato keyfile do NetworkManager trata \ como escape e ; como separador
    # de lista; nao vale a pena escapar, e mais honesto recusar.
    if ($ssid -match '[\\;]' -or $psk -match '[\\;]') {
        Die "WIFI${n}: barra invertida ou ponto-e-virgula em SSID/PSK nao sao suportados"
    }
    if ($psk -eq '') {
        $aps += "        `"$ssid`": {}"
        Warn2 "wifi$n '$ssid' - rede aberta"
    } else {
        $aps += "        `"$ssid`":$LF          password: `"$psk`""
        Good "wifi$n '$ssid'"
    }

    # Perfil do NetworkManager escrito direto, sem passar pelo netplan.
    #
    # O caminho netplan -> NM se mostrou pouco confiavel nesta imagem: ela
    # referencia um modulo cc_netplan_nm_patch que o cloud-init instalado nao
    # possui, e o netplan ainda reescreve SSID nao-ASCII como lista de bytes
    # decimais. Resultado observado em campo: a conexao Wi-Fi ora existia, ora
    # sumia entre boots. O keyfile abaixo grava o SSID como UTF-8 literal e nao
    # depende de nenhum dos dois, do mesmo jeito que ja funciona para o usb0.
    $prio   = Cfg "WIFI${n}_PRIORITY" '10'
    $hidden = if ((Cfg "WIFI${n}_HIDDEN" 'false') -match '^(true|1|yes)$') { 'true' } else { 'false' }
    $secBlock = ''
    if ($psk -ne '') {
        $secBlock = "$LF      [wifi-security]$LF      key-mgmt=wpa-psk$LF      psk=$psk"
    }
    $wifiKeys += @"
  - path: /etc/NetworkManager/system-connections/noc-wifi$n.nmconnection
    owner: root:root
    permissions: '0600'
    content: |
      [connection]
      id=noc-wifi$n
      type=wifi
      interface-name=wlan0
      autoconnect=true
      autoconnect-priority=$prio

      [wifi]
      mode=infrastructure
      hidden=$hidden
      ssid=$ssid$secBlock

      [ipv4]
      method=auto

      [ipv6]
      method=auto
      addr-gen-mode=default
"@
}
if ($wifiKeys.Count -gt 0) {
    # Sem isto o wlan0 pode nascer "unmanaged" quando o netplan deixa de
    # declara-lo -- foi exatamente o que aconteceu com o usb0.
    $wifiKeys += @"
  - path: /etc/NetworkManager/conf.d/98-noc-wlan0.conf
    owner: root:root
    permissions: '0644'
    content: |
      [device-wlan0]
      match-device=interface-name:wlan0
      managed=1
"@
}
$wifiKeyfiles = if ($wifiKeys.Count -gt 0) { $wifiKeys -join $LF } else { '' }
if ($aps.Count -gt 0) {
    $wifiBlock = @"
network:
  version: 2
  wifis:
    wlan0:
      dhcp4: true
      dhcp6: true
      optional: true
      regulatory-domain: "$WIFI_COUNTRY"
      access-points:
$($aps -join $LF)
"@
} else {
    Warn2 "nenhuma rede Wi-Fi no config.env - o probe nasce sem internet."
    Warn2 "As ferramentas de NOC so instalam quando ele alcancar a rede."
    Info  "Depois do primeiro boot, entre pelo cabo USB e rode: noc-wifi <SSID> <senha>"
    $wifiBlock = "# Nenhuma rede definida. Use 'noc-wifi <SSID> <senha>' no probe."
}

# ------------------------------------------------------------ blocos opc
$zramBlock = ": # zram desabilitado"
if ($ENABLE_ZRAM) {
    $zramBlock = @'
apt-get install -y --no-install-recommends zram-tools || echo "AVISO: zram-tools falhou"
cat > /etc/default/zramswap <<'ZRAMEOF'
ALGO=zstd
PERCENT=50
PRIORITY=100
ZRAMEOF
systemctl enable zramswap.service 2>/dev/null
'@
}

# usb0: IP fixo no probe e DHCP so nessa interface, SEM anunciar gateway nem
# DNS. Assim o notebook ganha endereco em segundos e continua saindo pela
# propria rede - plugar o probe nunca derruba a internet do usuario.
$usbBlock = ": # usb gadget desabilitado"
$usbWriteFiles = ''
$usbRuncmd = ''
if ($USB_GADGET) {
    $usbBlock = @'
apt-get install -y --no-install-recommends dnsmasq || echo "AVISO: dnsmasq falhou"
# port=0 desliga o DNS; dhcp-option=3 e 6 vazios = nao anuncia gateway nem
# DNS, entao o notebook nao roteia por aqui.
cat > /etc/dnsmasq.d/noc-usb0.conf <<'DNSMEOF'
port=0
interface=usb0
bind-dynamic
except-interface=lo
dhcp-range=10.55.0.2,10.55.0.6,255.255.255.248,12h
dhcp-option=3
dhcp-option=6
DNSMEOF
systemctl enable dnsmasq 2>/dev/null
systemctl restart dnsmasq 2>/dev/null
'@

    # link-local=enabled ao lado do IP fixo: antes do dnsmasq existir (isto e,
    # antes de o probe ver a internet pela primeira vez) o Windows nao recebe
    # DHCP e cai em APIPA. Com o link-local os dois se enxergam mesmo assim,
    # e o noc-probe.local resolve por mDNS.
    $usbWriteFiles = @"

  - path: /etc/NetworkManager/system-connections/usb0.nmconnection
    owner: root:root
    permissions: '0600'
    content: |
      [connection]
      id=usb0
      type=ethernet
      interface-name=usb0
      autoconnect=true
      autoconnect-priority=-10

      [ipv4]
      method=manual
      address1=10.55.0.1/29
      link-local=enabled
      never-default=true
      may-fail=true

      [ipv6]
      method=link-local
  - path: /etc/NetworkManager/conf.d/99-noc-usb0.conf
    owner: root:root
    permissions: '0644'
    content: |
      # Sem isto o usb0 aparece como "unmanaged" no nmcli e o perfil acima
      # nunca e aplicado -- observado em campo. Quando o netplan e o
      # renderizador, ele restringe o NetworkManager aos dispositivos que o
      # proprio netplan declara, e o usb0 nao esta entre eles. Este arquivo
      # em /etc sobrepoe o que o netplan gera em /run.
      [device-usb0]
      match-device=interface-name:usb0
      managed=1
  - path: /usr/local/bin/noc-share
    owner: root:root
    permissions: '0755'
    content: |
$(Indent (ReadTpl "$PSScriptRoot\payload\noc-share.sh") 6)
  - path: /etc/systemd/system/noc-share.service
    owner: root:root
    permissions: '0644'
    content: |
      [Unit]
      Description=noc-probe: reaplica o estado do compartilhamento pela USB
      After=network-online.target dnsmasq.service
      Wants=network-online.target

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/usr/local/bin/noc-share apply

      [Install]
      WantedBy=multi-user.target
"@

    $usbRuncmd = "  - [ systemctl, enable, noc-share.service ]"
}

# --------------------------------------------------------- render payload
Step "renderizando"
$nocDiag     = ReadTpl "$PSScriptRoot\payload\noc-diag.sh"
$probeStatus = ReadTpl "$PSScriptRoot\payload\probe-status.sh"

$setup = ReadTpl "$PSScriptRoot\payload\noc-probe-setup.sh.tmpl"
$setup = $setup.Replace('@@PACKAGES@@',   $PACKAGES)
$setup = $setup.Replace('@@ZRAM_BLOCK@@', $zramBlock)
$setup = $setup.Replace('@@USB_BLOCK@@',  $usbBlock)

$userData = ReadTpl "$PSScriptRoot\payload\user-data.tmpl"
$userData = $userData.Replace('@@HOSTNAME@@',        $HOSTNAME_)
$userData = $userData.Replace('@@TIMEZONE@@',        $TIMEZONE_)
$userData = $userData.Replace('@@USERNAME@@',        $USERNAME_)
$userData = $userData.Replace('@@PASSWORD_HASH@@',   $hash)
$userData = $userData.Replace('@@SSH_KEY_BLOCK@@',   $sshBlock)
$userData = $userData.Replace('@@NOC_DIAG@@',        (Indent $nocDiag 6))
$userData = $userData.Replace('@@PROBE_STATUS@@',    (Indent $probeStatus 6))
$userData = $userData.Replace('@@SETUP_SCRIPT@@',    (Indent $setup 6))
$userData = $userData.Replace('@@WIFI_WRITE_FILES@@', $wifiKeyfiles)
$userData = $userData.Replace('@@USB_WRITE_FILES@@', $usbWriteFiles)
$userData = $userData.Replace('@@USB_RUNCMD@@',      $usbRuncmd)

$netConfig = ReadTpl "$PSScriptRoot\payload\network-config.tmpl"
$netConfig = $netConfig.Replace('@@WIFI_BLOCK@@', $wifiBlock)

$stamp = "noc-probe-" + (Get-Date -Format 'yyyyMMddHHmmss')
$metaData = "instance-id: $stamp$LF" + "local-hostname: $HOSTNAME_$LF"

foreach ($pair in @(@('user-data', $userData), @('network-config', $netConfig))) {
    $left = ([regex]::Matches($pair[1], '@@[A-Z_]+@@') | ForEach-Object { $_.Value }) | Select-Object -Unique
    if ($left) { Die "placeholder nao substituido em $($pair[0]): $($left -join ', ')" }
}
Good "user-data ($($userData.Length) bytes), network-config, meta-data"

# Valida o YAML antes de gravar. Um user-data invalido faz o cloud-init
# descartar o arquivo em silencio, e so se descobre com o Pi ja montado.
$py = Get-Command python.exe, python3.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if ($py) {
    $tmpYaml = Join-Path ([System.IO.Path]::GetTempPath()) ("noc-ud-" + [guid]::NewGuid().ToString('N') + ".yaml")
    WriteLF $tmpYaml $userData
    $chk = & $py.Source -c "import sys,yaml; d=yaml.safe_load(open(sys.argv[1],encoding='utf-8')); print('OK', len(d.get('write_files',[])), 'write_files', len(d.get('runcmd',[])), 'runcmd')" $tmpYaml 2>&1
    Remove-Item -LiteralPath $tmpYaml -Force -ErrorAction SilentlyContinue
    if ("$chk" -match '^OK') { Good "YAML valido - $chk" }
    elseif ("$chk" -match 'ModuleNotFoundError') { Warn2 "PyYAML ausente - YAML nao validado (pip install pyyaml)" }
    else { Die "user-data invalido:$LF$chk" }
} else {
    Warn2 "python ausente - YAML nao validado"
}

# ------------------------------------------------------------- dry run
if ($DryRun) {
    $out = "$PSScriptRoot\out"
    New-Item -ItemType Directory -Force -Path $out | Out-Null
    WriteLF "$out\user-data" $userData
    WriteLF "$out\network-config" $netConfig
    WriteLF "$out\meta-data" $metaData
    Step "dry run"
    Good "gerado em $out (nenhum cartao foi tocado)"
    exit 0
}

# ------------------------------------------------------------- gravar
Step "gravando"
WriteLF (Join-Path $boot 'user-data')      $userData
WriteLF (Join-Path $boot 'network-config') $netConfig
WriteLF (Join-Path $boot 'meta-data')      $metaData
Good "user-data, network-config, meta-data"

# firstrun.sh de customizacao antiga concorreria com o cloud-init
$fr = Join-Path $boot 'firstrun.sh'
if (Test-Path $fr) { Remove-Item -LiteralPath $fr -Force; Good "firstrun.sh antigo removido" }

WriteLF (Join-Path $boot 'ssh') ''
Good "ssh (habilita sshd)"

# ---- cmdline.txt: uma unica linha. Preserva o ds=nocloud do Imager.
$cmdlinePath = Join-Path $boot 'cmdline.txt'
$bak = "$cmdlinePath.noc-bak"
if (-not (Test-Path $bak)) { Copy-Item -LiteralPath $cmdlinePath -Destination $bak }

# Le SEMPRE o arquivo vivo, nunca o backup. Regravar a imagem troca o PARTUUID
# do cartao; se partissemos do backup escreveriamos um root= apontando para uma
# particao que nao existe mais, e o Pi nao bootaria. A remocao dos nossos
# proprios tokens logo abaixo ja garante que rodar duas vezes nao acumula nada.
$cmdline = (Get-Content -LiteralPath $cmdlinePath -Raw) -replace "[`r`n]", ' '
$cmdline = ($cmdline -replace '\s+', ' ').Trim()
# tira restos de provisionamento antigo, mas NAO toca no ds=nocloud
$cmdline = ($cmdline -replace '\s*systemd\.run\S*', '')
$cmdline = ($cmdline -replace '\s*systemd\.unit=kernel-command-line\.target', '')
$cmdline = ($cmdline -replace '\s*modules-load=\S*', '')
$cmdline = ($cmdline -replace '\s+', ' ').Trim()

if ($USB_GADGET) {
    if ($cmdline -match 'rootwait') {
        $cmdline = $cmdline -replace 'rootwait', 'rootwait modules-load=dwc2,g_ether'
    } else {
        $cmdline = "$cmdline modules-load=dwc2,g_ether"
    }
}
if ($cmdline -notmatch 'ds=nocloud') { Warn2 "cmdline.txt sem ds=nocloud - o cloud-init pode nao rodar" }

# O instance-id que o cloud-init de fato respeita vem do token i= do cmdline,
# NAO do meta-data. Comprovado em campo: com o i= inalterado o cloud-init
# reporta o valor antigo como instance-id efetivo, considera o cartao ja
# provisionado e ignora todo write_files e runcmd novo -- regravar o cartao
# nao surtia efeito nenhum. Aqui ele e sincronizado com o mesmo carimbo do
# meta-data, entao cada gravacao produz uma instancia nova de verdade.
if ($cmdline -match 'ds=nocloud[^\s]*') {
    $ds = $Matches[0]
    if ($ds -match ';i=') { $dsNovo = $ds -replace ';i=[^;\s]*', ";i=$stamp" }
    else                  { $dsNovo = "$ds;i=$stamp" }
    $cmdline = $cmdline.Replace($ds, $dsNovo)
    Good "instance-id do cmdline sincronizado: i=$stamp"
}

WriteLF $cmdlinePath $cmdline
Good "cmdline.txt ($($cmdline.Length) chars, backup em cmdline.txt.noc-bak)"

# ---- config.txt: dtoverlay=dwc2 em modo peripheral
# O config.txt e dividido em secoes por modelo ([cm4], [cm5], [pi5], [all]).
# As imagens de fabrica ja trazem "dtoverlay=dwc2,dr_mode=host" dentro de
# [cm5] - que nao vale para o Zero 2 W, e ainda por cima e o modo oposto ao
# que o gadget precisa. Procurar a linha solta pelo arquivo inteiro daria um
# falso positivo e o probe nasceria sem USB.
if ($USB_GADGET) {
    $configPath = Join-Path $boot 'config.txt'
    $conf = (Get-Content -LiteralPath $configPath -Raw) -replace "`r`n", $LF

    $section = ''          # vazio = topo do arquivo, vale para todo modelo
    $applies = { param($s) $s -eq '' -or $s -eq 'all' -or $s -match '^pi0' }
    $havePeripheral = $false
    $conflict = ''
    foreach ($l in $conf.Split("`n")) {
        $t = $l.Trim()
        if ($t -match '^\[(.+)\]$') { $section = $Matches[1].ToLower(); continue }
        if ($t -match '^dtoverlay=dwc2') {
            if (-not (& $applies $section)) { continue }
            if ($t -match 'dr_mode=peripheral') { $havePeripheral = $true }
            elseif ($t -match 'dr_mode=host')   { $conflict = "$t  (secao [$section])" }
        }
    }

    if ($conflict) {
        Warn2 "config.txt tem '$conflict' valendo para esta placa - o modo host impede o gadget."
        Warn2 "Comente essa linha a mao se o USB nao subir."
    }
    if ($havePeripheral) {
        Good "config.txt ja tem dwc2 em modo peripheral valendo para esta placa"
    } else {
        $conf = $conf.TrimEnd() + "$LF$LF# noc-pocket-probe: ethernet sobre USB$LF[all]${LF}dtoverlay=dwc2,dr_mode=peripheral$LF"
        WriteLF $configPath $conf
        Good "config.txt + dtoverlay=dwc2,dr_mode=peripheral em [all]"
    }
}

# --------------------------------------------------------------- resumo
Step "pronto"
Info "1. Ejete o cartao com seguranca e ponha no Pi Zero 2 W."
Info "2. Ligue. O cloud-init provisiona tudo no primeiro boot (~2 min)."
if ($aps.Count -gt 0) {
    Info "3. Com Wi-Fi configurado, as ferramentas instalam sozinhas (10-25 min)."
} else {
    Info "3. SEM Wi-Fi: as ferramentas ainda NAO instalam. Entre pelo USB e rode:"
    Info "      noc-wifi `"<SSID>`" `"<senha>`""
    Info "   O servico de instalacao tenta de novo sozinho assim que houver rede."
}
Info ""
if ($USB_GADGET) {
    Info "Acesso por USB (conector do meio, marcado 'USB', nao o 'PWR'):"
    Info "   ssh $USERNAME_@10.55.0.1"
    Info "   Antes do dnsmasq existir, ponha o adaptador USB do Windows em"
    Info "   10.55.0.2 / 255.255.255.248, ou use ssh $USERNAME_@$HOSTNAME_.local"
}
Info "Acesso pela rede:  ssh $USERNAME_@$HOSTNAME_.local"
Info ""
Info "No probe: 'probe-status' mostra onde ele esta, 'noc-diag' da o veredito."
Info "Logs: /var/log/cloud-init-output.log e /var/log/noc-probe-setup.log"
