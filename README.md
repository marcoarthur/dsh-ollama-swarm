# dsh-ollama-swarm

Setup e diagnóstico do [DeepSeek Harness (DSH)](https://www.npmjs.com/package/@deepseek-ai/dsh) com o plugin [`dsh-swarm-orchestrator`](https://github.com/linkbag/dsh-swarm-orchestrator), rodando modelos **locais via Ollama**, sem API key de nuvem.

O repositório tem duas partes:

- um **Makefile** que instala, configura, verifica e testa o ambiente;
- um **relatório de experimentos** ([`report/experiments.md`](report/experiments.md)) com o que funcionou, o que não funcionou e por quê, sempre separando o que foi medido do que é hipótese.

## Requisitos

- Linux com `node`, `npm`, `pnpm`, `curl` e `jq`
- [Ollama](https://ollama.com) rodando em `http://127.0.0.1:11434` (como serviço systemd, para o `config-ollama`)
- `sensors` (lm-sensors) e, se houver GPU NVIDIA, `nvidia-smi`, para a trava térmica

Versões fixadas no Makefile: DSH `0.2.0-rc.2`, Swarm `0.6.30`, modelo padrão `qwen3.5:9b`.

## Uso rápido

```bash
make setup     # instala, configura, verifica e testa
make start     # DSH Web em http://127.0.0.1:3080, com a trava térmica junto
```

`make help` lista todos os alvos. Os principais:

| Alvo | O que faz |
|---|---|
| `make config` | Fixa o contexto do Ollama (pede sudo só se mudar), escreve o provider e o Roster do Swarm |
| `make verify` | Falha se algo essencial estiver errado: rota, contexto, personas, `toolFilter`, credencial |
| `make test-tools` | Confere se o agente **usa ferramentas**, e não só responde com texto |
| `make clean-workspace` | Arquiva (não apaga) o que runs anteriores deixaram no workspace |
| `make thermal-watch` | Vigia a temperatura; perto do crítico, encerra o Ollama e o DSH |
| `make thermal-bench LABEL=…` | Mede quanto uma geração contínua leva para esquentar a máquina |

## O que se aprendeu

Resumo; os detalhes e as evidências estão no relatório.

- **O Ollama trunca o prompt em silêncio** (§15). Pela API OpenAI-compatible ele ignora o `contextWindow` do DSH e usa o próprio `num_ctx` (padrão 4096). O agente perdia o system prompt, as ferramentas e a tarefa. Correção: `OLLAMA_CONTEXT_LENGTH` no serviço, igual ao `contextWindow` (`make config-ollama`).
- **O snapshot de runtime no fim da conversa faz o modelo responder sobre o ambiente** em vez de agir (§4). Correção: `includeRuntimeContext: false`.
- **`qwen2.5-coder` não serve para agentes** (§14). Ele emite as chamadas de ferramenta como texto, e nada é executado.
- **A janela de 16k enche rápido** (§16). Só os schemas das 33 ferramentas custam ~7k tokens. Uma tarefa grande num único agente não cabe.
- **O `toolFilter` do Swarm não funciona no DSH 0.2.0-rc.2** (§17). Ele tira `read`/`write`/`bash` do agente. O seed do roster remove qualquer filtro.
- **Calor** (§17–§20). Num notebook com RTX 2080 Max-Q, a potência da GPU durante a geração (~88 W) leva a CPU a 85–90 °C em segundos. A trava térmica (`scripts/thermal-guard.sh`) existe por causa disso, e a §20 tem um plano de melhoria com benchmark reprodutível.

## Estrutura

```
Makefile                      instalação, configuração, testes e alvos térmicos
report/experiments.md         relatório dos experimentos (§1–§20)
scripts/seed-swarm-roster.mjs fixa o modelo dos papéis do Swarm e saneia personas e filtros
scripts/thermal-guard.sh      trava térmica: status, check, watch e hook do Claude Code
scripts/thermal-bench.sh      benchmark térmico reprodutível (protocolo da §18)
.claude/settings.json         hook do Claude Code que encerra o turno com a máquina quente
```

## Avisos

- Os caminhos padrão (`~/.dsh`, `~/Documents/dsh`) e os limites térmicos (CPU 90 °C, GPU 85 °C) refletem a máquina onde isto foi feito. Ajuste as variáveis no topo do Makefile.
- O `make clean` remove o plugin Swarm e os blocos de configuração que o Makefile gerencia. As outras entradas do perfil são preservadas.
