#!/usr/bin/env bash
# Benchmark térmico reprodutível (relatório §18 e §20).
#
# Mede quanto tempo uma geração contínua no Ollama leva para esquentar
# a CPU, para comparar antes/depois de cada melhoria física (limpeza,
# pasta térmica, base com ventilação). Mesmo protocolo da §18:
#
#   1. espera a CPU baixar até START_MAX (padrão 60 °C);
#   2. dispara uma geração direta na API do Ollama (sem DSH), prompt fixo;
#   3. a cada 2 s registra temperaturas, uso/potência/clock da GPU e os
#      processos acima de 3% de CPU;
#   4. ABORTA a geração quando a CPU ou a GPU atinge ABORT_AT (padrão 85 °C).
#
# Rode com a trava térmica ligada (make thermal-watch, em outro terminal)
# — este script tem a própria trava, mas lê só a cada 2 s.
#
# Variáveis: MODEL, NUM_CTX, NUM_PREDICT, NUM_THREAD (vazio = padrão do
# Ollama), START_MAX, ABORT_AT, MAX_SECONDS, OLLAMA_HOST, LABEL.
# Saída: tabela no terminal + CSV em ~/.dsh/thermal-bench/<data>-<LABEL>.csv

set -u

MODEL="${MODEL:-qwen3.5:9b}"
NUM_CTX="${NUM_CTX:-16384}"
NUM_PREDICT="${NUM_PREDICT:-1500}"
NUM_THREAD="${NUM_THREAD:-}"
START_MAX="${START_MAX:-60}"
ABORT_AT="${ABORT_AT:-85}"
MAX_SECONDS="${MAX_SECONDS:-120}"
OLLAMA_HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"
LABEL="${LABEL:-bench}"
OUT_DIR="${OUT_DIR:-$HOME/.dsh/thermal-bench}"

GUARD="$(dirname "$(readlink -f "$0")")/thermal-guard.sh"
PROMPT='Escreva em Perl um módulo Truco::Game completo com as regras do truco paulista, com comentários detalhados.'

cpu_temp() { "$GUARD" status | awk 'NR==1 {print $2+0}'; }
gpu_temp() { "$GUARD" status | awk 'NR==1 {for (i=1;i<=NF;i++) if ($i=="GPU") {print $(i+1)+0; exit}}'; }

mkdir -p "$OUT_DIR"
csv="$OUT_DIR/$(date +%Y%m%d-%H%M%S)-$LABEL.csv"
echo "t_s,cpu_c,gpu_c,gpu_util,gpu_w,gpu_mhz,llama_cpu_pct,top_procs" > "$csv"

echo "==> $LABEL: modelo $MODEL, num_ctx $NUM_CTX, num_thread ${NUM_THREAD:-padrão}, aborta a ${ABORT_AT} °C"
printf '   esperando a CPU baixar até %s °C' "$START_MAX"
while [ "$(cpu_temp)" -gt "$START_MAX" ]; do printf '.'; sleep 3; done
echo " ok ($(cpu_temp) °C)"

opts=$(jq -n --argjson c "$NUM_CTX" --argjson p "$NUM_PREDICT" --arg t "$NUM_THREAD" \
	'{num_ctx:$c, num_predict:$p, temperature:0} + (if $t == "" then {} else {num_thread:($t|tonumber)} end)')
body=$(jq -n --arg m "$MODEL" --arg p "$PROMPT" --argjson o "$opts" \
	'{model:$m, prompt:$p, stream:false, think:false, options:$o}')
resp="$(mktemp)"
curl -s "$OLLAMA_HOST/api/generate" -d "$body" > "$resp" &
gen=$!

start=$(date +%s)
max_cpu=0; reason="geração terminou"
printf '%5s %5s %5s %5s %6s %6s %7s\n' "t(s)" "CPU" "GPU" "util" "W" "MHz" "llama%"
while :; do
	sleep 2
	t=$(( $(date +%s) - start ))
	cpu=$(cpu_temp); gpu=$(gpu_temp)
	IFS=', ' read -r util watts mhz < <(nvidia-smi --query-gpu=utilization.gpu,power.draw,clocks.gr \
		--format=csv,noheader,nounits 2>/dev/null || echo "0, 0, 0")
	# top com locale C (ponto decimal); uma amostra de 1 s, processos ≥ 3%.
	procs=$(LC_ALL=C top -b -n 2 -d 1 -o %CPU -w 200 | awk '/^top -/{n++} n==2 && /^ *[0-9]/ && $9+0 >= 3 {printf "%s:%d ", $12, $9}')
	llama=$(sed -n 's/.*llama-server:\([0-9]*\).*/\1/p' <<<"$procs"); llama=${llama:-0}
	[ "$cpu" -gt "$max_cpu" ] && max_cpu=$cpu
	printf '%5s %5s %5s %5s %6s %6s %7s\n' "$t" "$cpu" "$gpu" "$util" "$watts" "$mhz" "$llama"
	echo "$t,$cpu,$gpu,$util,$watts,$mhz,$llama,\"$procs\"" >> "$csv"
	if [ "$cpu" -ge "$ABORT_AT" ] || [ "${gpu:-0}" -ge "$ABORT_AT" ]; then
		kill "$gen" 2>/dev/null; reason="ABORTADO a ${t}s: CPU ${cpu} °C / GPU ${gpu} °C"; break
	fi
	if [ "$t" -ge "$MAX_SECONDS" ]; then
		kill "$gen" 2>/dev/null; reason="limite de ${MAX_SECONDS}s atingido sem passar de ${ABORT_AT} °C"; break
	fi
	kill -0 "$gen" 2>/dev/null || break
done
wait "$gen" 2>/dev/null

echo "==> $reason · CPU máx ${max_cpu} °C"
if jq -e '.eval_count' "$resp" >/dev/null 2>&1; then
	jq -r '"   geração: \(.eval_count) tokens a \((.eval_count/(.eval_duration/1e9)*10|floor)/10) tok/s"' "$resp"
elif [ -s "$resp" ]; then
	echo "   resposta do Ollama: $(head -c 200 "$resp")"
else
	echo "   sem resposta completa do Ollama (interrompida ou servidor fora do ar)"
fi
rm -f "$resp"
echo "   CSV: $csv"
