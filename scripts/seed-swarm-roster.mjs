#!/usr/bin/env node
// Semeia o duty table do dsh-swarm-orchestrator com um modelo local.
//
// Por que um script e não jq inline: o formato do duty-table.json é
// definido pelo plugin (defaultDutyTable em lib/domain/duty-table.js).
// O cliente da UI faz `role.fallbacks.map(...)`, então um papel sem
// `fallbacks` (ou sem label/persona) derruba o painel Settings → AI
// Swarm. Importando o default do próprio plugin, o arquivo sempre
// nasce com o formato correto — e continua correto numa atualização.
//
// Idempotente e não destrutivo: campos já customizados (label,
// description, persona, fallbacks) são preservados; só provider e
// model são fixados. Exceção: uma persona que mande passar
// `sandbox_permissions` volta ao default do plugin (ver abaixo).
//
//   node scripts/seed-swarm-roster.mjs <duty-table.json> <provider> <modelo>

import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

const [file, provider, model] = process.argv.slice(2)

if (!file || !provider || !model) {
  console.error('uso: seed-swarm-roster.mjs <arquivo> <provider> <modelo>')
  process.exit(2)
}

// Localiza o plugin instalado no perfil do DSH.
const DSH_HOME = process.env.DSH_HOME ?? resolve(process.env.HOME, '.dsh')
const PLUGIN_DIRS = [
  resolve(DSH_HOME, 'profiles', process.env.DSH_PROFILE ?? 'web',
    'node_modules/dsh-swarm-orchestrator'),
  resolve(DSH_HOME, 'profiles', 'web', 'node_modules/dsh-swarm-orchestrator'),
]

let defaultDutyTable
for (const dir of PLUGIN_DIRS) {
  try {
    const mod = await import(pathToFileURL(
      resolve(dir, 'lib/domain/duty-table.js')).href)
    defaultDutyTable = mod.defaultDutyTable
    break
  } catch {}
}

if (!defaultDutyTable) {
  console.error(`ERRO: dsh-swarm-orchestrator não encontrado em:\n  ${PLUGIN_DIRS.join('\n  ')}`)
  console.error('Rode `dsh plugin --profile web add -w dsh-swarm-orchestrator` primeiro.')
  process.exit(1)
}

const PINNED = ['architect', 'builder', 'reviewer', 'integrator']

// Ferramentas por papel (toolFilter.allow). Os schemas das 33 tools do
// host custam ~7k tokens por requisição — com contexto de 16k sobravam
// ~5,7k para o trabalho e o Builder estourava a janela no 2º arquivo
// (relatório §16). Estas listas cabem em ~2k tokens. Sempre aplicadas
// aos papéis built-in: editar aqui, não no dashboard.
const BUILD_TOOLS = ['read', 'write', 'edit', 'bash', 'glob', 'grep', 'todo_write', 'swarm_report']
const TOOL_FILTERS = {
  architect: BUILD_TOOLS,
  builder: BUILD_TOOLS,
  integrator: BUILD_TOOLS,
  // O revisor só inspeciona e roda checagens; não escreve.
  reviewer: ['read', 'bash', 'glob', 'grep', 'swarm_report'],
}

// Base: o default do plugin, para todo papel sempre nascer completo.
const base = defaultDutyTable()
const table = { ...base, roles: { ...base.roles } }

// Sobrepõe o que já existe no disco (customizações do usuário).
let existing = {}
try {
  existing = JSON.parse(readFileSync(file, 'utf8'))
} catch {
  /* arquivo ausente ou ilegível: usa só o default */
}

if (existing.roles && typeof existing.roles === 'object') {
  for (const [id, role] of Object.entries(existing.roles)) {
    const key = id.toLowerCase()
    if (!table.roles[key]) continue
    table.roles[key] = {
      ...table.roles[key],
      ...(role && typeof role === 'object' ? role : {}),
      // Garante os arrays que o cliente da UI percorre.
      fallbacks: Array.isArray(role?.fallbacks) ? role.fallbacks : [],
    }
  }
}

// Fixa provider/model apenas nos papéis built-in.
for (const id of PINNED) {
  const role = table.roles[id]
  if (!role) continue
  role.id ??= id
  role.provider = provider
  role.model = model
  role.fallbacks ??= []
  // Persona que manda passar sandbox_permissions sabota o write: o
  // runtime trata o parâmetro como pedido de escalonamento e o rejeita
  // sem justificativa (relatório §15.4). Volta ao texto do plugin.
  if (typeof role.persona === 'string' && role.persona.includes('sandbox_permissions')) {
    role.persona = base.roles[id].persona
    console.log(`  ${id}: persona com sandbox_permissions restaurada ao default do plugin`)
  }
  role.toolFilter = { allow: [...TOOL_FILTERS[id]] }
}

// Preserva a trava manual do dashboard (override.enabled), que o
// DutyTableStore respeita: perdê-la destravaria a tabela em silêncio.
if (existing.override && typeof existing.override === 'object') table.override = existing.override

table.version = 1
table.updatedAt = Date.now()

// Descarta papéis desconhecidos que o usuário tenha adicionado.
for (const id of Object.keys(table.roles)) {
  if (!PINNED.includes(id) && existing.roles?.[id] === undefined) delete table.roles[id]
}

mkdirSync(dirname(file), { recursive: true })
const tmp = `${file}.tmp`
writeFileSync(tmp, `${JSON.stringify(table, null, 2)}\n`, 'utf8')
renameSync(tmp, file)

console.log(`Roster semeado em ${file}`)
for (const id of PINNED) {
  const r = table.roles[id]
  console.log(`  ${id}: ${r?.provider ?? '(inherit)'}/${r?.model ?? '-'}  tools: ${r?.toolFilter?.allow?.length ?? 'todas'}`)
}