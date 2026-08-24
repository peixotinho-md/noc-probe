#!/usr/bin/env python3
"""
noc-pocket-probe - injeta o despejo de diagnostico num cartao ja gravado.

Uso:  python tools/add-boot-debug.py D:

Por que existe: quando o probe nao responde nem por Wi-Fi nem por USB, nao ha
como entrar nele. Este script acrescenta ao user-data um servico que escreve
um relatorio completo em /boot/firmware/noc-debug.txt, na particao FAT32 -- a
unica que o Windows le. Tambem incrementa o instance-id do meta-data, que e o
mecanismo oficial do cloud-init para reprocessar um cartao ja usado; sem isso
o cloud-init reconhece a instancia como ja provisionada e ignora as mudancas.

E idempotente: rodar duas vezes nao duplica nada.
"""
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("ERRO: PyYAML nao instalado.  pip install pyyaml")

MARCA = "noc-debug.sh"

UNIT = """[Unit]
Description=noc-probe: despejo de diagnostico na particao de boot
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/noc-debug.sh
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
"""


def bloco(item_ind, path, perms, conteudo):
    """Monta uma entrada de write_files com a indentacao do arquivo alvo."""
    ki = " " * (item_ind + 2)          # chaves do item
    ci = " " * (item_ind + 4)          # corpo do bloco literal
    corpo = "\n".join((ci + l) if l.strip() else "" for l in conteudo.split("\n"))
    return (
        f"{' ' * item_ind}- path: {path}\n"
        f"{ki}permissions: '{perms}'\n"
        f"{ki}owner: root:root\n"
        f"{ki}content: |\n"
        f"{corpo.rstrip()}\n"
    )


def indent_da_lista(linhas, i, padrao=2):
    """Descobre a indentacao dos itens da lista que comeca depois da linha i."""
    for l in linhas[i + 1:]:
        if not l.strip():
            continue
        m = re.match(r"^(\s*)-\s", l)
        if m:
            return len(m.group(1))
        if not l.startswith(" "):
            break
    return padrao


def inserir_apos(linhas, chave, novas):
    for i, l in enumerate(linhas):
        if l.rstrip() == chave:
            ind = indent_da_lista(linhas, i)
            return linhas[:i + 1] + novas(ind).split("\n") + linhas[i + 1:], ind
    sys.exit(f"ERRO: nao encontrei a chave '{chave}' no user-data")


def main():
    drive = sys.argv[1] if len(sys.argv) > 1 else "D:"
    boot = Path(drive + "\\" if len(drive) == 2 and drive[1] == ":" else drive)
    ud, md = boot / "user-data", boot / "meta-data"
    dbg = Path(__file__).resolve().parent.parent / "payload" / "noc-debug.sh"

    for f in (ud, md, dbg):
        if not f.is_file():
            sys.exit(f"ERRO: nao achei {f}")

    texto = ud.read_text(encoding="utf-8")
    if MARCA in texto:
        print("user-data ja contem o despejo de diagnostico; nada a inserir.")
    else:
        script = dbg.read_text(encoding="utf-8")
        linhas = texto.split("\n")

        linhas, _ = inserir_apos(
            linhas, "write_files:",
            lambda ind: (bloco(ind, "/usr/local/sbin/noc-debug.sh", "0755", script)
                         + bloco(ind, "/etc/systemd/system/noc-debug.service", "0644", UNIT)).rstrip(),
        )
        linhas, _ = inserir_apos(
            linhas, "runcmd:",
            lambda ind: (f"{' ' * ind}- [ systemctl, enable, noc-debug.service ]\n"
                         f"{' ' * ind}- [ systemctl, start, --no-block, noc-debug.service ]").rstrip(),
        )
        texto = "\n".join(linhas)

        d = yaml.safe_load(texto)          # so grava se o YAML continuar valido
        caminhos = [w["path"] for w in d["write_files"]]
        assert "/usr/local/sbin/noc-debug.sh" in caminhos, "entrada nao entrou no write_files"
        ud.write_bytes(texto.encode("utf-8"))
        print(f"user-data: +2 write_files (agora {len(caminhos)}), +2 runcmd (agora {len(d['runcmd'])})")

    # O que REALMENTE manda no instance-id e o token i= do cmdline.txt, nao o
    # meta-data. Comprovado no dump: com ds=nocloud;i=rpi-imager-1787255423175
    # o cloud-init reporta esse valor como instance-id efetivo e ignora o
    # meta-data, tratando o cartao como ja provisionado. Sem mexer aqui, nenhum
    # write_files ou runcmd novo chega a rodar.
    cl = boot / "cmdline.txt"
    cltxt = cl.read_text(encoding="utf-8").strip()
    m = re.search(r"(ds=nocloud[^\s]*?;i=)([^\s;]+)", cltxt)
    if m:
        antigo = m.group(2)
        novo_i = re.sub(r"-r(\d+)$", lambda x: f"-r{int(x.group(1)) + 1}", antigo) \
            if re.search(r"-r\d+$", antigo) else antigo + "-r1"
        cltxt = cltxt[:m.start(2)] + novo_i + cltxt[m.end(2):]
        cl.write_bytes((cltxt + "\n").encode("utf-8"))
        print(f"cmdline.txt: i= {antigo} -> {novo_i}   (este e o que conta)")
    else:
        print("AVISO: cmdline.txt sem 'ds=nocloud;i=' - o cloud-init pode nao reprocessar")

    # mantido por coerencia, mas sozinho nao surte efeito
    mdtxt = md.read_text(encoding="utf-8")
    atual = re.search(r"^instance-id:\s*(\S+)", mdtxt, re.M)
    if not atual:
        sys.exit("ERRO: meta-data sem instance-id")
    novo = atual.group(1)
    novo = re.sub(r"-r(\d+)$", lambda m: f"-r{int(m.group(1)) + 1}", novo) if re.search(r"-r\d+$", novo) else novo + "-r1"
    mdtxt = re.sub(r"^instance-id:\s*\S+", f"instance-id: {novo}", mdtxt, count=1, flags=re.M)
    yaml.safe_load(mdtxt)
    md.write_bytes(mdtxt.encode("utf-8"))
    print(f"meta-data: instance-id {atual.group(1)} -> {novo}")
    print("\nPronto. Ejete o cartao, ligue o Pi, espere 3 minutos, desligue e")
    print("traga o cartao de volta: o relatorio estara em noc-debug.txt.")


if __name__ == "__main__":
    main()
