# ============================================================
# Makefile — DSH + dsh-swarm-orchestrator + Ollama local
# ============================================================
# Política de versão:
#   DSH_VERSION   = versão exata do DSH a instalar (reprodutível)
#   SWARM_VERSION = versão exata do Swarm a instalar (reprodutível)
# Para acompanhar rolling, use DSH_VERSION=latest
# ============================================================
#
# COMO A CONFIGURAÇÃO FUNCIONA (DSH >= 0.2.0-rc.2)
# -------------------------------------------------
# O DSH não lê mais ~/.dsh/settings.yaml. Cada perfil compõe sua
# árvore a partir de camadas de patch e a camada do usuário é
# $DSH_HOME/profiles/<perfil>/cordis.patch.yml — é esse o documento
# que a página Settings → Models escreve e lê.
#
# Três peças dão o ambiente local:
#   1. llm-pi-ai.providers.ollama  → registra a rota "ollama"
#      (baseURL da API OpenAI-compatible + o catálogo de modelos).
#      Sem isso o adaptador fica dormente: zero rotas.
#   2. agent-default-model          → o modelo padrão do harness.
#      Sem isso o padrão é o DeepSeek da conta, que exige API key.
#   3. ~/.dsh/.credentials.yaml     → refs: OLLAMA_API_KEY.
#      O pi-ai recusa uma rota openai-completions sem apiKey não
#      vazio ("No API key for provider: ollama"), mesmo servindo
#      Ollama local, que não autentica nada. Guardamos um valor
#      simbólico local; nada disso sai da máquina.
# ============================================================

SHELL := /bin/bash

DSH_PROFILE    := web
DSH_HOME       := $(HOME)/.dsh

# Camada de configuração do usuário, por perfil.
PROFILE_DIR    := $(DSH_HOME)/profiles/$(DSH_PROFILE)
PROFILE_PATCH  := $(PROFILE_DIR)/cordis.patch.yml
HEADLESS_PATCH := $(DSH_HOME)/profiles/headless/cordis.patch.yml

# Documento gerenciado de credenciais.
CREDENTIALS    := $(DSH_HOME)/.credentials.yaml
# Valor simbólico: o Ollama local não autentica, mas o pi-ai exige
# uma credencial não vazia para montar o cabeçalho Authorization.
OLLAMA_KEY     := ollama-local

# Roster do swarm (pin por papel).
SWARM_STORAGE  := $(DSH_HOME)/storages/swarm
DUTY_TABLE     := $(SWARM_STORAGE)/duty-table.json
# Script que semeia o duty-table.json usando o default do próprio
# plugin (o formato é dele, não nosso).
ROSTER_SEED    := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))scripts/seed-swarm-roster.mjs)

OLLAMA_HOST    := http://127.0.0.1:11434
OLLAMA_URL     := $(OLLAMA_HOST)/v1
MODEL          := qwen3.5:9b
MODEL_LABEL    := Qwen3.5 9B
# Modelos adicionais no catálogo do provider (não são o padrão). Ficam
# selecionáveis no Roster. O granite saiu do fallback do Architect: a 16k
# não cabe na RTX 2080 e gera ~5× mais devagar (relatório §23).
# Separados por espaço; o nome exibido é o id.
EXTRA_MODELS   := granite4.1:8b
# Tem que bater com OLLAMA_CONTEXT_LENGTH do serviço ollama: pela API
# OpenAI-compatible o Ollama ignora este valor e usa o próprio num_ctx
# (padrão 4096), truncando o prompt em silêncio. Ver relatório §15.
# `config-ollama` fixa o serviço neste mesmo valor.
CONTEXT_WINDOW := 16384

# Uma entrada de catálogo por modelo extra, já indentada para o bloco.
define NL


endef
EXTRA_MODEL_ENTRIES := $(foreach m,$(EXTRA_MODELS),$(NL)          - id: $(m)$(NL)            name: $(m)$(NL)            contextWindow: $(CONTEXT_WINDOW))

# Drop-in systemd do Ollama gerenciado por este Makefile. O prefixo
# zz- faz ele ser lido por último e prevalecer sobre o override.conf
# que o `systemctl edit` cria.
OLLAMA_UNIT    := ollama
OLLAMA_DROPIN  := /etc/systemd/system/$(OLLAMA_UNIT).service.d/zz-dsh-context.conf

WEB_PORT       := 3080

# Workspace onde os runs do Swarm escrevem, e para onde clean-workspace
# move o conteúdo antigo (nada é apagado).
WORKSPACE      := $(HOME)/Documents/dsh
WS_ARCHIVE     := $(DSH_HOME)/workspace-archive

# Trava térmica (relatório §17): acima destes limites o vigia encerra o
# runner do Ollama e o DSH na hora. CPU crítica = 100 °C; a GPU reduz
# clock em 94 °C.
THERMAL_GUARD  := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))scripts/thermal-guard.sh)
THERMAL_BENCH  := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))scripts/thermal-bench.sh)
CPU_MAX        := 90
GPU_MAX        := 85

# Inferência em CPU usa todos os núcleos: os alvos de teste rodam
# com nice/ionice e nunca em paralelo.
TOOLS_TIMEOUT  := 300

# Marcadores do bloco gerenciado dentro dos cordis.patch.yml.
# O prefixo literal "# >>> dsh-local-llm" também é o padrão de regex
# usado pelo awk de strip — por isso não leva parênteses.
BEGIN_MARK     := \# >>> dsh-local-llm >>>
END_MARK       := \# <<< dsh-local-llm <<<

DSH_VERSION    := 0.2.0-rc.2
SWARM_VERSION  := 0.6.30

.PHONY: help check-prereqs install-dsh ensure-model install-swarm \
        install config-ollama config-provider config-roster config start \
        verify test test-dsh test-tools status clean clean-workspace setup \
        thermal-watch thermal-status thermal-bench

# ------------------------------------------------------------
# Help
# ------------------------------------------------------------
help:
	@echo "Alvos disponíveis:"
	@echo ""
	@echo "  make setup        Instala, configura, verifica e testa"
	@echo "  make install      Instala DSH + Swarm + garante o modelo"
	@echo "  make config       Fixa o contexto do Ollama, escreve o provider e o Roster"
	@echo "  make config-ollama  Fixa OLLAMA_CONTEXT_LENGTH=$(CONTEXT_WINDOW) (sudo se mudar)"
	@echo "  make start        Inicia o DSH Web em http://127.0.0.1:$(WEB_PORT) com a trava térmica"
	@echo "  make thermal-watch  Vigia a temperatura; acima de CPU $(CPU_MAX)°C / GPU $(GPU_MAX)°C mata Ollama e DSH"
	@echo "  make thermal-status Mostra as temperaturas e os limites"
	@echo "  make thermal-bench  Mede o aquecimento numa geração (LABEL=antes-limpeza etc.)"
	@echo "  make verify       Verifica instalação (falha se algo essencial faltar)"
	@echo "  make test         Testa geração via API OpenAI-compatible"
	@echo "  make test-tools   Testa se o agente USA ferramentas (1 exec, nice)"
	@echo "  make test-dsh     Testa integração DSH → llm-pi-ai → Ollama"
	@echo "  make status       Mostra estado do ambiente"
	@echo "  make clean        Remove o plugin Swarm e a configuração local"
	@echo "  make clean-workspace  Arquiva o conteúdo de $(WORKSPACE) (YES=1 sem perguntar)"
	@echo ""
	@echo "Variáveis:"
	@echo "  DSH_VERSION=$(DSH_VERSION)  SWARM_VERSION=$(SWARM_VERSION)"
	@echo "  MODEL=$(MODEL)  OLLAMA_URL=$(OLLAMA_URL)"
	@echo ""

# ------------------------------------------------------------
# Pré-requisitos (verificação pura)
# ------------------------------------------------------------
check-prereqs:
	@echo "==> Verificando pré-requisitos..."
	@command -v node >/dev/null 2>&1 || { echo "ERRO: Node.js não encontrado."; exit 1; }
	@command -v npm >/dev/null 2>&1 || { echo "ERRO: npm não encontrado."; exit 1; }
	@command -v pnpm >/dev/null 2>&1 || { echo "ERRO: pnpm não encontrado."; exit 1; }
	@command -v ollama >/dev/null 2>&1 || { echo "ERRO: Ollama não encontrado."; exit 1; }
	@command -v curl >/dev/null 2>&1 || { echo "ERRO: curl não encontrado."; exit 1; }
	@command -v jq >/dev/null 2>&1 || { echo "ERRO: jq não encontrado."; exit 1; }
	@echo "   Node:   $$(node --version)"
	@echo "   pnpm:   $$(pnpm --version)"
	@echo "   Ollama: $$(ollama --version 2>/dev/null | head -1)"
	@echo ""
	@curl -sf "$(OLLAMA_HOST)/api/tags" >/dev/null 2>&1 || { \
		echo "ERRO: Ollama não respondeu em $(OLLAMA_HOST)."; \
		echo "      Inicie com: ollama serve"; exit 1; }
	@echo "==> Pré-requisitos OK."

# ------------------------------------------------------------
# Instalação do DSH (versão fixada)
#
# DSH_VERSION=latest resolve a versão publicada antes de comparar,
# então o alvo continua sendo idempotente no modo rolling.
# ------------------------------------------------------------
install-dsh:
	@echo "==> Verificando DSH..."
	@WANT="$(DSH_VERSION)"; \
	if [ "$$WANT" = "latest" ]; then \
		WANT="$$(npm view @deepseek-ai/dsh version 2>/dev/null)"; \
		if [ -z "$$WANT" ]; then \
			echo "ERRO: não foi possível resolver @deepseek-ai/dsh@latest no npm."; exit 1; \
		fi; \
	fi; \
	CURRENT="$$(dsh --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[a-z0-9.]+)?' | head -1)"; \
	if [ -z "$$CURRENT" ]; then \
		echo "   → Instalando @deepseek-ai/dsh@$$WANT..."; \
		npm install -g "@deepseek-ai/dsh@$$WANT" || { \
			echo "ERRO: falha ao instalar o DSH."; exit 1; }; \
	elif [ "$$CURRENT" = "$$WANT" ]; then \
		echo "   DSH $$CURRENT instalado. OK."; \
	else \
		echo "   DSH $$CURRENT encontrado, mas o desejado é $$WANT."; \
		echo "   → Atualizando..."; \
		npm install -g "@deepseek-ai/dsh@$$WANT" || { \
			echo "ERRO: falha ao atualizar o DSH."; exit 1; }; \
	fi

# ------------------------------------------------------------
# Garantir o modelo (fatal em caso de falha)
# ------------------------------------------------------------
ensure-model:
	@echo "==> Verificando modelo $(MODEL)..."
	@if ! ollama list 2>/dev/null \
		| awk 'NR > 1 {print $$1}' \
		| grep -Fxq "$(MODEL)"; then \
		echo "   Baixando $(MODEL)..."; \
		ollama pull "$(MODEL)" || { echo "ERRO: Falha ao baixar $(MODEL)."; exit 1; }; \
	fi
	@echo "==> Modelo OK."

# ------------------------------------------------------------
# Instalação do Swarm (versão fixada, sem fallback)
# ------------------------------------------------------------
install-swarm:
	@echo "==> Verificando dsh-swarm-orchestrator@$(SWARM_VERSION)..."
	@if dsh plugin --profile "$(DSH_PROFILE)" list 2>/dev/null \
		| grep -qE "^dsh-swarm-orchestrator $(SWARM_VERSION)$$"; then \
		echo "   Swarm $(SWARM_VERSION) instalado. OK."; \
	else \
		echo "   → Instalando..."; \
		dsh plugin --profile "$(DSH_PROFILE)" add -w "dsh-swarm-orchestrator@$(SWARM_VERSION)" || { \
			echo "ERRO: Falha ao instalar dsh-swarm-orchestrator@$(SWARM_VERSION)."; \
			echo "Verifique: npm view dsh-swarm-orchestrator versions"; \
			exit 1; \
		}; \
	fi

# Dependências explícitas para ordem correta
ensure-model: check-prereqs
install: check-prereqs ensure-model install-dsh install-swarm

# ------------------------------------------------------------
# Bloco gerenciado: entra/sai do cordis.patch.yml sem apagar o
# resto das configurações do perfil.
# ------------------------------------------------------------
define MANAGED_BLOCK

- id: llm-pi-ai
  config:
    providers:
      ollama:
        displayName: Ollama
        # O pi-ai exige uma credencial não vazia mesmo para rota local.
        apiKeyEnv: OLLAMA_API_KEY
        api: openai-completions
        baseURL: $(OLLAMA_URL)
        models:
          - id: $(MODEL)
            name: $(MODEL_LABEL)
            contextWindow: $(CONTEXT_WINDOW)$(EXTRA_MODEL_ENTRIES)

- id: agent-default-model
  config:
    provider: ollama
    model: $(MODEL)

# O agent-loop injeta o snapshot de runtime como ÚLTIMA mensagem de
# usuário, ou seja, DEPOIS da tarefa. Medido com as mesmas mensagens e
# as mesmas 24 tools do DSH:
#   [system, TAREFA, contexto] -> finish_reason=stop, tool_calls=[]
#   [system, contexto, TAREFA] -> finish_reason=tool_calls, ["write"]
# Com o snapshot no fim, o modelo responde sobre o ambiente em vez de
# agir. Desligar o snapshot não é-loss: ele só carrega política de
# arquivos, aprovação e fuso — o agente recebe o mesmo resto no system
# prompt.
- id: system-prompt
  config:
    includeRuntimeContext: false
endef
export MANAGED_BLOCK

# Substitui o bloco gerenciado anterior (ou o acrescenta) preservando
# qualquer outra entrada do perfil. Idempotente.
#
# Uso: bash -c "$$PATCH_SCRIPT" _ <arquivo>
define PATCH_SCRIPT
set -euo pipefail
file="$$1"
mkdir -p "$$(dirname "$$file")"
[ -f "$$file" ] || : > "$$file"
kept="$$(awk '/^# >>> dsh-local-llm/{skip=1} /^# <<< dsh-local-llm/{skip=0; next} !skip' "$$file")"
{
	if [ -n "$$kept" ]; then printf '%s\n\n' "$$kept"; fi
	printf '%s\n' '$(BEGIN_MARK)'
	printf '%s\n' "$$MANAGED_BLOCK"
	printf '%s\n' '$(END_MARK)'
} > "$$file.$$$$"
mv "$$file.$$$$" "$$file"
endef
export PATCH_SCRIPT

# ------------------------------------------------------------
# Credencial simbólica do Ollama.
#
# Insere `OLLAMA_API_KEY` na seção `refs:` de
# $DSH_HOME/.credentials.yaml sem duplicar a chave e sem tocar
# em `records:`. Cria o arquivo se ainda não existir.
#
# Uso: bash -c "$$CRED_SCRIPT" _ <arquivo> <valor>
define CRED_SCRIPT
set -euo pipefail
file="$$1"
value="$$2"
mkdir -p "$$(dirname "$$file")"

if [ ! -f "$$file" ]; then
	printf 'version: 1\nrefs:\n  OLLAMA_API_KEY: %s\n' "$$value" > "$$file"
	echo "criado"
	exit 0
fi

if grep -qE '^[[:space:]]+OLLAMA_API_KEY:' "$$file"; then
	echo "ja-existe"
	exit 0
fi

tmp="$$(mktemp)"
if grep -qE '^refs:' "$$file"; then
	# Já existe uma seção refs: — acrescenta a chave logo abaixo dela.
	awk -v v="$$value" '
		{ print }
		/^refs:/ && !d { print "  OLLAMA_API_KEY: " v; d = 1 }
	' "$$file" > "$$tmp"
else
	# Sem seção refs: — cria logo após a linha version:.
	awk -v v="$$value" '
		{ print }
		/^version:/ && !d { print ""; print "refs:"; print "  OLLAMA_API_KEY: " v; d = 1 }
		END { if (!d) { print "version: 1"; print "refs:"; print "  OLLAMA_API_KEY: " v } }
	' "$$file" > "$$tmp"
fi
mv "$$tmp" "$$file"
echo "adicionada"
endef
export CRED_SCRIPT

# ------------------------------------------------------------
# Contexto do Ollama: OLLAMA_CONTEXT_LENGTH = CONTEXT_WINDOW
#
# Sem isso o Ollama carrega o modelo com o num_ctx padrão (4096 numa
# GPU de 8 GB) e trunca o prompt pelo início: o agente perde o system
# prompt, os schemas das tools e a tarefa (relatório §15.2).
#
# Idempotente: lê o ambiente efetivo da unit e só escreve o drop-in
# (com sudo) e reinicia o serviço quando o valor difere. Fora do
# systemd (ex.: `ollama serve` manual) apenas avisa.
# ------------------------------------------------------------
config-ollama:
	@echo "==> Verificando OLLAMA_CONTEXT_LENGTH do serviço $(OLLAMA_UNIT)..."
	@if ! systemctl cat "$(OLLAMA_UNIT)" >/dev/null 2>&1; then \
		echo "   AVISO: unit systemd $(OLLAMA_UNIT) não encontrada."; \
		echo "   Exporte OLLAMA_CONTEXT_LENGTH=$(CONTEXT_WINDOW) antes de 'ollama serve'."; \
		exit 0; \
	fi; \
	if systemctl show "$(OLLAMA_UNIT)" -p Environment --value \
			| tr ' ' '\n' | grep -qx 'OLLAMA_CONTEXT_LENGTH=$(CONTEXT_WINDOW)'; then \
		echo "   OLLAMA_CONTEXT_LENGTH=$(CONTEXT_WINDOW) já ativo. OK."; \
		exit 0; \
	fi; \
	echo "   → Gravando $(OLLAMA_DROPIN) (requer sudo)..."; \
	printf '[Service]\nEnvironment="OLLAMA_CONTEXT_LENGTH=$(CONTEXT_WINDOW)"\n' \
		| sudo install -D -m 0644 /dev/stdin "$(OLLAMA_DROPIN)" || { \
		echo "ERRO: falha ao gravar $(OLLAMA_DROPIN)."; exit 1; }; \
	sudo systemctl daemon-reload && sudo systemctl restart "$(OLLAMA_UNIT)" || { \
		echo "ERRO: falha ao reiniciar $(OLLAMA_UNIT)."; exit 1; }; \
	for i in $$(seq 1 30); do \
		curl -sf "$(OLLAMA_HOST)/api/tags" >/dev/null 2>&1 && break; sleep 1; \
	done; \
	systemctl show "$(OLLAMA_UNIT)" -p Environment --value \
		| tr ' ' '\n' | grep -qx 'OLLAMA_CONTEXT_LENGTH=$(CONTEXT_WINDOW)' || { \
		echo "ERRO: o valor ainda não está ativo; confira 'systemctl cat $(OLLAMA_UNIT)'."; exit 1; }; \
	echo "   OLLAMA_CONTEXT_LENGTH=$(CONTEXT_WINDOW) ativo."

# ------------------------------------------------------------
# Configuração do provider Ollama
#
# Além do patch do perfil, grava a credencial simbólica no
# documento gerenciado $DSH_HOME/.credentials.yaml.
# ------------------------------------------------------------
config-provider:
	@echo "==> Verificando Ollama..."
	@curl -sf "$(OLLAMA_URL)/models" >/dev/null 2>&1 || { \
		echo "ERRO: Ollama não responde em $(OLLAMA_URL)/models"; \
		echo "      O modelo precisa estar servindo em $(OLLAMA_HOST)."; exit 1; }

	@echo "==> Escrevendo o provider Ollama no perfil $(DSH_PROFILE)..."
	@bash -c "$$PATCH_SCRIPT" _ "$(PROFILE_PATCH)"
	@echo "   → $(PROFILE_PATCH)"

	@echo "==> Escrevendo o provider Ollama no perfil headless (usado por test-dsh)..."
	@bash -c "$$PATCH_SCRIPT" _ "$(HEADLESS_PATCH)"
	@echo "   → $(HEADLESS_PATCH)"

	@echo "==> Registrando a credencial local OLLAMA_API_KEY..."
	@mkdir -p "$(dir $(CREDENTIALS))"
	@case "$$(bash -c "$$CRED_SCRIPT" _ "$(CREDENTIALS)" "$(OLLAMA_KEY)")" in \
		*criado*)    echo "   → $(CREDENTIALS) criado." ;; \
		*adicionada*) echo "   → OLLAMA_API_KEY adicionada a $(CREDENTIALS)." ;; \
		*)           echo "   → OLLAMA_API_KEY já registrada." ;; \
	esac
	@echo "==> Provider Ollama configurado."

# ------------------------------------------------------------
# Roster do Swarm: fixa os 4 papéis no modelo local.
#
# Sem este arquivo o Swarm usa o padrão do deployment — que já é
# o Ollama. Mas fixar explicitamente garante que Architect /
# Builder / Reviewer / Integrator continuem locais mesmo que o
# modelo padrão da sessão mude.
#
# O seed também restaura ao default do plugin qualquer persona que
# mande passar `sandbox_permissions` (relatório §15.4).
#
# Recusa rodar com o DSH no ar: o serviço do Swarm mantém o duty
# table em memória e sobrescreve o arquivo no próximo save do
# dashboard, desfazendo a edição.
# ------------------------------------------------------------
config-roster:
	@echo "==> Fixando o Roster do Swarm em ollama / $(MODEL)..."
	@if ! dsh plugin --profile "$(DSH_PROFILE)" list 2>/dev/null \
			| grep -q 'dsh-swarm-orchestrator'; then \
		echo "   AVISO: Swarm não instalado; Roster pulado."; \
		exit 0; \
	fi; \
	if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$(WEB_PORT)/"; then \
		echo "ERRO: o DSH está rodando em :$(WEB_PORT). Pare-o e rode de novo —"; \
		echo "      com ele no ar a edição do duty table seria sobrescrita."; \
		exit 1; \
	fi; \
	node "$(ROSTER_SEED)" "$(DUTY_TABLE)" ollama "$(MODEL)"
	@echo "   → $(DUTY_TABLE)"

config: config-ollama config-provider config-roster

# ------------------------------------------------------------
# Start
#
# Nenhuma variável de ambiente é necessária: a credencial do
# Ollama vive em $(CREDENTIALS).
#
# Sobe a trava térmica em paralelo e a derruba quando o DSH sai: este
# notebook passou de 100 °C numa corrida de 16 min (relatório §17).
# ------------------------------------------------------------
start:
	@echo "==> Iniciando DSH Web..."
	@echo "    http://127.0.0.1:$(WEB_PORT)"
	@echo "    trava térmica: CPU $(CPU_MAX)°C · GPU $(GPU_MAX)°C (log em $(DSH_HOME)/thermal-guard.log)"
	@echo ""
	@CPU_MAX=$(CPU_MAX) GPU_MAX=$(GPU_MAX) "$(THERMAL_GUARD)" watch & guard=$$!; \
	trap 'kill $$guard 2>/dev/null' EXIT INT TERM; \
	dsh web --port $(WEB_PORT)

# ------------------------------------------------------------
# Trava térmica avulsa (para experimentos rodados fora do make start)
# ------------------------------------------------------------
thermal-watch:
	@CPU_MAX=$(CPU_MAX) GPU_MAX=$(GPU_MAX) "$(THERMAL_GUARD)" watch

thermal-status:
	@CPU_MAX=$(CPU_MAX) GPU_MAX=$(GPU_MAX) "$(THERMAL_GUARD)" status

# Protocolo da §18, para comparar antes/depois de cada melhoria física
# (§20). Rode com `make thermal-watch` aberto em outro terminal.
thermal-bench:
	@MODEL="$(MODEL)" NUM_CTX="$(CONTEXT_WINDOW)" OLLAMA_HOST="$(OLLAMA_HOST)" \
		LABEL="$(or $(LABEL),bench)" "$(THERMAL_BENCH)"

# ------------------------------------------------------------
# Verify — retorna erro se algo essencial falhar
# ------------------------------------------------------------
verify:
	@echo "==> Verificando instalação..."
	@ok=1; \
	command -v dsh >/dev/null 2>&1 || { echo "   ERRO: dsh não encontrado"; ok=0; }; \
	command -v ollama >/dev/null 2>&1 || { echo "   ERRO: ollama não encontrado"; ok=0; }; \
	ollama list 2>/dev/null | awk 'NR > 1 {print $$1}' \
		| grep -Fxq "$(MODEL)" \
		|| { echo "   ERRO: $(MODEL) não encontrado"; ok=0; }; \
	curl -sf "$(OLLAMA_URL)/models" >/dev/null 2>&1 \
		|| { echo "   ERRO: Ollama API indisponível"; ok=0; }; \
	dsh plugin --profile "$(DSH_PROFILE)" list 2>/dev/null \
		| grep -q 'dsh-swarm-orchestrator' \
		|| { echo "   ERRO: Swarm não instalado"; ok=0; }; \
	for f in "$(PROFILE_PATCH)" "$(HEADLESS_PATCH)"; do \
		test -f "$$f" || { echo "   ERRO: $$f não encontrado"; ok=0; }; \
		grep -q 'id: llm-pi-ai' "$$f" 2>/dev/null \
			|| { echo "   ERRO: rota ollama ausente em $$f"; ok=0; }; \
		grep -q "baseURL: $(OLLAMA_URL)" "$$f" 2>/dev/null \
			|| { echo "   ERRO: baseURL do Ollama ausente em $$f"; ok=0; }; \
		grep -q "model: $(MODEL)" "$$f" 2>/dev/null \
			|| { echo "   ERRO: modelo padrão ausente em $$f"; ok=0; }; \
		grep -q "contextWindow: $(CONTEXT_WINDOW)" "$$f" 2>/dev/null \
			|| { echo "   ERRO: contextWindow $(CONTEXT_WINDOW) ausente em $$f"; ok=0; }; \
	done; \
	if systemctl cat "$(OLLAMA_UNIT)" >/dev/null 2>&1; then \
		systemctl show "$(OLLAMA_UNIT)" -p Environment --value \
			| tr ' ' '\n' | grep -qx 'OLLAMA_CONTEXT_LENGTH=$(CONTEXT_WINDOW)' \
			|| { echo "   ERRO: OLLAMA_CONTEXT_LENGTH=$(CONTEXT_WINDOW) não ativo no serviço $(OLLAMA_UNIT) (prompt será truncado; rode make config-ollama)"; ok=0; }; \
	else \
		echo "   AVISO: sem unit systemd $(OLLAMA_UNIT); confira OLLAMA_CONTEXT_LENGTH à mão"; \
	fi; \
	grep -qE '^[[:space:]]+OLLAMA_API_KEY:' "$(CREDENTIALS)" 2>/dev/null \
		|| { echo "   ERRO: OLLAMA_API_KEY ausente de $(CREDENTIALS)"; ok=0; }; \
	test -f "$(ROSTER_SEED)" \
		|| { echo "   ERRO: $(ROSTER_SEED) não encontrado"; ok=0; }; \
	for f in "$(PROFILE_PATCH)" "$(HEADLESS_PATCH)"; do \
		grep -q 'includeRuntimeContext: false' "$$f" 2>/dev/null \
			|| { echo "   ERRO: includeRuntimeContext: false ausente em $$f (o agente fica só em texto)"; ok=0; }; \
	done; \
	if [ -f "$(DUTY_TABLE)" ]; then \
		jq -e --arg m "$(MODEL)" '[.roles | to_entries[]? | select(.key | test("^(architect|builder|reviewer|integrator)$$")) | select(.value.provider == "ollama" and .value.model == $$m) | select(.value.fallbacks | type == "array")] | length == 4' "$(DUTY_TABLE)" >/dev/null 2>&1 \
			|| { echo "   ERRO: Roster do Swarm não fixado em ollama/$(MODEL) em $(DUTY_TABLE)"; ok=0; }; \
		jq -e '[.roles[]?.persona // "" | select(contains("sandbox_permissions"))] | length == 0' "$(DUTY_TABLE)" >/dev/null 2>&1 \
			|| { echo "   ERRO: persona do Swarm manda passar sandbox_permissions (rode make config-roster)"; ok=0; }; \
		jq -e '[.roles[]? | select(.toolFilter != null)] | length == 0' "$(DUTY_TABLE)" >/dev/null 2>&1 \
			|| { echo "   ERRO: papel do Swarm com toolFilter — no DSH 0.2.0-rc.2 isso tira read/write/bash do agente (relatório §17; rode make config-roster)"; ok=0; }; \
	else \
		echo "   AVISO: Roster do Swarm ausente (usa o padrão do deployment)"; \
	fi; \
	dsh --profile "$(DSH_PROFILE)" --dump-config >/dev/null 2>&1 \
		|| { echo "   ERRO: o DSH não consegue carregar o perfil $(DSH_PROFILE)"; ok=0; }; \
	if [ $$ok -eq 1 ]; then \
		echo "==> Verificação OK."; \
		echo "   Rota:    ollama/$(MODEL)"; \
		echo "   Default: ollama/$(MODEL)"; \
		echo "   Roster:  architect/builder/reviewer/integrator → ollama/$(MODEL)"; \
		echo "   Contexto: $(CONTEXT_WINDOW) (DSH e Ollama)"; \
	else \
		echo "==> Verificação FALHOU."; \
		exit 1; \
	fi

# ------------------------------------------------------------
# Test: geração via API OpenAI-compatible (Ollama puro)
# ------------------------------------------------------------
test:
	@echo "==> Testando geração via $(OLLAMA_URL)/chat/completions..."
	@response=$$(curl -fsS "$(OLLAMA_URL)/chat/completions" \
		-H "Content-Type: application/json" \
		-d '{"model":"$(MODEL)","messages":[{"role":"user","content":"Responda com exatamente uma palavra: OK"}],"max_tokens":2048}') || { \
		echo "ERRO: chamada ao Ollama falhou."; exit 1; }; \
	content=$$(echo "$$response" | jq -r '.choices[0].message.content // empty'); \
	reasoning=$$(echo "$$response" | jq -r '.choices[0].message.reasoning // empty'); \
	result="$$content"; \
	if [ -z "$$result" ]; then \
		result="$$reasoning"; \
	fi; \
	if [ -z "$$result" ]; then \
		echo "ERRO: resposta não contém conteúdo nem reasoning."; \
		echo "$$response" | jq .; \
		exit 1; \
	fi; \
	echo "OK: geração realizada."; \
	echo "Resposta: $$result"

# ------------------------------------------------------------
# Test-Tools: o agente USA ferramentas, não só texto.
#
# É o teste que realmente importa: `test` só prova que o Ollama gera
# texto, e `test-dsh` só prova que o harness enxerga o modelo. Nenhum
# dos dois nota quando o modelo responde com prosa em vez de agir.
#
# O critério de sucesso é EFEITO OBSERVÁVEL — o arquivo existir no
# disco. Não conferimos o conteúdo: um 8B em CPU acerta a ferramenta
# e erra o texto, e isso não é falha de tooling.
#
# Uma única execução, sem loop, com nice/ionice e limite de tempo.
# Inferência em CPU satura todos os núcleos e não deve competir com
# o trabalho da máquina. Em caso de falha o diretório é preservado
# para inspeção.
# ------------------------------------------------------------
test-tools:
	@echo "==> Testando uso de ferramentas pelo agente (1 execução, nice)..."
	@dir="$$(mktemp -d)"; \
	( cd "$$dir" && nice -n 19 ionice -c 3 timeout $(TOOLS_TIMEOUT) \
		dsh headless --json \
		"Crie um arquivo chamado nota.txt neste workspace contendo exatamente: ola" \
		> run.jsonl 2>&1 ); \
	calls=$$(jq -r 'select(.type=="tool_call") | .tool' "$$dir/run.jsonl" 2>/dev/null | sort | uniq -c | tr '\n' ' '); \
	if [ -f "$$dir/nota.txt" ]; then \
		echo "OK: o agente chamou ferramentas e criou o arquivo."; \
		echo "   ferramentas chamadas: $${calls:-nenhuma registrada}"; \
		echo "   conteúdo escrito:    $$(cat "$$dir/nota.txt")"; \
		rm -rf "$$dir"; \
	elif [ -n "$$calls" ]; then \
		echo "PARCIAL: o agente chamou ferramentas mas não criou o arquivo."; \
		echo "   ferramentas chamadas: $$calls"; \
		echo "   inspecione: $$dir"; \
		exit 1; \
	elif grep -Eqi 'no api key|missing_credential|no credential|INVALID_CREDENTIAL' "$$dir/run.jsonl" 2>/dev/null; then \
		echo "ERRO: o DSH tentou usar um provedor sem credencial."; \
		echo "   log: $$dir/run.jsonl"; \
		exit 1; \
	else \
		echo "ERRO: o agente NÃO usou ferramentas — respondeu só com texto."; \
		echo "   Causa provável: o snapshot de runtime-context chega como"; \
		echo "   última mensagem de usuário, DEPOIS da tarefa, e o modelo"; \
		echo "   trata isso como o pedido. Confira includeRuntimeContext"; \
		echo "   no bloco gerenciado do patch."; \
		echo "   log: $$dir/run.jsonl"; \
		exit 1; \
	fi

# ------------------------------------------------------------
# Test-DSH: integração completa DSH → llm-pi-ai → Ollama
#
# Usa o modo headless oficial: dsh headless "task"
# O teste afirma que não houve erro de credencial/provedor — o texto
# exato não é conferido, porque um modelo de 8B pode responder
# qualquer coisa.
# ------------------------------------------------------------
test-dsh:
	@echo "==> Testando integração DSH → llm-pi-ai → Ollama..."
	@RESULT=$$(dsh headless "Responda com exatamente uma palavra: OK" 2>&1); \
	if echo "$$RESULT" | grep -Eqi 'no api key|missing_credential|no credential|pi_ai_error|settings-rejected'; then \
		echo "ERRO: o DSH tentou usar um provedor sem credencial."; \
		echo "$$RESULT" | tail -20; \
		exit 1; \
	fi; \
	if [ -z "$$(echo "$$RESULT" | tr -d '[:space:]')" ]; then \
		echo "ERRO: o DSH não produziu nenhuma saída."; exit 1; \
	fi; \
	echo "   Resposta do DSH (primeiras linhas):"; \
	echo "$$RESULT" | grep -v '^$$' | head -6 | cut -c1-160 | sed 's/^/      /'; \
	echo "OK: integração DSH → Ollama funcionando."

# ------------------------------------------------------------
# Status
# ------------------------------------------------------------
status:
	@echo "============================================================"
	@echo "  Status do Ambiente DSH"
	@echo "============================================================"
	@echo ""
	@echo "  DSH profile:   $(DSH_PROFILE)"
	@echo "  DSH home:      $(DSH_HOME)"
	@echo "  Patch perfil:  $(PROFILE_PATCH)"
	@echo "  Patch headless:$(HEADLESS_PATCH)"
	@echo "  Credenciais:  $(CREDENTIALS)"
	@echo "  Roster:        $(DUTY_TABLE)"
	@echo "  Ollama:        $(OLLAMA_URL)"
	@echo "  Modelo:        $(MODEL)"
	@printf "  DSH instalado: "
	@if command -v dsh >/dev/null 2>&1; then \
		dsh --version 2>/dev/null || echo "(versão indisponível)"; \
	else \
		echo "NÃO INSTALADO"; \
	fi
	@echo "  DSH desejado:  $(DSH_VERSION)"
	@echo "  Swarm desejado:$(SWARM_VERSION)"
	@echo ""
	@echo "--- Modelo padrão efetivo ---"
	@dsh --profile "$(DSH_PROFILE)" --dump-config 2>/dev/null \
		| grep -A4 'id: agent-default-model' \
		| grep -E 'provider|model' | sed 's/^ */  /' || echo "  (indisponível)"
	@echo ""
	@echo "--- Modelos Ollama ---"
	@ollama list 2>/dev/null || echo "  (Ollama não disponível)"
	@echo ""
	@echo "--- Plugins DSH (perfil $(DSH_PROFILE)) ---"
	@dsh plugin --profile "$(DSH_PROFILE)" list 2>/dev/null || echo "  (DSH não disponível)"
	@echo ""
	@echo "--- Roster do Swarm ---"
	@if [ -f "$(DUTY_TABLE)" ]; then \
		jq -r '.roles | to_entries[] | "  \(.key): \(.value.provider // "(inherit)")/\(.value.model // "-")"' "$(DUTY_TABLE)"; \
	else \
		echo "  (não fixado — usa o padrão do deployment)"; \
	fi
	@echo ""
	@echo "============================================================"

# ------------------------------------------------------------
# Setup: install → config → verify → test → test-tools → test-dsh
#
# Sequencial de propósito: cada etapa carrega o modelo no Ollama, e
# inferência em CPU satura todos os núcleos.
# ------------------------------------------------------------
setup:
	@$(MAKE) --no-print-directory install
	@$(MAKE) --no-print-directory config
	@$(MAKE) --no-print-directory verify
	@$(MAKE) --no-print-directory test
	@$(MAKE) --no-print-directory test-tools
	@$(MAKE) --no-print-directory test-dsh
	@echo ""
	@echo "============================================================"
	@echo "  DSH + Ollama + Swarm configurados e testados"
	@echo "============================================================"
	@echo ""
	@echo "  Modelo:  ollama / $(MODEL)  (local, sem API key)"
	@echo "  DSH:     http://127.0.0.1:$(WEB_PORT)"
	@echo ""
	@echo "Próximo passo:"
	@echo "  make start"
	@echo ""
	@echo "Depois, na UI: a aba Swarm mostra o board; Settings → AI Swarm"
	@echo "mostra o Roster (architect, builder, reviewer, integrator), já"
	@echo "fixado em ollama/$(MODEL)."
	@echo ""
	@echo "============================================================"

# ------------------------------------------------------------
# Clean-workspace: arquiva o que runs anteriores deixaram no workspace.
#
# Sobras de um run atrapalham o seguinte: o write recusa sobrescrever
# arquivo não lido, e o agente gasta contexto lendo e contornando o
# PLAN.md e os relatórios antigos (relatório §16). Nada é apagado — o
# conteúdo vai para $(WS_ARCHIVE)/<data-hora>/.
# ------------------------------------------------------------
clean-workspace:
	@if [ ! -d "$(WORKSPACE)" ] || [ -z "$$(ls -A "$(WORKSPACE)")" ]; then \
		echo "==> $(WORKSPACE) já está vazio."; exit 0; \
	fi; \
	dest="$(WS_ARCHIVE)/$$(date +%Y%m%d-%H%M%S)"; \
	echo "==> Conteúdo de $(WORKSPACE):"; \
	ls -A "$(WORKSPACE)" | sed 's/^/     /'; \
	echo "   Será movido para $$dest"; \
	if [ "$(YES)" != "1" ]; then \
		read -p "Continuar? [s/N] " -n 1 -r; echo; \
		[[ $$REPLY =~ ^[Ss]$$ ]] || { echo "==> Cancelado."; exit 0; }; \
	fi; \
	mkdir -p "$$dest" && \
	find "$(WORKSPACE)" -mindepth 1 -maxdepth 1 -exec mv -t "$$dest" {} + && \
	echo "==> Workspace limpo; conteúdo arquivado em $$dest"

# ------------------------------------------------------------
# Clean (conservador: remove o plugin e a configuração local)
# ------------------------------------------------------------
clean:
	@echo "ATENÇÃO: isto removerá o plugin Swarm, o roster e os blocos"
	@echo "de configuração local do DSH (as demais entradas do perfil"
	@echo "são preservadas)."
	@read -p "Continuar? [s/N] " -n 1 -r; \
	echo; \
	if [[ $$REPLY =~ ^[Ss]$$ ]]; then \
		dsh plugin --profile "$(DSH_PROFILE)" \
			remove dsh-swarm-orchestrator 2>/dev/null || true; \
		for f in "$(PROFILE_PATCH)" "$(HEADLESS_PATCH)"; do \
			[ -f "$$f" ] || continue; \
			tmp="$$(mktemp)"; \
			awk '/^# >>> dsh-local-llm/{skip=1} /^# <<< dsh-local-llm/{skip=0; next} !skip' "$$f" > "$$tmp"; \
			mv "$$tmp" "$$f"; \
		done; \
		rm -f "$(DUTY_TABLE)"; \
		echo "==> Swarm e configuração local removidos."; \
		if [ -f "$(OLLAMA_DROPIN)" ]; then \
			echo "   O drop-in $(OLLAMA_DROPIN) foi mantido (afeta o Ollama todo)."; \
			echo "   Para remover: sudo rm $(OLLAMA_DROPIN) && sudo systemctl daemon-reload && sudo systemctl restart $(OLLAMA_UNIT)"; \
		fi; \
	else \
		echo "==> Cancelado."; \
	fi
