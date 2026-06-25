# CIS Scan Toolkit

Ferramentas para executar scans de compliance **CIS Benchmark** em servidores
**RHEL 9** usando **OpenSCAP**, projetadas para evitar o problema mais comum
desse tipo de scan: o processo `oscap` ser interrompido pelo OOM Killer do
Linux antes de terminar.

Inclui:
- Um script (`run-cis-scan.sh`) que aplica mitigações de memória e roda o
  scan em um único servidor.
- Um playbook Ansible (`ansible/playbook-cis-scan.yml`) para orquestrar a
  execução em muitos servidores ao mesmo tempo, em lotes controlados.
- Um tailoring file de exemplo (`examples/`) para excluir regras com bug
  conhecido de consumo de memória no OpenSCAP.

> Este projeto nasceu de um troubleshooting real: o scan completo do perfil
> CIS Server Level 1 em um servidor RHEL 9 com ~30 GB de RAM falhava
> repetidamente por falta de memória. As soluções abaixo foram validadas em
> produção/homologação até o scan completar com sucesso.

---

## Sumário

- [Pré-requisitos](#pré-requisitos)
- [Como funciona](#como-funciona)
- [Uso rápido (um servidor)](#uso-rápido-um-servidor)
- [Uso em escala (Ansible)](#uso-em-escala-ansible)
- [Riscos conhecidos](#riscos-conhecidos)
- [Solução de problemas](#solução-de-problemas)
- [Estrutura do repositório](#estrutura-do-repositório)
- [Roadmap / ideias de otimização](#roadmap--ideias-de-otimização)
- [Licença e referências](#licença-e-referências)

---

## Pré-requisitos

### No servidor a ser escaneado

| Requisito | Detalhe |
|---|---|
| SO | RHEL 9 (ou compatível: Rocky Linux 9, AlmaLinux 9, CentOS Stream 9) |
| Pacote `openscap-scanner` | Fornece o binário `oscap` |
| Pacote `scap-security-guide` | Fornece o datastream com o conteúdo CIS (`/usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml`) |
| Acesso root / sudo | O script precisa criar swap, ajustar `sysctl` e ler arquivos de sistema |
| Espaço em disco livre | Recomendado **24 GB+** livres para a área de swap (ver [Riscos Conhecidos](#riscos-conhecidos)) |
| RAM | Funciona com 8 GB+, mas quanto menos RAM, maior a dependência do swap e mais lento o scan |

Instalação dos pacotes necessários:

```bash
sudo dnf install -y openscap-scanner scap-security-guide
```

### Na máquina de controle (se for usar Ansible)

| Requisito | Detalhe |
|---|---|
| `ansible-core` | Versão 2.14+ recomendada |
| Acesso SSH | Chave SSH já configurada para os servidores do inventário |
| Sudo nos hosts remotos | O usuário SSH precisa conseguir `sudo` sem interação manual de senha (ou usar `--ask-become-pass`) |

```bash
pip install ansible-core --user
# ou, em ambientes RHEL/Fedora:
sudo dnf install -y ansible-core
```

---

## Como funciona

O OpenSCAP, por padrão, mantém **todos os resultados do scan na memória**
até o processo terminar. Em servidores com muitos arquivos (containers,
agentes de monitoramento, múltiplas aplicações), algumas regras específicas
do CIS Benchmark — principalmente as que verificam propriedade de arquivos
em todo o sistema de arquivos — fazem esse consumo de memória explodir,
levando o `oscap` a ser interrompido pelo OOM Killer antes de concluir.

Este toolkit mitiga isso com uma combinação de três técnicas:

1. **Swap de segurança** — cria (ou reaproveita) uma área de swap dedicada,
   como margem de segurança para picos de consumo de memória.
2. **Split do datastream** (`oscap ds sds-split`) — separa o pacote SSG
   (que inclui XCCDF, OVAL, OCIL e dicionário CPE) em componentes
   individuais antes da avaliação.
3. **Referência explícita ao dicionário CPE** (`--cpe`) — necessária ao usar
   o XCCDF separado de forma standalone; sem isso, o `oscap` não consegue
   confirmar a plataforma (RHEL 9) e **todas as regras retornam
   `notselected` silenciosamente, sem nenhum erro visível** — o scan parece
   ter funcionado (termina rápido, sem travar) mas não avalia nada de
   fato. Esse foi o bug mais traiçoeiro encontrado durante o
   desenvolvimento deste toolkit.

O script gera o resultado em XML (`resultado-cis.xml`) — que é o dado
completo e estruturado — e tenta gerar também um relatório em HTML como
conveniência visual. A geração do HTML é tratada como **melhor esforço**:
ver [Riscos Conhecidos](#riscos-conhecidos) para entender por que ela pode
falhar mesmo quando o scan em si funcionou perfeitamente.

---

## Uso rápido (um servidor)

```bash
chmod +x scripts/run-cis-scan.sh
sudo ./scripts/run-cis-scan.sh /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml
```

Saída gerada em `/root/cis-scan/<hostname>-<timestamp>/`:
- `resultado-cis.xml` — resultado completo e estruturado (sempre gerado se o
  scan terminar sem erro fatal)
- `relatorio-cis-baseline.html` — relatório visual (gerado em melhor
  esforço; pode não existir, ver Riscos Conhecidos)
- `report-generation.log` — detalhes do erro, caso o HTML não tenha sido
  gerado

O script é **idempotente**: pode ser executado várias vezes no mesmo
servidor sem duplicar configuração de swap ou `sysctl`.

---

## Uso em escala (Ansible)

1. Copie o inventário de exemplo e ajuste para o seu ambiente:

```bash
cp ansible/inventory.example.ini ansible/inventory.ini
# edite ansible/inventory.ini com os hosts reais do seu ambiente
```

2. Teste em **um único servidor** antes de escalar:

```bash
cd ansible
ansible-playbook -i inventory.ini playbook-cis-scan.yml \
  -e "ds_path=/usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml" \
  --limit nome-do-servidor-de-teste
```

3. Depois de validar, rode no grupo inteiro:

```bash
ansible-playbook -i inventory.ini playbook-cis-scan.yml \
  -e "ds_path=/usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml"
```

Por padrão, o playbook usa `serial: 3` — ou seja, no máximo 3 servidores
rodam o scan **simultaneamente**, mesmo que o grupo tenha muito mais hosts.
Isso evita gerar vários picos de memória ao mesmo tempo na sua infraestrutura.
Ajuste esse valor em `playbook-cis-scan.yml` conforme a capacidade do seu
ambiente.

Os resultados de cada host são copiados automaticamente para
`ansible/resultados-cis/<hostname>/` no controlador — não é necessário
acessar cada servidor manualmente para coletar os arquivos.

---

## Riscos conhecidos

### 1. Geração do relatório HTML pode falhar (`growing nodeset hit limit`)

Em servidores com grande volume de arquivos, a geração do relatório HTML
pode falhar com o erro:

```
XPath error : Memory allocation failed : growing nodeset hit limit
```

Esse é um **bug documentado** na combinação OpenSCAP + libxml2, catalogado
pela Red Hat ([artigo de suporte](https://access.redhat.com/articles/6999111))
e pelo projeto OpenSCAP
([issue #2099](https://github.com/OpenSCAP/openscap/issues/2099)). Ele
ocorre na fase de **geração do relatório**, não na avaliação em si — ou
seja, **o `resultado-cis.xml` permanece válido e completo** mesmo quando o
HTML falha. O script trata isso como não-fatal por esse motivo.

### 2. Duas regras específicas podem causar OOM mesmo com as mitigações

As regras a seguir varrem recursivamente todo o sistema de arquivos e são
conhecidas por consumir memória de forma desproporcional ao consolidar o
resultado, podendo levar a OOM mesmo com swap configurado:

- `xccdf_org.ssgproject.content_rule_no_files_unowned_by_user`
  ("Ensure All Files Are Owned by a User")
- `xccdf_org.ssgproject.content_rule_file_permissions_ungroupowned`
  ("Ensure All Files Are Owned by a Group")

Referências: [Red Hat RHEL-73012](https://access.redhat.com/articles/6999111),
[OpenSCAP issue #1588](https://github.com/OpenSCAP/openscap/issues/1588)
(memory leak confirmado no probe de arquivos).

**Mitigação recomendada:** use o tailoring file de exemplo em
`examples/tailoring-cis-server-l1-no-fileperms.xml`, que desabilita essas
duas regras do perfil, mantendo todas as outras intactas. Avalie essas duas
regras separadamente — manualmente, ou com uma execução isolada e dedicada,
fora do scan em massa.

```bash
cd /caminho/para/ssg-split/   # pasta gerada pelo split do datastream

sudo oscap xccdf eval \
  --profile xccdf_org.ssgproject.content_profile_cis_server_l1_no_fileperms \
  --tailoring-file /caminho/para/tailoring-cis-server-l1-no-fileperms.xml \
  --cpe scap_org.open-scap_cref_ssg-rhel9-cpe-dictionary.xml \
  --results resultado-cis.xml \
  scap_org.open-scap_cref_ssg-rhel9-xccdf.xml
```

> O nome exato dos arquivos gerados pelo split pode variar entre versões do
> `scap-security-guide`. Sempre confirme com `ls` antes de rodar o comando
> acima — o script `run-cis-scan.sh` já faz essa detecção automaticamente.

### 3. Consumo de memória ainda alto mesmo com as mitigações

Mesmo com swap e split, o scan completo do perfil L1 pode consumir
**25–30 GB de memória** (RAM + swap combinados) em servidores com bastante
conteúdo no filesystem. Dimensione a swap de acordo:

| RAM física | Swap recomendado |
|---|---|
| 8 GB | 24 GB+ (scan pode ser bem lento) |
| 16 GB | 16–24 GB |
| 30 GB+ | 8–24 GB (normalmente suficiente) |

Se mesmo assim o processo for interrompido por OOM, considere processar o
scan em sub-lotes de regras (dividindo o perfil em grupos menores via
tailoring file) em vez de avaliar o perfil completo de uma vez.

### 4. O script modifica configuração persistente do sistema

O script cria `/swapfile` (persistido em `/etc/fstab`) e ajusta
`vm.swappiness` permanentemente em `/etc/sysctl.conf`. Essas mudanças
**não são revertidas automaticamente**. Em ambientes com change control,
considere essas alterações como parte do escopo a ser aprovado antes da
execução em produção.

---

## Solução de problemas

| Sintoma | Causa provável | Solução |
|---|---|---|
| Scan termina em menos de 1 segundo, tudo `notselected` | Faltou `--cpe` ao avaliar XCCDF separado por `sds-split` | Use o `run-cis-scan.sh`, que já inclui essa referência automaticamente |
| Processo morto, `dmesg` mostra `Out of memory: Killed process ... (oscap)` | Memória insuficiente para o volume de regras/arquivos do servidor | Aumente a swap (ver tabela acima) ou use o tailoring file para excluir as regras problemáticas |
| `growing nodeset hit limit` ao gerar o HTML | Bug conhecido do libxml2/OpenSCAP (ver Riscos Conhecidos #1) | Ignore — o XML de resultados já é válido. Use-o diretamente ou analise via ferramenta externa |
| `oscap: option '--fetch-remote-resources' doesn't allow an argument` | Versão do `oscap` não aceita `=false`; a flag deve ser omitida, não negada | Não passe a flag — o comportamento padrão já é não buscar recursos remotos |
| `cp: cannot create regular file '/home/usuario/': Not a directory` | Home do usuário não é o caminho padrão (comum em integrações AD/LDAP) | Confirme o caminho real com `getent passwd <usuario>` antes de copiar arquivos |

---

## Estrutura do repositório

```
cis-scan-toolkit/
├── README.md
├── .gitignore
├── scripts/
│   └── run-cis-scan.sh              # Script principal (1 servidor)
├── ansible/
│   ├── playbook-cis-scan.yml        # Orquestração em escala
│   └── inventory.example.ini        # Exemplo de inventário (copie e ajuste)
└── examples/
    └── tailoring-cis-server-l1-no-fileperms.xml
                                      # Tailoring file que exclui as 2
                                      # regras com bug conhecido de memória
```

---

## Roadmap / ideias de otimização

Pontos abertos para quem quiser evoluir este toolkit:

- [ ] Investigar processamento do perfil em sub-lotes de regras (tailoring
      files menores, executados em sequência) para reduzir o pico de
      memória de forma mais previsível que apenas aumentar swap.
- [ ] Avaliar alternativas ao `oscap` para as duas regras problemáticas de
      ownership de arquivos (ex.: script dedicado com `find` + streaming de
      resultado, em vez de manter tudo em memória).
- [ ] Adicionar modo `--dry-run` ao script para validar pré-requisitos sem
      executar o eval completo.
- [ ] Adicionar trava de execução concorrente (lock file) para evitar dois
      scans simultâneos no mesmo host.
- [ ] Integração opcional de envio do resultado para
      [DefectDojo](https://github.com/DefectDojo/django-DefectDojo) via API.
- [ ] Benchmarks de tempo/memória em diferentes tamanhos de filesystem, para
      dar uma estimativa melhor de dimensionamento de swap.

Contribuições e PRs são bem-vindos.

---

## Licença e referências

Este projeto é disponibilizado sob licença MIT (ver `LICENSE`).

O conteúdo de regras CIS utilizado pelo OpenSCAP vem do
[SCAP Security Guide](https://github.com/ComplianceAsCode/content) (projeto
ComplianceAsCode/Red Hat), sob suas respectivas licenças. Este toolkit não
redistribui esse conteúdo — ele apenas orquestra a ferramenta `oscap` já
instalada no sistema.

- [OpenSCAP](https://www.open-scap.org/)
- [SCAP Security Guide](https://github.com/ComplianceAsCode/content)
- [CIS Benchmarks](https://www.cisecurity.org/cis-benchmarks)
- [Red Hat — OpenSCAP memory-consumption problems](https://access.redhat.com/articles/6999111)
- [OpenSCAP issue #1588 — Memory leak in file probe](https://github.com/OpenSCAP/openscap/issues/1588)
- [OpenSCAP issue #2099 — large file count + HTML report](https://github.com/OpenSCAP/openscap/issues/2099)
