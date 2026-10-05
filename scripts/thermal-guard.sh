#!/usr/bin/env bash
# Trava térmica para os experimentos com LLM local (relatório §17).
#
# Este notebook passou de 100 °C na CPU durante 16 min de inferência
# contínua. A regra: perto do crítico, para IMEDIATAMENTE.
#
#   thermal-guard.sh status   mostra as temperaturas e os limites
#   thermal-guard.sh check    sai 0 se está ok, 1 se passou do limite
#   thermal-guard.sh hook     PreToolUse do Claude Code: acima do limite
#                             encerra o turno do Claude ({"continue":false})
#   thermal-guard.sh watch    vigia a cada INTERVAL s; acima do limite mata
#                             a inferência (llama-server do Ollama) e o DSH
#
# Limites (°C), ajustáveis por ambiente:
#   CPU_MAX=90  — crítico da CPU é 100 (sensors: crit = +100.0°C)
#   GPU_MAX=85  — a GPU começa a reduzir clock em 94 (nvidia-smi: Slowdown Temp)
#
# Sem leitura de sensor o script não bloqueia (falha aberta), mas avisa.

set -u

CPU_MAX="${CPU_MAX:-90}"
GPU_MAX="${GPU_MAX:-85}"
INTERVAL="${INTERVAL:-2}"
LOG="${THERMAL_LOG:-$HOME/.dsh/thermal-guard.log}"

# Maior temperatura entre os núcleos e o pacote (coretemp), inteiro.
cpu_temp() {
	sensors -j 2>/dev/null | jq -r '
		[ to_entries[] | select(.key | startswith("coretemp")) | .value
		  | to_entries[] | select(.value | type == "object") | .value
		  | to_entries[] | select(.key | test("_input$")) | .value ]
		| if length > 0 then max | floor else empty end' 2>/dev/null
}

gpu_temp() {
	command -v nvidia-smi >/dev/null 2>&1 || return 0
	nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null \
		| sort -n | tail -1 | tr -d ' '
}

# Preenche CPU, GPU e REASON; retorna 1 se algum passou do limite.
evaluate() {
	CPU="$(cpu_temp)"
	GPU="$(gpu_temp)"
	REASON=""
	if [ -n "$CPU" ] && [ "$CPU" -ge "$CPU_MAX" ]; then
		REASON="CPU ${CPU}°C ≥ limite ${CPU_MAX}°C"
	fi
	if [ -n "$GPU" ] && [ "$GPU" -ge "$GPU_MAX" ]; then
		REASON="${REASON:+$REASON; }GPU ${GPU}°C ≥ limite ${GPU_MAX}°C"
	fi
	[ -z "$REASON" ]
}

describe() {
	echo "CPU ${CPU:-?}°C (limite $CPU_MAX) · GPU ${GPU:-?}°C (limite $GPU_MAX)"
}

# PIDs a encerrar, por identidade exata do executável — nunca por texto
# solto na linha de comando: `pkill -f llama-server` também mata qualquer
# shell ou editor cujo comando apenas MENCIONE o nome (aconteceu no teste).
#   - runner do Ollama: comm == llama-server (roda com o nosso usuário;
#     matá-lo aborta a geração, o serviço recarrega o modelo depois)
#   - DSH web: argv[0] é `node`, argv[1] o binário dsh, argv[2] `web`
#     (o DSH reenviaria a tarefa do Swarm se ficasse no ar). Exigir argv[0]
#     node exclui shells: o Claude Code roda comandos como
#     `bash -c "<texto>"`, e um texto citando "dsh web" casava antes. Não
#     dá para usar comm: no Node 24 ele aparece como "MainThread".
inference_pids() {
	ps -u "$USER" -o pid=,comm=,args= | awk '
		$2 == "llama-server" { print $1, "llama-server"; next }
		$3 ~ /(^|\/)node$/ && $4 ~ /\/(bin\/dsh|dsh\/lib\/bin\.js)$/ && $5 == "web" { print $1, "dsh-web" }'
}

stop_inference() {
	local pids names
	pids="$(inference_pids | awk '{print $1}')"
	names="$(inference_pids | awk '{print $2}' | sort -u | paste -sd, -)"
	if [ -z "$pids" ]; then echo "nada estava rodando"; return; fi
	# shellcheck disable=SC2086
	kill $pids 2>/dev/null
	echo "$names (pids $(echo $pids))"
}

case "${1:-status}" in
	status)
		evaluate; rc=$?
		describe
		[ -z "$CPU" ] && echo "AVISO: sem leitura da CPU (sensors/jq)"
		[ $rc -eq 0 ] && echo "OK" || echo "QUENTE: $REASON"
		exit $rc
		;;
	check)
		evaluate || { echo "QUENTE: $REASON" >&2; exit 1; }
		exit 0
		;;
	hook)
		# Lido pelo Claude Code antes de cada ferramenta. continue:false
		# encerra o turno inteiro, não só a chamada.
		cat >/dev/null
		if ! evaluate; then
			msg="TRAVA TÉRMICA: $REASON. Pare agora: não rode mais nada, avise o usuário e espere a máquina esfriar ($(describe))."
			jq -n --arg m "$msg" '{continue: false, stopReason: $m, systemMessage: $m}'
		fi
		exit 0
		;;
	watch)
		mkdir -p "$(dirname "$LOG")"
		echo "$(date '+%F %T') vigia iniciado — CPU_MAX=$CPU_MAX GPU_MAX=$GPU_MAX INTERVAL=${INTERVAL}s" | tee -a "$LOG"
		[ -z "$(cpu_temp)" ] && echo "AVISO: sem leitura da CPU (sensors/jq) — a vigia da CPU não funciona" | tee -a "$LOG"
		while :; do
			if ! evaluate; then
				what="$(stop_inference)"
				line="$(date '+%F %T') PARADA: $REASON — encerrado: $what"
				echo "$line" | tee -a "$LOG" >&2
				printf '\a' >&2
				# Não reinicia nada: só volta a vigiar. Se algo relançar a
				# inferência ainda quente, é derrubado de novo.
				sleep 10
			fi
			sleep "$INTERVAL"
		done
		;;
	*)
		echo "uso: $0 {status|check|hook|watch}" >&2
		exit 2
		;;
esac
