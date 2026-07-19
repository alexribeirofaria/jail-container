---
name: auto-pr-commit
file: auto-pr-commit.sh
description: Executar commit por arquivo com mensagem inteligente, criar feature branch, abrir Pull Request e mesclar — sempre com destino `develop` (fallback `main` se `develop` não existir). Todo o fluxo é executado ao vivo por Claude via ferramenta de bash, comando a comando, analisando cada diff — nunca gerando um script para rodar depois.
---

# 🧠 Skill: Commit por Arquivo + Feature Branch + Pull Request

---

## 🎯 Objetivo

- Criar commits **granulares e semânticos**: cada arquivo modificado gera **um commit individual**
- Cada commit tem **mensagem específica** (Conventional Commits) e **descrição detalhada em markdown**, sempre em **português (pt-BR)**
- Isolar o trabalho numa **feature branch**, abrir um **Pull Request** e mesclá-lo
- **Branch de destino sempre `develop`**; se `develop` não existir (local nem remota), cai para `main` automaticamente
- **Nunca gerar um script (`.sh`) para executar depois.** Claude roda cada comando diretamente, um de cada vez, via ferramenta de bash, analisando a saída antes do próximo passo. Isso evita heurísticas "cegas" — cada decisão (tipo, escopo, mensagem) é tomada olhando o diff real daquele arquivo, na hora.

---

## ⚙️ Pré-requisitos

Antes de qualquer commit, Claude verifica ao vivo (um comando por vez, parando se algo falhar):

```bash
command -v git                         # git instalado
gh auth status                         # gh autenticado
git rev-parse --is-inside-work-tree    # está dentro de um repo git
git remote get-url origin              # remote origin configurado
git ls-remote --exit-code origin       # origin acessível (rede/credenciais)
gh repo view                           # gh enxerga o repo (permissão p/ abrir PR)
git rev-parse --git-dir                # localizar .git p/ checar operações pendentes
```

Se qualquer um falhar, Claude **para e explica** o que precisa ser corrigido — nunca segue em frente "torcendo para dar certo". Também checa se há rebase/merge/cherry-pick pendente (`rebase-merge`, `rebase-apply`, `MERGE_HEAD`, `CHERRY_PICK_HEAD` dentro de `.git`) e aborta se houver.

---

## 🚀 Fluxo da Skill

### 1. Verificar estado do repositório

```bash
git rev-parse --abbrev-ref HEAD
git status --porcelain=v1 -uall
```

Se não houver nada modificado, Claude informa e encerra — não cria branch nem PR à toa.

### 2. Resolver a branch de destino (`develop` → `main`)

```bash
git show-ref --verify --quiet refs/heads/develop \
  && echo develop \
  || (git ls-remote --exit-code --heads origin develop &>/dev/null && echo develop || echo main)
```

Essa é a única fonte de verdade da branch alvo. Usada em todo o resto do fluxo (checkout, pull, PR `--base`, merge).

### 3. Gerar nome da feature branch

Claude olha os arquivos alterados (`git status --porcelain=v1 -uall`) e o conteúdo agregado do diff (`git diff`) para montar um nome como por exemplo `feature/adicionar-autenticacao` ou `feature/atualizar-relatorios`, seguindo:

- **Ação dominante**: mais adições → `adicionar`; mais remoções → `remover`; mais modificações → `atualizar`
- **Módulo pelo conteúdo do diff**: `auth|login|token|jwt` → `autenticacao`; `payment|pagamento|billing` → `pagamentos`; `report|dashboard` → `relatorios`; etc. (heurística por palavra-chave, não exaustiva — Claude usa bom senso quando nada bate)
- Sem acentos, minúsculo, só `a-z0-9-`, máx. ~50 caracteres

### 4. Sincronizar destino e criar a feature branch

```bash
git checkout "$TARGET_BRANCH"
git pull origin "$TARGET_BRANCH"
git submodule update --init --recursive
git checkout -b "$FEATURE_NAME"
```

(Se houver alterações locais não commitadas antes de trocar de branch, Claude faz `git stash push -u` só se `git diff --quiet` indicar que há algo a guardar, e dá `git stash pop` depois do checkout.)

### 5. Processar submodules primeiro

```bash
git submodule foreach --quiet \
  'git status --porcelain -uall | grep -q . && echo $displaypath'
```

Para cada submodule modificado: entrar nele, repetir o passo 6 (commit por arquivo) **dentro do submodule**, dar `git push origin HEAD`, voltar ao pai e commitar a referência:

```bash
git add "$sub"
git commit -m "chore(deps): atualizar referência do submodule $(basename "$sub")" \
            -m "Ponteiro atualizado após commits internos na feature \`$FEATURE_NAME\`."
```

### 6. Commit atômico por arquivo (repositório pai)

Para cada linha de `git status --porcelain=v1 -uall`, Claude:

1. Lê o status (`A`/`??`, `M`, `D`, `R`)
2. Roda `git diff -- "$file"` (ou `--cached` se já estiver staged) para **ler o conteúdo real da mudança**
3. Decide tipo, escopo e mensagem pelas heurísticas abaixo
4. `git add -- "$file"` e `git commit -m "<mensagem>" -m "<descrição>"`

Submodules (`-d "$dir/$file/.git"` ou presentes em `.gitmodules`) são **pulados** aqui — já tratados no passo 5.

### 7. Push da feature branch

```bash
git push -u origin "$FEATURE_NAME"
```

### 8. Abrir (ou reaproveitar) o Pull Request

```bash
gh pr list --head "$FEATURE_NAME" --base "$TARGET_BRANCH" --state open --json number --jq '.[0].number // empty'
```

- Se já existir PR aberto para essa branch → **reaproveita** (`gh pr edit`), nunca duplica
- Se não existir → `gh pr create --base "$TARGET_BRANCH" --head "$FEATURE_NAME" --title "..." --body "..."`
- Número do PR capturado via `gh pr view "$FEATURE_NAME" --json number --jq .number` (mais confiável que extrair da URL)
- Antes de criar, Claude confere que há commits novos (`git rev-list --count "$TARGET_BRANCH".."$FEATURE_NAME"`) — sem isso, não faz sentido abrir PR

### 9. Mesclar o PR (obrigatório)

```bash
gh pr view "$PR_NUMBER" --json mergeable --jq .mergeable
```

- Se `CONFLICTING` → Claude **avisa e não tenta mesclar**, pois o conflito precisa ser resolvido antes.
- Caso contrário → Claude **sempre executa** `gh pr merge "$PR_NUMBER" --merge --delete-branch` (estratégia configurável: `--merge` / `--squash` / `--rebase`). Não é necessário pedir confirmação adicional ao usuário.

### 10. Limpeza

```bash
git checkout "$TARGET_BRANCH"
git pull origin "$TARGET_BRANCH"
git submodule update --init --recursive
git branch -d "$FEATURE_NAME" 2>/dev/null || git branch -D "$FEATURE_NAME"
```

Apenas a feature branch é removida (local + remota via `--delete-branch`). A branch de destino nunca é tocada além de `checkout`/`pull`.

---

## 🧠 Heurísticas de geração de mensagem

### Tipo pelo status Git

| Status Git | Tipo base | Ação   |
|------------|-----------|--------|
| `A` / `??` | `feat`    | `add`  |
| `M`        | depende do diff | `update` |
| `D`        | `chore`   | `remove` |
| `R`        | `refactor`| `rename` |

### Refinamento pelo conteúdo do diff

| Padrão no diff | Tipo preferencial |
|---|---|
| `test\|spec\|describe\|it(\|expect(` | `test` |
| `interface \|type \|enum \|abstract class` | `refactor` |
| `@Injectable\|@Controller\|@Module` | `feat` |
| `password\|secret\|token\|apiKey` | `security` |
| `fix\|bug\|erro\|error\|correct` | `fix` |
| `console\.\|logger\.\|log(` | `chore` |
| Só remoções (`^-`, nenhum `^+`) | `refactor` |

### Escopo pelo caminho do arquivo

| Padrão no caminho | Escopo |
|---|---|
| `src/domain/*` | `domain` |
| `src/application/*` | `app` |
| `src/infrastructure/*` | `infra` |
| `src/presentation/*` | `presentation` |
| `test/*` ou `*.spec.*` | `tests` |
| `*.md` | `docs` |
| `*.json\|yaml\|yml\|env*` | `config` |
| `Dockerfile*\|docker-*` | `docker` |
| `.github/*` | `ci` |
| Arquivo direto na raiz (sem `/` no caminho) | `root folder` |
| Qualquer outro caminho | primeiro diretório do caminho (ex: `src/utils/x.js` → `src`) |

> ⚠️ Ponto de atenção conhecido: `dirname` de um arquivo na raiz retorna `"."` — sem tratamento explícito isso vaza para o escopo como `chore(.): ...`. A regra "arquivo na raiz → `root folder`" existe justamente para isso.

### Formato final

```
<tipo>(<escopo>): <ação> <nome_do_arquivo>
```

com corpo em markdown, por exemplo:

```markdown
## Alterações em `src/domain/user.ts`

### Resumo
- **Ação:** update
- **Tipo:** feat
- **Escopo:** domain
- **Linhas adicionadas:** 12
- **Linhas removidas:** 3

### Principais mudanças
- Adiciona validação de e-mail no construtor
- Remove campo legado `oldId`

### Motivação
Alteração incluída como parte da feature `feature/adicionar-autenticacao`.
```

A descrição **não é um placeholder fixo** — Claude escreve o resumo olhando de fato o `git diff` daquele arquivo.

---

## 📬 Regras do Pull Request

- **Anti-duplicação**: sempre checar PR aberto existente antes de criar um novo
- **Draft opcional**: se o usuário pedir, abrir com `--draft`
- **Labels/reviewers opcionais**: aplicados via `gh pr edit --add-label` / `--add-reviewer` depois de criado, um por vez, avisando se algum falhar (ex: label inexistente no repo)
- **Merge automático é obrigatório**: após abrir ou reaproveitar um PR, Claude verifica se ele pode ser mesclado e executa o merge sem pedir confirmação adicional.
- **Nunca mesclar com conflito**: checar `mergeable` antes de tentar
- Corpo do PR inclui: descrição, estatísticas (commits, arquivos alterados), lista de commits da feature, checklist de revisão

---

## 🔒 Boas práticas

- Nunca commitar em massa sem revisar (`git add .` é proibido — sempre arquivo por arquivo)
- Nunca mesclar PR com conflito ou sem confirmar com o usuário quando o pedido não for explícito
- Evitar mensagens genéricas como `update file`
- Submodules sempre commitados e com push **antes** do repositório pai
- Parar e avisar, nunca "seguir tentando", quando um pré-requisito falha

---

## 🧪 Exemplo real

Alterações detectadas:

```
M  src/app/service.ts
A  src/app/new-feature.ts
M  README.md
```

Resultado (3 commits atômicos, na ordem em que os arquivos aparecem):

```
feat(app): add new-feature.ts
fix(app): update service.ts
docs(geral): update README.md
```

Seguido de: push da feature branch, PR `feature/adicionar-new-feature` → `develop` (ou `main`, se `develop` não existir).

---

## 🚀 Benefícios

- Histórico limpo e rastreável, commit por commit
- Mensagens e descrições fiéis ao diff real, não genéricas
- Fluxo de branch/PR sem scripts para manter — a lógica vive na skill e é aplicada ao vivo
- Evita duplicar PRs e evita mesclar com conflito

## ⚠️ Limitações

- Heurísticas de tipo/escopo são baseadas em padrões de texto; casos ambíguos podem exigir ajuste manual do Claude no momento
- Depende de `gh` autenticado com permissão de escrita de PRs no repositório 
- O merge é sempre executado ao final do fluxo, exceto quando o PR estiver com conflito ou quando uma falha externa impedir a operação

## 🔥 Evoluções futuras

- Suporte a squash inteligente de commits relacionados antes do PR
- Detecção de breaking changes para sinalizar `BREAKING CHANGE:` no corpo do commit
- Integração com CI para só sugerir merge depois dos checks passarem

---

## ✅ Conclusão

Essa skill entrega commits granulares, mensagens fiéis ao diff, branch/PR consistentes com `develop`→`main`, e tudo isso **sem depender de um script externo** — cada passo é decidido e executado por Claude, ao vivo, olhando o estado real do repositório.
