# 🏗️ Desafio 2 — Docker + CI/CD do Backend e Frontend (CondoCombat)

## 🎯 Objetivo

Criar **Dockerfiles** e um **docker-compose.yml** para o backend (FastAPI) e frontend (Next.js) do CondoCombat, e configurar **3 arquivos de pipeline** de **Integração Contínua (CI)** no GitLab CI/CD que executam lint, testes, build e push das imagens para o **DockerHub**.

As pipelines devem:

1. **Pipeline do Backend** (`.gitlab-ci/backend.yml`): Executar lint (Ruff) → testes (pytest) → build Docker → push DockerHub
2. **Pipeline do Frontend** (`.gitlab-ci/frontend.yml`): Executar lint (ESLint) → testes (Vitest) → build Docker → push DockerHub
3. **Arquivo principal** (`.gitlab-ci.yml`): Incluir os dois pipelines com `include:` e filtrar por `rules:changes`
4. **Rodar localmente** com Docker Compose usando as imagens publicadas

Pipelines configuradas como **arquivos separados** no GitLab CI/CD.

---

## 📦 Sobre o Projeto

### Backend (FastAPI)

| Item | Detalhe |
|------|---------|
| **Framework** | FastAPI 0.115+ com SQLAlchemy Async |
| **Linter** | Ruff (`ruff check app/`) |
| **Testes** | pytest (`pytest`) |
| **Porta** | 8000 (uvicorn) |
| **Banco** | PostgreSQL 16 + Alembic |
| **Entrypoint** | `backend/app/main.py` |
| **Dependências** | `backend/requirements.txt` |

### Frontend (Next.js)

| Item | Detalhe |
|------|---------|
| **Framework** | Next.js 14 App Router + shadcn/ui |
| **Linter** | ESLint (`npm run lint`) |
| **Testes** | Vitest (`npm run test`) |
| **Porta** | 3000 (Next.js dev) |
| **Build** | `npm run build` |
| **Entrypoint** | `frontend/next.config.js` |
| **Dependências** | `frontend/package.json` |

---

## 📋 Pré-requisitos

1. **Conta no DockerHub**
   - Crie em [hub.docker.com](https://hub.docker.com/)
   - Crie um Access Token em Account Settings → Security

2. **Conta no GitLab**
   - Repositório do CondoCombat importado ou criado no GitLab

3. **Docker instalado localmente**
   - Para testar os Dockerfiles
   - Para rodar o docker-compose

4. **Permissões de push** no repositório GitLab

---

## 🔐 Variáveis de Ambiente (CI/CD Variables)

Configure estas variáveis no GitLab (Settings → CI/CD → Variables):

| Variável | Valor | Descrição | Masked | Protected |
|----------|-------|-----------|--------|-----------|
| `DOCKERHUB_USERNAME` | Seu usuário DockerHub | Username para login | Não | Não |
| `DOCKERHUB_TOKEN` | Access Token do DockerHub | Token em vez de senha | Sim | Sim |
| `SECRET_KEY` | Chave JWT de 32 caracteres | Backend valida na inicialização | Sim | Sim |

**Como gerar a SECRET_KEY**:
```bash
python -c 'import secrets; print(secrets.token_urlsafe(32))'
```

> **Importante**: Marque `DOCKERHUB_TOKEN` e `SECRET_KEY` como **Masked** (mascarados) para não aparecerem nos logs. Se a branch `main` for protegida, marque também como **Protected** para que só pipelines da `main` tenham acesso.

---

## 🏗️ Criando o Dockerfile do Backend

Crie o arquivo `backend/Dockerfile` com **multi-stage build** em 2 estágios:

### Etapas

1. **Stage 1 (deps)**: Instala dependências Python
2. **Stage 2 (runtime)**: Imagem final com usuário não-root

### `backend/Dockerfile`

```dockerfile
# =============================================================================
# Stage 1: Dependencies — instala dependências Python
# =============================================================================
FROM python:3.12-slim AS deps

WORKDIR /app

# Instala sistema básico e dependências de compilação
RUN apt-get update && apt-get install -y \
    gcc \
    postgresql-client \
    && rm -rf /var/lib/apt/lists/*

# Copia requirements e instala dependências
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# =============================================================================
# Stage 2: Runtime — imagem final
# =============================================================================
FROM python:3.12-slim AS runtime

WORKDIR /app

# Instala dependências de runtime
RUN apt-get update && apt-get install -y \
    postgresql-client \
    && rm -rf /var/lib/apt/lists/*

# Cria usuário não-root
RUN useradd --create-home --shell /bin/bash app

# Copia dependências do stage deps
COPY --from=deps /usr/local/lib/python3.12/site-packages /usr/local/lib/python3.12/site-packages
COPY --from=deps /usr/local/bin /usr/local/bin

# Copia código fonte
COPY app/ app/
COPY alembic/ alembic/
COPY alembic.ini .

# Copia e configura script de entrada
COPY entrypoint.sh .
RUN chmod +x entrypoint.sh

# Troca para usuário não-root
USER app

# Expõe porta e health check
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=30s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1

# Entry point
ENTRYPOINT ["./entrypoint.sh"]
```

### `backend/entrypoint.sh`

```bash
#!/bin/bash
set -e

# Valida SECRET_KEY obrigatória
if [ -z "$SECRET_KEY" ]; then
    echo "❌ ERRO: SECRET_KEY não está definida!"
    echo "   Gere uma com: python -c 'import secrets; print(secrets.token_urlsafe(32))'"
    exit 1
fi

echo "🔧 Rodando migrations do Alembic..."
alembic upgrade head

echo "🚀 Iniciando servidor FastAPI..."
exec uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

---

## 🏗️ Criando o Dockerfile do Frontend

Crie o arquivo `frontend/Dockerfile` com **multi-stage build** em 3 estágios:

### Etapas

1. **Stage 1 (deps)**: Instala dependências com `npm ci`
2. **Stage 2 (builder)**: Compila o Next.js com `npm run build`
3. **Stage 3 (runner)**: Imagem final apenas com o necessário para produção

### `frontend/Dockerfile`

```dockerfile
# =============================================================================
# Stage 1: Dependencies — instala node_modules
# =============================================================================
FROM node:20-alpine AS deps

WORKDIR /app

# Copia apenas os arquivos de dependências (aproveita cache)
COPY package.json package-lock.json ./

# Instala dependências exatas do lockfile
RUN npm ci

# =============================================================================
# Stage 2: Builder — compila a aplicação
# =============================================================================
FROM node:20-alpine AS builder

WORKDIR /app

# Copia dependências do stage deps
COPY --from=deps /app/node_modules ./node_modules

# Copia código fonte
COPY . .

# Build da aplicação Next.js
RUN npm run build

# =============================================================================
# Stage 3: Runner — imagem de produção
# =============================================================================
FROM node:20-alpine AS runner

WORKDIR /app

# Instala dependências de runtime (mínimas)
RUN npm add next@latest

# Cria usuário não-root
RUN addgroup --system --gid 1001 nodejs
RUN adduser --system --uid 1001 nextjs

# Copia arquivos buildados
COPY --from=builder /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static

# Troca para usuário não-root
USER nextjs

# Expõe porta e health check
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=30s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:3000 || exit 1

# Inicia servidor Next.js
CMD ["node", "server.js"]
```

---

## 🐳 Criando o docker-compose.yml

Crie o arquivo `docker-compose.yml` na raiz do projeto:

```yaml
# =============================================================================
# CondoCombat — Docker Compose (Backend + Frontend + Database)
# =============================================================================
version: '3.8'

services:
  # PostgreSQL Database
  db:
    image: postgres:16-alpine
    container_name: condocombat-db
    environment:
      POSTGRES_USER: ${POSTGRES_USER:-condocombat}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-condocombat}
      POSTGRES_DB: ${POSTGRES_DB:-condocombat}
    volumes:
      - pgdata:/var/lib/postgresql/data
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-condocombat}"]
      interval: 10s
      timeout: 5s
      retries: 5

  # Backend API (FastAPI)
  api:
    image: your-dockerhub-username/condocombat-backend:latest
    container_name: condocombat-api
    environment:
      DATABASE_URL: postgresql+asyncpg://${POSTGRES_USER:-condocombat}:${POSTGRES_PASSWORD:-condocombat}@db:5432/${POSTGRES_DB:-condocombat}
      SECRET_KEY: ${SECRET_KEY}
    ports:
      - "8000:8000"
    depends_on:
      db:
        condition: service_healthy
    restart: unless-stopped

  # Frontend (Next.js)
  web:
    image: your-dockerhub-username/condocombat-frontend:latest
    container_name: condocombat-web
    environment:
      NEXT_PUBLIC_API_URL: http://localhost:8000
    ports:
      - "3000:3000"
    depends_on:
      - api
    restart: unless-stopped

volumes:
  pgdata:
    driver: local
```

---

## 📝 Pipeline do Backend

Crie o diretório `.gitlab-ci/` e dentro dele o arquivo `backend.yml`:

```yaml
# =============================================================================
# Pipeline do Backend — Lint → Test → Build → Push
# =============================================================================
stages:
  - lint
  - test
  - build

variables:
  PIP_CACHE_DIR: "$CI_PROJECT_DIR/.cache/pip"

# ---------------------------------------------------------------------------
# Lint — Ruff
# ---------------------------------------------------------------------------
lint:
  stage: lint
  image: python:3.12-slim
  cache:
    key: backend-pip
    paths:
      - .cache/pip
  before_script:
    - pip install ruff
  script:
    - cd backend
    - ruff check app/
  rules:
    - changes:
        - backend/**/*

# ---------------------------------------------------------------------------
# Test — pytest
# ---------------------------------------------------------------------------
test:
  stage: test
  image: python:3.12-slim
  cache:
    key: backend-pip
    paths:
      - .cache/pip
  before_script:
    - pip install -r backend/requirements.txt
  script:
    - cd backend
    - pytest
  variables:
    SECRET_KEY: $SECRET_KEY
  rules:
    - changes:
        - backend/**/*

# ---------------------------------------------------------------------------
# Build — Docker image → Push to DockerHub
# ---------------------------------------------------------------------------
build:
  stage: build
  image: docker:27
  services:
    - docker:dind
  variables:
    DOCKER_TLS_CERTDIR: ""
  before_script:
    - docker login -u $DOCKERHUB_USERNAME -p $DOCKERHUB_TOKEN
  script:
    - docker build -t $DOCKERHUB_USERNAME/condocombat-backend:latest ./backend
    - docker push $DOCKERHUB_USERNAME/condocombat-backend:latest
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
      changes:
        - backend/**/*
```

---

## 📝 Pipeline do Frontend

Crie o arquivo `.gitlab-ci/frontend.yml`:

```yaml
# =============================================================================
# Pipeline do Frontend — Lint → Test → Build → Push
# =============================================================================
stages:
  - lint
  - test
  - build

variables:
  npm_config_cache: "$CI_PROJECT_DIR/.npm"

cache:
  key: frontend-npm
  paths:
    - .npm

# ---------------------------------------------------------------------------
# Lint — ESLint
# ---------------------------------------------------------------------------
lint:
  stage: lint
  image: node:20-alpine
  before_script:
    - cd frontend
    - npm ci
  script:
    - cd frontend
    - npm run lint
  rules:
    - changes:
        - frontend/**/*

# ---------------------------------------------------------------------------
# Test — Vitest
# ---------------------------------------------------------------------------
test:
  stage: test
  image: node:20-alpine
  cache:
    key: frontend-npm
    paths:
      - frontend/node_modules
  before_script:
    - cd frontend
    - npm ci
  script:
    - cd frontend
    - npm run test
  rules:
    - changes:
        - frontend/**/*

# ---------------------------------------------------------------------------
# Build — Docker image → Push to DockerHub
# ---------------------------------------------------------------------------
build:
  stage: build
  image: docker:27
  services:
    - docker:dind
  variables:
    DOCKER_TLS_CERTDIR: ""
  before_script:
    - docker login -u $DOCKERHUB_USERNAME -p $DOCKERHUB_TOKEN
  script:
    - docker build -t $DOCKERHUB_USERNAME/condocombat-frontend:latest ./frontend
    - docker push $DOCKERHUB_USERNAME/condocombat-frontend:latest
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
      changes:
        - frontend/**/*
```

---

## 📝 Arquivo Principal

Crie o arquivo `.gitlab-ci.yml` na **raiz do repositório**. Ele inclui os dois pipelines com `include:` e o GitLab CI/CD automaticamente executa apenas os jobs cujas `rules:changes` corresponderem aos arquivos modificados no push.

```yaml
# =============================================================================
# CondoCombat — Pipeline Principal
# Inclui pipelines separadas para backend e frontend
# =============================================================================
include:
  - local: .gitlab-ci/backend.yml
  - local: .gitlab-ci/frontend.yml
```

### Como funciona

1. Quando você faz push para `main`, o GitLab CI/CD carrega o `.gitlab-ci.yml`
2. Ele encontra as duas pipelines incluídas via `include:`
3. Cada job dentro delas tem `rules:changes` que filtra por diretório
4. Se você alterou só o `backend/`, apenas os jobs do backend executam
5. Se alterou só o `frontend/`, apenas os jobs do frontend executam
6. Se alterou ambos, os dois pipelines rodam em paralelo

---

## 🐳 Rodando o Stack Local com Docker Compose

Depois das pipelines publicarem as imagens no DockerHub, você pode rodar localmente:

### 1. Configure as variáveis de ambiente

```bash
# Crie o arquivo .env na raiz do projeto
cp .env.example .env
# Edite .env com suas credenciais DockerHub
```

### 2. Atualize o docker-compose.yml

Substitua `your-dockerhub-username` pelo seu usuário real no DockerHub.

### 3. Inicie os serviços

```bash
# Inicia todos os serviços em background
docker compose up -d

# Acompanha os logs
docker compose logs -f

# Verifica status dos serviços
docker compose ps
```

### 4. Acesse as aplicações

- **Frontend**: http://localhost:3000
- **Backend API**: http://localhost:8000
- **API Docs**: http://localhost:8000/docs

### 5. Parar os serviços

```bash
# Para os serviços sem apagar dados
docker compose down

# Para os serviços e apaga volume do banco (cuidado!)
docker compose down -v
```

---

## ✅ Critérios de Avaliação

| Critério | Peso | Descrição |
|----------|------|-----------|
| Dockerfiles funcionais | 25% | Ambos Dockerfiles buildam e rodam localmente |
| docker-compose completo | 20% | 3 serviços (api, web, db) com health checks |
| Pipeline do backend | 20% | Lint → test → build → push funcionando |
| Pipeline do frontend | 20% | Lint → test → build → push funcionando |
| Arquivo principal com include | 5% | `.gitlab-ci.yml` inclui os dois pipelines |
| Boas práticas Docker | 10% | Multi-stage, usuário não-root, health checks |

---

## 📚 Referências

- [DockerHub — Repositórios](https://hub.docker.com/)
- [Docker — Boas práticas para Dockerfiles](https://docs.docker.com/develop/develop-images/dockerfile_best-practices/)
- [FastAPI — Implantação com Docker](https://fastapi.tiangolo.com/deployment/docker/)
- [Next.js — Implantação com Docker](https://nextjs.org/docs/pages/building-your-application/deploying#docker-image)
- [GitLab CI/CD — Documentação](https://docs.gitlab.com/ee/ci/)
- [GitLab CI/CD — Include](https://docs.gitlab.com/ee/ci/yaml/includes.html)
- [GitLab CI/CD — Rules](https://docs.gitlab.com/ee/ci/yaml/#rules)
- [PostgreSQL — Docker Hub](https://hub.docker.com/_/postgres)
- [CondoCombat — Backend](../../backend/)
- [CondoCombat — Frontend](../../frontend/)

---

## 💡 Dicas

1. **Monorepo com `rules:changes`**: O projeto CondoCombat é um monorepo com `landing/`, `frontend/` e `backend/`. Use `rules:changes` para que cada pipeline só execute quando os arquivos do seu diretório forem alterados. Isso evita execuções desnecessárias.

2. **Docker-in-Docker (dind)**: O GitLab CI/CD usa o serviço `docker:dind` (Docker in Docker) para executar comandos Docker dentro do pipeline. Sem ele, o `docker build` e `docker push` não funcionam. A variável `DOCKER_TLS_CERTDIR: ""` é necessária para desabilitar TLS no dind.

3. **DockerHub Token**: Prefira tokens de acesso em vez de senha. Crie em DockerHub → Account Settings → Security. Use o token como valor da variável `DOCKERHUB_TOKEN`.

4. **Tags**: Use tags semânticas (`v1.0.0`, `v1.1.0`) em vez de `latest` para produção. O `latest` é suficiente para este desafio, mas em projetos reais prefira versionamento.

5. **entrypoint.sh**: Não esqueça de dar permissão de execução: `chmod +x backend/entrypoint.sh`. Sem isso o container vai falhar ao iniciar.

6. **SECRET_KEY**: O backend valida a SECRET_KEY na inicialização. Se não for definida, o container vai crashar com um `ValueError`. Sempre defina essa variável.

7. **Cache do Docker**: A ordem das instruções no Dockerfile importa. Coloque `COPY requirements.txt` antes do código fonte para aproveitar o cache de camadas do Docker.

8. **Cache do pip/npm**: As pipelines configuram cache para `PIP_CACHE_DIR` e `npm_config_cache`. Isso acelera execuções subsequentes ao reutilizar pacotes já baixados.

9. **Variáveis Protegidas**: Marque `DOCKERHUB_TOKEN` e `SECRET_KEY` como "Masked" no GitLab. Se a branch `main` for protegida, marque também como "Protected" para que só pipelines da `main` tenham acesso.

10. **Health checks**: Todos os contêineres no docker-compose incluem health checks. O backend depende do banco estar saudável (`condition: service_healthy`), garantindo a ordem correta de inicialização.

---

> **⚠️ Aviso**
>
> **Não há etapa de deploy.** A pipeline termina no push das imagens para o DockerHub.
>
> Escolha a plataforma desejada abaixo:
>
> | Plataforma | Arquivo |
> |-----------|---------|
> | 🐙 GitHub Actions | [`README.github.md`](./README.github.md) |
> | 🦊 GitLab CI/CD | [`README.gitlab.md`](./README.gitlab.md) |
