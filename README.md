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
- **Calor** (§17–§20, §24). Num notebook com RTX 2080 Max-Q, a potência da GPU durante a geração (~88 W) leva a CPU a 85–90 °C em segundos. Limite de potência e trava de clock na GPU não resolveram (§18). A trava térmica (`scripts/thermal-guard.sh`) existe por causa disso, e a §20 tem um plano de melhoria com benchmark reprodutível. Mesmo com a trava em 90 °C e leitura a cada 2 s, a CPU chegou a 100 °C uma vez (§24).
- **`qwen3.5:9b` × `granite4.1:8b`** (§22–§23). O Qwen cabe inteiro na GPU a 16k (KV de 512 MiB, arquitetura híbrida) e gera ~37 tok/s em sessões reais. O Granite precisa de 2,5 GB de KV a 16k, põe 5 camadas na CPU e gera ~7 tok/s. Recomendação aplicada: Qwen em todos os papéis, sem fallback.
- **Colibri não substitui o DSH** (§21). É um motor de inferência, no lugar do Ollama. Os modelos dele com tool calling pedem mais RAM do que esta máquina tem.
- **Projetos parecidos** (§25). Nenhum combina DSH + Ollama local + Swarm. O [`dsh-tiny`](https://github.com/VMoonLightV/dsh-tiny) é o mais próximo e trouxe as ideias testadas na §26.
- **Corte das tools do preset** (§26). Reescrever o preset `standard` sem as tools ociosas baixou de 33 para 16 tools e o 1º prompt do agente de 9.614 para 5.471 tokens (−43%), com 0 erros de tool. Aplicado pelo `make config-provider` a partir de [`config/preset-trim.patch.yml`](config/preset-trim.patch.yml); o `make verify` confere.

## Estado atual

**A inferência nesta máquina está suspensa** até a limpeza das ventoinhas e a troca da pasta térmica (§20, itens 2 e 3). Depois de cada passo, `make thermal-bench LABEL=<passo>` compara com a referência da §20.3. Os próximos testes de configuração estão na §26.5.

## Estrutura

```
Makefile                      instalação, configuração, testes e alvos térmicos
report/experiments.md         relatório dos experimentos (§1–§26)
config/preset-trim.patch.yml  corte das tools do preset standard (§26)
scripts/seed-swarm-roster.mjs fixa o modelo dos papéis do Swarm e saneia personas e filtros
scripts/thermal-guard.sh      trava térmica: status, check, watch e hook do Claude Code
scripts/thermal-bench.sh      benchmark térmico reprodutível (protocolo da §18)
.claude/settings.json         hook do Claude Code que encerra o turno com a máquina quente
```

## Avisos

- Os caminhos padrão (`~/.dsh`, `~/Documents/dsh`) e os limites térmicos (CPU 90 °C, GPU 85 °C) refletem a máquina onde isto foi feito. Ajuste as variáveis no topo do Makefile.
- O `make clean` remove o plugin Swarm e os blocos de configuração que o Makefile gerencia. As outras entradas do perfil são preservadas.
