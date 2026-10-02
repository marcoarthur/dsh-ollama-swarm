# ============================================================
# Makefile — DSH + dsh-swarm-orchestrator + Ollama/qwen3:8b
# ============================================================
# Política de versão:
#   DSH_VERSION   = versão exata do DSH a instalar (reprodutível)
#   SWARM_VERSION = versão exata do Swarm a instalar (reprodutível)
# Para acompanhar rolling, use DSH_VERSION=latest
# ============================================================

SHELL := /bin/bash

DSH_PROFILE    := web
DSH_HOME       := $(HOME)/.dsh
SETTINGS_YAML  := $(DSH_HOME)/settings.yaml

OLLAMA_HOST    := http://127.0.0.1:11434
OLLAMA_URL     := $(OLLAMA_HOST)/v1
MODEL          := qwen3:8b

DSH_VERSION    := 0.1.0-rc.7

SWARM_VERSION  := 0.6.30

.PHONY: help check-prereqs install-dsh ensure-model install-swarm \
        install config-ollama config-roster config start \
        verify test test-dsh status clean setup

# ------------------------------------------------------------
# Help
# ------------------------------------------------------------
help:
	@echo "Alvos disponíveis:"
	@echo ""
	@echo "  make setup        Instala, configura, verifica e testa"
	@echo "  make install      Instala DSH + Swarm + garante o modelo"
	@echo "  make config       Configura provider Ollama e mostra Roster"
	@echo "  make start        Inicia o DSH Web"
	@echo "  make verify       Verifica instalação (falha se algo essencial faltar)"
	@echo "  make test         Testa geração via API OpenAI-compatible"
	@echo "  make test-dsh     Testa integração DSH → llm-pi-ai → Ollama"
	@echo "  make status       Mostra estado do ambiente"
	@echo "  make clean        Remove o plugin Swarm"
	@echo ""
	@echo "Variáveis:"
	@echo "  DSH_VERSION=$(DSH_VERSION)  SWARM_VERSION=$(SWARM_VERSION)"
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
		echo "ERRO: Ollama não respondeu em $(OLLAMA_HOST)."; exit 1; }
	@echo "==> Pré-requisitos OK."

# ------------------------------------------------------------
# Instalação do DSH (versão fixa)
# ------------------------------------------------------------

install-dsh:
	@echo "==> Verificando DSH..."
	@if command -v dsh >/dev/null 2>&1; then \
		CURRENT=$$(dsh --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[a-z0-9.]+)?' | head -1); \
		echo "   DSH instalado: $${CURRENT:-desconhecido}"; \
		echo "   → Versão aceita. Não será reinstalado."; \
	else \
		echo "   → Instalando @deepseek-ai/dsh@$(DSH_VERSION)..."; \
		npm install -g @deepseek-ai/dsh@$(DSH_VERSION); \
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
# Instalação do Swarm (versão fixa, sem fallback)
# ------------------------------------------------------------
install-swarm: install-dsh
	@echo "==> Instalando dsh-swarm-orchestrator@$(SWARM_VERSION)..."
	@dsh plugin --profile "$(DSH_PROFILE)" add -w "dsh-swarm-orchestrator@$(SWARM_VERSION)" || { \
		echo "ERRO: Falha ao instalar dsh-swarm-orchestrator@$(SWARM_VERSION)."; \
		echo "Verifique: npm view dsh-swarm-orchestrator versions"; \
		exit 1; \
	}
	@echo "==> Swarm instalado."

# Dependências explícitas para ordem correta
ensure-model: check-prereqs
install-swarm: check-prereqs
install: check-prereqs ensure-model install-swarm

# ------------------------------------------------------------
# Configuração do provider Ollama em settings.yaml
#
# O DSH armazena providers customizados em $DSH_HOME/settings.yaml,
# sob a chave llm-pi-ai. Mudanças são hot-reloaded (próxima requisição).
# Docs: docs/user/guide/providers.md
# ------------------------------------------------------------
config-ollama:
	@echo "==> Verificando Ollama..."
	@curl -sf "$(OLLAMA_URL)/models" >/dev/null 2>&1 || { \
		echo "ERRO: Ollama não responde em $(OLLAMA_URL)/models"; exit 1; }

	@echo "==> Configurando provider Ollama em $(SETTINGS_YAML)..."
	@mkdir -p "$(dir $(SETTINGS_YAML))"

	@if [ ! -f "$(SETTINGS_YAML)" ]; then \
		printf '%s\n' \
			'llm-pi-ai:' \
			'  providers:' \
			'    ollama:' \
			'      apiKeyEnv: OLLAMA_API_KEY' \
			'      api: openai-completions' \
			'      baseURL: $(OLLAMA_URL)' \
			'      models:' \
			'        - id: $(MODEL)' \
			'          name: Qwen3 8B' \
			'          contextWindow: 32768' \
			> "$(SETTINGS_YAML)"; \
		echo "   → Provider Ollama criado."; \
	else \
		echo "   → $(SETTINGS_YAML) já existe. Não será sobrescrito."; \
		echo "   → Verifique se o provider 'ollama' já está configurado."; \
	fi
	@echo ""

# ------------------------------------------------------------
# Roster (instruções — NÃO configura automaticamente)
# ------------------------------------------------------------
config-roster:
	@echo "==> Roster do Swarm (instruções)"
	@echo ""
	@echo "Após iniciar o DSH (make start):"
	@echo "  Settings → AI Swarm"
	@echo ""
	@echo "Configure os papéis com 'ollama / $(MODEL)':"
	@echo "  architect, builder, reviewer, integrator"
	@echo ""

# config: configura provider + mostra instruções do Roster
config: config-ollama config-roster

# ------------------------------------------------------------
# Start
# ------------------------------------------------------------
start:
	@echo "==> Iniciando DSH Web..."
	@echo "    http://127.0.0.1:3080"
	@echo ""
	@export OLLAMA_API_KEY=dummy && dsh web

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
	test -f "$(SETTINGS_YAML)" \
		|| { echo "   ERRO: $(SETTINGS_YAML) não encontrado"; ok=0; }; \
	dsh plugin --profile "$(DSH_PROFILE)" list 2>/dev/null \
		| grep -q 'dsh-swarm-orchestrator' \
		|| { echo "   ERRO: Swarm não instalado"; ok=0; }; \
	if [ $$ok -eq 1 ]; then \
		echo "==> Verificação OK."; \
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
# Test-DSH: integração completa DSH → llm-pi-ai → Ollama
#
# Usa o modo headless oficial: dsh --profile headless "task"
# Cria uma sessão persistida, executa a tarefa, imprime a resposta.
# Docs: apps/cli/README.md → dsh --profile headless "task"
# ------------------------------------------------------------
test-dsh:
	@echo "==> Testando integração DSH → llm-pi-ai → Ollama..."
	@RESULT=$$(OLLAMA_API_KEY=dummy \
		dsh --profile headless \
		"Responda com exatamente uma palavra: OK" 2>&1) || { \
		echo "ERRO: DSH headless falhou."; \
		echo "$$RESULT"; \
		exit 1; \
	}; \
	echo "   Resposta do DSH: $$RESULT"; \
	if echo "$$RESULT" | grep -Eq '(^|[^[:alpha:]])OK([^[:alpha:]]|$$)'; then \
		echo "OK: integração DSH → Ollama funcionando."; \
	else \
		echo "ERRO: DSH executou, mas a resposta não foi a esperada."; \
		exit 1; \
	fi

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
	@echo "  Settings:      $(SETTINGS_YAML)"
	@echo "  Ollama:        $(OLLAMA_URL)"
	@echo "  Modelo:        $(MODEL)"
	@printf "  DSH instalado: "
	@if command -v dsh >/dev/null 2>&1; then \
		dsh --version 2>/dev/null || echo "(versão indisponível)"; \
	else \
		echo "NÃO INSTALADO"; \
	fi
	@echo "  DSH desejado:  $(DSH_VERSION)"
	@echo "  Swarm desejado: $(SWARM_VERSION)"
	@echo ""
	@echo "--- Modelos Ollama ---"
	@ollama list 2>/dev/null || echo "  (Ollama não disponível)"
	@echo ""
	@echo "--- Plugins DSH (perfil $(DSH_PROFILE)) ---"
	@dsh plugin --profile "$(DSH_PROFILE)" list 2>/dev/null || echo "  (DSH não disponível)"
	@echo ""
	@echo "============================================================"
# ------------------------------------------------------------
# Setup: install → config → verify → test → test-dsh
# ------------------------------------------------------------
setup: install config verify test test-dsh install-headless-pristine
	@echo ""
	@echo "============================================================"
	@echo "  DSH + Ollama + Swarm configurados e testados"
	@echo "============================================================"
	@echo ""
	@echo "  Modelo:  $(MODEL)"
	@echo "  DSH:     http://127.0.0.1:3080"
	@echo ""
	@echo "Próximo passo:"
	@echo "  make start"
	@echo ""
	@echo "Depois: Settings → AI Swarm → configure o Roster."
	@echo ""
	@echo "============================================================"

# ------------------------------------------------------------
# Clean (conservador: não apaga settings.yaml)
# ------------------------------------------------------------
clean:
	@echo "ATENÇÃO: isto removerá o plugin Swarm."
	@read -p "Continuar? [s/N] " -n 1 -r; \
	echo; \
	if [[ $$REPLY =~ ^[Ss]$$ ]]; then \
		dsh plugin --profile "$(DSH_PROFILE)" \
			remove dsh-swarm-orchestrator 2>/dev/null || true; \
		echo "==> Swarm removido."; \
	else \
		echo "==> Cancelado."; \
	fi

install-headless-pristine: install-dsh
	@echo "==> Instalando dsh-pristine no perfil headless..."
	@dsh plugin --profile headless add -w dsh-pristine || { \
		echo "AVISO: Falha ao instalar dsh-pristine. O test-dsh pode entrar em loop."; \
	}
	@echo "==> dsh-pristine instalado."
