#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# auto-pr-commit.sh
# Fluxo: detectar mudanças → resolver branch de destino (develop → main) →
#        gerar nome inteligente → feature branch → commits atômicos
#        (submodules primeiro) → push → PR → merge na branch de destino
#        → deletar APENAS a feature branch (local + remota)
#
# Uso:
#   bash auto-pr-commit.sh                    # nome gerado automaticamente
#   bash auto-pr-commit.sh "feature/meu-nome" # nome manual
#
# Variáveis opcionais:
#   MAIN_BRANCH=develop     força a branch de destino (senão: develop -> main)
#   MERGE_STRATEGY=--merge  --merge | --squash | --rebase
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

MERGE_STRATEGY="${MERGE_STRATEGY:---merge}"

# ─────────────────────────────────────────────────────────────────────────────
# FUNÇÕES AUXILIARES
# ─────────────────────────────────────────────────────────────────────────────

_log() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "$1"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Resolve a branch de destino: respeita MAIN_BRANCH se definido,
# senão tenta 'develop' (local ou remota), caindo para 'main'.
_resolve_target_branch() {
  if [[ -n "${MAIN_BRANCH:-}" ]]; then
    echo "$MAIN_BRANCH"
    return
  fi

  if git show-ref --verify --quiet refs/heads/develop; then
    echo "develop"
    return
  fi

  if git ls-remote --exit-code --heads origin develop &>/dev/null; then
    echo "develop"
    return
  fi

  echo "main"
}

# Gera o nome da feature analisando os arquivos modificados
_generate_feature_name() {
  local files
  files=$(git status --porcelain=v1 -uall | awk '{print $2}' | grep -v '/$' || true)

  if [[ -z "$files" ]]; then
    echo "feature/atualizacao-geral"
    return
  fi

  local adds dels mods action
  adds=$(git status --porcelain=v1 -uall | grep -cE '^(A|\?\?)' || true)
  dels=$(git status --porcelain=v1 -uall | grep -cE '^.?D'      || true)
  mods=$(git status --porcelain=v1 -uall | grep -cE '^.?M'      || true)
  adds="${adds:-0}"; dels="${dels:-0}"; mods="${mods:-0}"

  if   [[ "$adds" -gt "$mods" && "$adds" -gt "$dels" ]]; then action="adicionar"
  elif [[ "$dels" -gt "$mods" ]]; then action="remover"
  else action="atualizar"
  fi

  local scope=""
  local domain_c app_c infra_c pres_c test_c config_c docker_c ci_c
  domain_c=$(echo "$files" | grep -c 'src/domain/'          || true)
  app_c=$(echo "$files"    | grep -c 'src/application/'     || true)
  infra_c=$(echo "$files"  | grep -c 'src/infrastructure/'  || true)
  pres_c=$(echo "$files"   | grep -c 'src/presentation/'    || true)
  test_c=$(echo "$files"   | grep -cE 'test/|\.spec\.'      || true)
  config_c=$(echo "$files" | grep -cE '\.(json|yaml|yml|env)$' || true)
  docker_c=$(echo "$files" | grep -cE 'Dockerfile|docker-'  || true)
  ci_c=$(echo "$files"     | grep -c '\.github/'            || true)
  domain_c="${domain_c:-0}"; app_c="${app_c:-0}"; infra_c="${infra_c:-0}"
  pres_c="${pres_c:-0}"; test_c="${test_c:-0}"; config_c="${config_c:-0}"
  docker_c="${docker_c:-0}"; ci_c="${ci_c:-0}"

  local max=0
  for pair in "$domain_c:dominio" "$app_c:aplicacao" "$infra_c:infraestrutura" \
              "$pres_c:apresentacao" "$test_c:testes" "$config_c:configuracao" \
              "$docker_c:docker" "$ci_c:ci"; do
    local cnt="${pair%%:*}" name="${pair##*:}"
    if [[ "$cnt" -gt "$max" ]]; then max="$cnt"; scope="$name"; fi
  done

  if [[ -z "$scope" || "$max" -eq 0 ]]; then
    local top_file
    top_file=$(echo "$files" | head -1)
    scope=$(dirname "$top_file" | tr '/' '-' | sed 's/^\.\-//' | sed 's/^\./geral/')
    [[ -z "$scope" ]] && scope="geral"
  fi

  local module=""
  local all_diff
  all_diff=$(git diff 2>/dev/null || true)

  if   echo "$all_diff" | grep -qiE 'auth|login|token|jwt|session'; then module="autenticacao"
  elif echo "$all_diff" | grep -qiE 'user|usuario|perfil|profile'; then module="usuarios"
  elif echo "$all_diff" | grep -qiE 'payment|pagamento|billing|invoice'; then module="pagamentos"
  elif echo "$all_diff" | grep -qiE 'report|relatorio|dashboard|chart'; then module="relatorios"
  elif echo "$all_diff" | grep -qiE 'email|smtp|notification|notificacao'; then module="notificacoes"
  elif echo "$all_diff" | grep -qiE 'upload|file|arquivo|storage|s3'; then module="arquivos"
  elif echo "$all_diff" | grep -qiE 'api|endpoint|route|rota|controller'; then module="api"
  elif echo "$all_diff" | grep -qiE 'database|banco|migration|schema|model'; then module="banco-dados"
  elif echo "$all_diff" | grep -qiE 'cache|redis|memcache'; then module="cache"
  elif echo "$all_diff" | grep -qiE 'queue|fila|worker|job|task'; then module="filas"
  fi

  local name_part
  if [[ -n "$module" ]]; then
    name_part="${action}-${module}"
  else
    name_part="${action}-${scope}"
  fi

  name_part=$(echo "$name_part" \
    | sed 's/ã/a/g; s/â/a/g; s/á/a/g; s/à/a/g; s/ê/e/g; s/é/e/g; s/í/i/g' \
    | sed 's/õ/o/g; s/ô/o/g; s/ó/o/g; s/ú/u/g; s/ç/c/g' \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9-]/-/g' \
    | sed 's/--*/-/g; s/^-//; s/-$//' \
    | cut -c1-50)

  echo "feature/${name_part}"
}

_detect_type() {
  local diff="$1" raw="$2"
  if   echo "$diff" | grep -qE '^\+.*(test|spec|describe|it\(|expect\()'; then echo "test"
  elif echo "$diff" | grep -qE '^\+.*(interface |type |enum |abstract class)'; then echo "refactor"
  elif echo "$diff" | grep -qE '^\+.*(@Injectable|@Controller|@Module)'; then echo "feat"
  elif echo "$diff" | grep -qiE '^\+.*(password|secret|token|apiKey)'; then echo "security"
  elif echo "$diff" | grep -qiE '^\+.*(fix|bug|erro|error|correct)'; then echo "fix"
  elif echo "$diff" | grep -qE '^\+.*(console\.|logger\.|log\()'; then echo "chore"
  elif echo "$diff" | grep -qE '^-' && ! echo "$diff" | grep -qE '^\+[^+]'; then echo "refactor"
  else echo "$raw"
  fi
}

_detect_scope() {
  local f="$1"
  case "$f" in
    src/domain/*)          echo "domain" ;;
    src/application/*)     echo "app" ;;
    src/infrastructure/*)  echo "infra" ;;
    src/presentation/*)    echo "presentation" ;;
    test/*|*.spec.*)       echo "tests" ;;
    *.md)                  echo "docs" ;;
    *.json|*.yaml|*.yml|*.env*) echo "config" ;;
    Dockerfile*|docker-*)  echo "docker" ;;
    .github/*)             echo "ci" ;;
    *)                     dirname "$f" | tr '/' '-' | sed 's/^\.\-//' ;;
  esac
}

_commit_files() {
  local dir="${1:-.}"
  local count=0

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    # Formato do porcelain/v1: XY<espaço>PATH (PATH pode conter espaços)
    local xy="${line:0:2}"
    local file="${line:3}"

    file="${file%\"}"
    file="${file#\"}"

    [[ -z "$file" ]] && continue

    # Pular submodules — tratados separadamente.
    # (usar 'if' em vez de '&&' solto: sob 'set -e', um '&&' cujo lado
    #  esquerdo é falso derruba o script, pois o status do comando composto
    #  vira não-zero.)
    if [[ -d "$dir/$file/.git" ]]; then
      continue
    fi
    if git -C "$dir" config --file .gitmodules "submodule.$file.path" &>/dev/null; then
      continue
    fi

    local raw_type action
    case "$xy" in
      "A "|"??")  raw_type="feat";     action="add"    ;;
      "M "|" M")  raw_type="fix";      action="update" ;;
      "D "|" D")  raw_type="chore";    action="remove" ;;
      R*)         raw_type="refactor"; action="rename" ;;
      *)          raw_type="chore";    action="update" ;;
    esac

    local diff type scope filename added removed
    diff=$(git -C "$dir" diff -- "$file" 2>/dev/null || true)
    if [[ -z "$diff" ]]; then
      diff=$(git -C "$dir" diff --cached -- "$file" 2>/dev/null || true)
    fi

    type=$(_detect_type "$diff" "$raw_type")
    scope=$(_detect_scope "$file")
    filename=$(basename "$file")
    added=$(echo "$diff"   | grep -c '^+[^+]' || true); added="${added:-0}"
    removed=$(echo "$diff" | grep -c '^-[^-]' || true); removed="${removed:-0}"

    local short_msg="${type}(${scope}): ${action} ${filename}"
    local body
    body="## Alterações em \`${file}\`

### Resumo
- **Ação:** ${action}
- **Tipo:** ${type}
- **Escopo:** ${scope}
- **Linhas adicionadas:** ${added}
- **Linhas removidas:** ${removed}

### Principais mudanças
$(echo "$diff" | grep '^+[^+]' | head -8 | sed 's/^+/- /' || echo '- Sem diff textual disponível')

### Motivação
Alteração incluída como parte da feature \`${FEATURE_NAME}\`."

    git -C "$dir" add -- "$file"
    git -C "$dir" commit -m "$short_msg" -m "$body"
    echo "  ✅ ${type}(${scope}): ${file}"
    count=$((count + 1))
  done < <(git -C "$dir" status --porcelain=v1 -uall)

  echo "  📦 ${count} arquivo(s) commitado(s)"
}

# ─────────────────────────────────────────────────────────────────────────────
# ETAPA 1 — Verificar pré-requisitos e estado do repo
# ─────────────────────────────────────────────────────────────────────────────
_log "🔍 ETAPA 1 — Verificar estado do repositório"

if ! command -v gh &>/dev/null; then
  echo "❌ GitHub CLI (gh) não encontrado. Instale em: https://cli.github.com"
  exit 1
fi

if ! gh auth status &>/dev/null; then
  echo "❌ GitHub CLI não autenticado. Execute: gh auth login"
  exit 1
fi

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo "  📍 Branch atual: $CURRENT_BRANCH"

CHANGED_COUNT=$(git status --porcelain=v1 -uall | wc -l | tr -d ' ')
echo "  📋 Arquivos modificados: $CHANGED_COUNT"

if [[ "$CHANGED_COUNT" -eq 0 ]]; then
  echo "  ℹ️  Nenhuma alteração detectada. Nada a commitar."
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# ETAPA 2 — Resolver branch de destino (develop -> main) e criar feature branch
# ─────────────────────────────────────────────────────────────────────────────
_log "🌿 ETAPA 2 — Resolver branch de destino e criar feature branch"

TARGET_BRANCH=$(_resolve_target_branch)
echo "  🎯 Branch de destino resolvida: $TARGET_BRANCH"

if [[ -n "${1:-}" ]]; then
  FEATURE_NAME="$1"
  echo "  📌 Nome informado manualmente: $FEATURE_NAME"
else
  FEATURE_NAME=$(_generate_feature_name)
  echo "  🧠 Nome gerado automaticamente: $FEATURE_NAME"
fi

# Garantir que estamos na branch de destino atualizada antes de criar a feature.
if [[ "$CURRENT_BRANCH" != "$TARGET_BRANCH" ]]; then
  echo "  ⚠️  Não está na $TARGET_BRANCH. Fazendo stash (se houver algo) e checkout..."
  STASHED=0
  if ! git diff --quiet || ! git diff --cached --quiet; then
    git stash push -u -m "auto-pr-commit: stash antes de criar feature"
    STASHED=1
  fi
  git checkout "$TARGET_BRANCH"
  git pull origin "$TARGET_BRANCH"
  if [[ "$STASHED" -eq 1 ]]; then
    git stash pop
  fi
else
  git pull origin "$TARGET_BRANCH"
fi

git submodule update --init --recursive
git checkout -b "$FEATURE_NAME"
echo "  ✅ Branch criada: $FEATURE_NAME"

# ─────────────────────────────────────────────────────────────────────────────
# ETAPA 3 — Commits atômicos nos submodules (sempre antes do pai)
# ─────────────────────────────────────────────────────────────────────────────
_log "🔗 ETAPA 3 — Submodules"

MODIFIED_SUBS=$(git submodule foreach --quiet \
  'git status --porcelain -uall | grep -q . && echo $displaypath' 2>/dev/null || true)

if [[ -n "$MODIFIED_SUBS" ]]; then
  while IFS= read -r sub; do
    [[ -z "$sub" ]] && continue
    echo "  🔗 Processando submodule: $sub"
    (
      cd "$sub"
      _commit_files "."
      git push origin HEAD
      echo "  ✅ Push do submodule '$sub' realizado."
    )
    git add "$sub"
    git commit \
      -m "chore(deps): atualizar referência do submodule $(basename "$sub")" \
      -m "## Atualização de Submodule

### Submodule: \`$sub\`
Ponteiro atualizado após commits atômicos internos realizados na feature \`$FEATURE_NAME\`.

### Impacto
- Sem alteração de interface pública
- Referência do repositório pai sincronizada com HEAD do submodule"
    echo "  ✅ Referência de '$sub' commitada no pai."
  done <<< "$MODIFIED_SUBS"
else
  echo "  ℹ️  Nenhum submodule com modificações."
fi

# ─────────────────────────────────────────────────────────────────────────────
# ETAPA 4 — Commits atômicos no repositório pai
# ─────────────────────────────────────────────────────────────────────────────
_log "📦 ETAPA 4 — Commits no repositório pai"
_commit_files "."

# ─────────────────────────────────────────────────────────────────────────────
# ETAPA 5 — Push da feature branch
# ─────────────────────────────────────────────────────────────────────────────
_log "⬆️  ETAPA 5 — Push da feature branch"
git push -u origin "$FEATURE_NAME"
echo "  ✅ Push realizado: origin/$FEATURE_NAME"

# ─────────────────────────────────────────────────────────────────────────────
# ETAPA 6 — Abrir Pull Request com título e corpo ricos
# ─────────────────────────────────────────────────────────────────────────────
_log "📬 ETAPA 6 — Abrir Pull Request"

COMMIT_COUNT=$(git rev-list --count "$TARGET_BRANCH".."$FEATURE_NAME")
FILES_CHANGED=$(git diff --name-only "$TARGET_BRANCH".."$FEATURE_NAME" | wc -l | tr -d ' ')
COMMIT_LOG=$(git log "$TARGET_BRANCH".."$FEATURE_NAME" \
  --pretty=format:"- **%s**%n  > _%ad_" \
  --date=format:'%d/%m/%Y %H:%M' \
  --no-merges)

PR_TITLE=$(echo "$FEATURE_NAME" \
  | sed 's|feature/||' \
  | tr '-' ' ' \
  | sed 's/\b./\u&/g')

PR_BODY="## 📋 Descrição

Implementação da **${PR_TITLE}** via feature branch \`${FEATURE_NAME}\`, com commits atômicos e semânticos por arquivo.

---

## 📊 Estatísticas

| Métrica | Valor |
|---|---|
| 🌿 Branch de origem | \`${FEATURE_NAME}\` |
| 🎯 Branch de destino | \`${TARGET_BRANCH}\` |
| 📝 Total de commits | ${COMMIT_COUNT} |
| 📁 Arquivos alterados | ${FILES_CHANGED} |

---

## 📝 Commits desta feature

${COMMIT_LOG}

---

## ✅ Checklist

- [ ] Código revisado
- [ ] Testes passando
- [ ] Sem conflitos com \`${TARGET_BRANCH}\`
- [ ] Submodules atualizados (se aplicável)
- [ ] Documentação atualizada (se aplicável)

---

> 🤖 Pull Request gerado automaticamente pelo fluxo **auto-pr-commit** (destino: \`${TARGET_BRANCH}\`)."

PR_URL=$(gh pr create \
  --base "$TARGET_BRANCH" \
  --head "$FEATURE_NAME" \
  --title "$PR_TITLE" \
  --body "$PR_BODY")

PR_NUMBER=$(echo "$PR_URL" | grep -oE '[0-9]+$')
echo "  ✅ PR #${PR_NUMBER} criado: ${PR_URL}"

# ─────────────────────────────────────────────────────────────────────────────
# ETAPA 7 — Mesclar o PR na branch de destino
# IMPORTANTE: --delete-branch deleta APENAS a feature branch remota.
#             A branch de destino (develop/main) permanece intacta.
# ─────────────────────────────────────────────────────────────────────────────
_log "🔀 ETAPA 7 — Mesclar PR #${PR_NUMBER} na ${TARGET_BRANCH}"

gh pr merge "$PR_NUMBER" \
  $MERGE_STRATEGY \
  --delete-branch

echo "  ✅ PR #${PR_NUMBER} mesclado em '${TARGET_BRANCH}'."
echo "  🗑️  Branch remota '${FEATURE_NAME}' deletada pelo GitHub."

# ─────────────────────────────────────────────────────────────────────────────
# ETAPA 8 — Deletar APENAS a feature branch local e sincronizar destino
# A branch de destino NÃO é tocada além do pull.
# ─────────────────────────────────────────────────────────────────────────────
_log "🧹 ETAPA 8 — Limpeza da feature branch local"

git checkout "$TARGET_BRANCH"
git pull origin "$TARGET_BRANCH"
git submodule update --init --recursive

if git branch --list "$FEATURE_NAME" | grep -q .; then
  git branch -d "$FEATURE_NAME" 2>/dev/null \
    || git branch -D "$FEATURE_NAME"
  echo "  🗑️  Branch local '${FEATURE_NAME}' deletada."
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎉 FLUXO CONCLUÍDO COM SUCESSO"
echo ""
echo "  📌 PR #${PR_NUMBER}: ${PR_TITLE}"
echo "  🔀 Mesclado em:      ${TARGET_BRANCH}"
echo "  🗑️  Branch removida:  ${FEATURE_NAME} (local + remota)"
echo "  📍 Branch atual:     ${TARGET_BRANCH} (sincronizada)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"