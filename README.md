# swizzin-toolkit

Toolkit completo de **tuning e backup** para servidores [swizzin](https://github.com/swizzin/swizzin), com auto-detecção de hardware e suporte a múltiplos usuários.

## Funcionalidades

- **Tuning automático** — detecta RAM, CPU, tipo de disco (NVMe/SSD/HDD) e velocidade de rede, aplicando parâmetros otimizados para cada perfil
- **Tuning manual** — sobrescreva qualquer parâmetro detectado via flags ou menu interativo
- **Dry-run** — visualize todas as mudanças antes de aplicar, sem tocar em nada
- **Backup e restore** — todos os clientes torrent e Plex, com múltiplos usuários, manifesto JSON e retenção automática
- **Integração com swizzin** — detecta lock files, enumera usuários e pode substituir os scripts `box tune` / `box backup`
- **Standalone** — funciona sem swizzin instalado

### O que é tunado

| Componente | O que muda |
|---|---|
| **Kernel** | `sysctl`: descritores de arquivo, swappiness, dirty ratios, PID max |
| **Rede** | Buffers TCP/UDP adaptativos a RAM + link, BBR congestion control, port range |
| **Disco** | I/O scheduler (`none` NVMe / `mq-deadline` SSD / `bfq` HDD), readahead, regra udev persistente |
| **rTorrent** | `max_peers`, `max_uploads`, `preload_min_rate` (por tipo de disco), buffers de rede |
| **qBittorrent** | Conexões, cache de disco, async I/O threads (multiplicador por disco), file pool, filas ativas |
| **Deluge** | Conexões, upload slots, cache, limites ativos por disco, `peer_tos` |
| **Transmission** | Peers, upload slots, cache, preallocation (full para HDD), filas de download/seed |
| **Plex** | `Nice=-5`, `IOSchedulingClass`, threads de transcoder, limite de memória, `LimitNOFILE` |

### Perfis de recursos

| Perfil | RAM | Exemplo: qBt conexões | Exemplo: buffer de rede |
|---|---|---|---|
| **Light** | < 4 GB | 200 | 16 MB |
| **Medium** | 4–16 GB | 500 | 64 MB |
| **Heavy** | > 16 GB | 1000 | 128–256 MB |

Os buffers de rede combinam RAM **e** velocidade do link (ex: link 10 GbE + perfil heavy → 256 MB).

---

## Instalação

```bash
git clone https://github.com/seu-usuario/swizzin-toolkit
cd swizzin-toolkit
sudo bash install.sh
```

`install.sh` instala em `/opt/swizzin-toolkit`, cria o symlink `/usr/local/bin/toolkit` e opcionalmente integra com o `box` do swizzin.

### Requisitos

- Bash 4.4+
- Python 3 (para tuning de Deluge e Transmission)
- Debian 11/12 ou Ubuntu 20.04/22.04/24.04 (recomendado)
- `root` para tuning de kernel/disco e backup do Plex

---

## Uso

### Modo interativo

```bash
toolkit
```

Abre o menu principal (whiptail se disponível, `select` como fallback).

### CLI

```bash
# Tuning
toolkit tune --auto --target all
toolkit tune --dry-run --target all          # visualiza, não aplica
toolkit tune --manual --profile heavy --disk-type NVME
toolkit tune --auto --target kernel,network  # só kernel e rede

# Backup
toolkit backup --target all
toolkit backup --target rtorrent,plex
toolkit backup --target all --user alice     # só usuário alice

# Restore
toolkit restore                              # menu interativo
toolkit restore --file /root/swizzin-toolkit-backups/20260310_143022/rtorrent_alice.tar.gz
toolkit restore --target rtorrent --user alice

# Listar backups
toolkit list
toolkit list --app plex

# Rollback do tuning
toolkit rollback
toolkit rollback --timestamp 20260310_143022

# Status do sistema
toolkit status
```

### Flags disponíveis para `tune`

| Flag | Descrição |
|---|---|
| `--auto` | Auto-detecta hardware (padrão) |
| `--manual` | Permite sobrescrever manualmente |
| `--dry-run` | Mostra o que seria feito, não aplica nada |
| `--yes` | Pula confirmações |
| `--target TARGETS` | Alvos separados por vírgula (padrão: `all`) |
| `--profile light\|medium\|heavy` | Sobrescreve o perfil detectado |
| `--disk-type NVME\|SSD\|HDD` | Sobrescreve o tipo de disco |
| `--ram GB` | Sobrescreve a RAM em GB |
| `--net-speed Mbps` | Sobrescreve a velocidade do link |

---

## Backup

Os backups são armazenados em `/root/swizzin-toolkit-backups/` com a estrutura:

```
/root/swizzin-toolkit-backups/
└── 20260310_143022/              ← sessão (timestamp)
    ├── manifest.json             ← metadados da sessão
    ├── rtorrent_alice.tar.gz
    ├── rtorrent_bob.tar.gz
    ├── qbittorrent_alice.tar.gz
    ├── deluge_alice.tar.gz
    ├── transmission_alice.tar.gz
    └── plex_system.tar.gz        ← backup completo do Plex
```

**Retenção:** por padrão, mantém os últimos 10 backups por app/usuário. Configurável via `BACKUP_RETENTION_COUNT`.

**Plex:** o backup exclui `Cache/`, `Logs/` e `Crash Reports/` para reduzir tamanho.

---

## Configuração

Edite `/etc/swizzin-toolkit/defaults.conf` (criado pelo `install.sh`) para sobrescrever padrões:

```bash
TOOLKIT_BACKUP_ROOT="/root/swizzin-toolkit-backups"
BACKUP_RETENTION_COUNT=10
PLEX_DATA_PATH="/var/lib/plexmediaserver/Library/Application Support/Plex Media Server"
TOOLKIT_LOG="/var/log/swizzin-toolkit.log"
```

Ou exporte variáveis antes de chamar `toolkit`:

```bash
BACKUP_RETENTION_COUNT=20 toolkit backup --target all
```

---

## Integração com swizzin

Quando swizzin está instalado, o `install.sh` oferece substituir os scripts `box tune` e `box backup` por wrappers que chamam este toolkit. Os originais são preservados como `.bak.*`.

A detecção de apps usa o método canônico do swizzin (lock files em `/install/`), com fallback para systemd e binários.

---

## Testes

```bash
bash tests/run_tests.sh
```

Os testes usam `DRY_RUN=true` e diretórios temporários — seguros para rodar em qualquer ambiente, inclusive produção.

```
── Hardware Detection ──
  [PASS] detect_ram_gb returns a value
  [PASS] detect_cpu_cores returns positive integer
  [PASS] detect_disk_type returns valid value (got: SSD)
  ...
── Tuning Dry-Run ──
  [PASS] tune_kernel: sysctl file not written in dry-run
  [PASS] tune_disk: udev rule not written in dry-run
  ...
── Backup & Restore ──
  [PASS] create_backup_session creates directory
  [PASS] verify_archive returns 0 for valid archive
  [PASS] enforce_retention keeps at most 10 backups
  ...
```

---

## Estrutura do projeto

```
swizzin-toolkit/
├── toolkit.sh              # CLI principal
├── install.sh              # Instalador
├── uninstall.sh            # Desinstalador
├── conf/
│   └── defaults.conf       # Configurações padrão
├── lib/
│   ├── core/               # colors, hardware, swizzin, utils
│   ├── tune/               # kernel, network, disk, rtorrent, qbittorrent,
│   │                       # deluge, transmission, plex, tune (orchestrator)
│   ├── backup/             # engine, rtorrent, qbittorrent, deluge,
│   │                       # transmission, plex
│   └── ui/                 # menu, tune_menu, backup_menu
└── tests/
    ├── run_tests.sh
    ├── test_hardware.sh
    ├── test_swizzin.sh
    ├── test_tune_dry_run.sh
    └── test_backup.sh
```

---

## Rollback

Todo tuning salva um snapshot em `/root/swizzin-toolkit-backups/.tuning/TIMESTAMP/` antes de aplicar. Para desfazer:

```bash
toolkit rollback              # desfaz o último tuning
toolkit rollback --timestamp 20260310_143022
```

O rollback restaura: arquivo sysctl, regra udev (disco) e override do Plex. Configs de apps torrent são restauradas via `toolkit restore`.

---

## Desinstalação

```bash
sudo bash uninstall.sh
```

Remove o toolkit, sysctl config, regra udev e override do Plex. **Seus backups não são apagados.**

---

## Licença

GPL-3.0 — veja [LICENSE](LICENSE).
