# 🏗️ Desafio 2 — Docker + CI/CD do Backend e Frontend (CondoCombat)

## 🎯 Objetivo

Criar **Dockerfiles** e um **docker-compose.yml** para o backend (FastAPI) e frontend (Next.js) do CondoCombat, e configurar **2 pipelines separadas** de **Integração Contínua (CI)** no GitHub Actions que executam lint, testes, build e push das imagens para o **DockerHub**.

As pipelines devem:

1. **Pipeline do Backend**: Executar lint (Ruff) → testes (pytest) → build Docker → push DockerHub
2. **Pipeline do Frontend**: Executar lint (ESLint) → testes (Vitest) → build Docker → push DockerHub
3. **Rodar localmente** com Docker Compose usando as imagens publicadas

Pipelines configuradas como **arquivos separados** no GitHub Actions.

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

2. **Conta no GitHub**
   - Repositório do CondoCombat forkado ou clonado

3. **Docker instalado localmente**
   - Para testar os Dockerfiles
   - Para rodar o docker-compose

4. **Permissões de escrita** no repositório GitHub

---

## 🔐 Variáveis de Ambiente (Secrets)

Configure estes secrets no repositório GitHub (Settings → Secrets and variables → Actions):

| Secret | Valor | Descrição |
|--------|-------|-----------|
| `DOCKERHUB_USERNAME` | Seu usuário DockerHub | Username para login |
| `DOCKERHUB_TOKEN` | Access Token do DockerHub | Token em vez de senha |
| `SECRET_KEY` | Chave JWT de 32 caracteres | Backend valida na inicialização |

**Como gerar a SECRET_KEY**:
```bash
python -c 'import secrets; print(secrets.token_urlsafe(32))'
```

---

## 🏗️ Criando o Dockerfile do Backend

Crie o arquivo `backend/Dockerfile` com **multi-stage build** em 3 estágios:

### Etapas

1. **Stage 1 (deps)**: Instala dependências Python
2. **Stage 2 (builder)**: Copia código fonte
3. **Stage 3 (runner)**: Imagem final com usuário não-root

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

Crie o arquivo `.github/workflows/backend.yml`:

```yaml
# =============================================================================
# Pipeline do Backend — Lint → Test → Build → Push
# =============================================================================
name: Backend CI

on:
  push:
    branches: [main]
    paths: ['backend/**']
  pull_request:
    branches: [main]
    paths: ['backend/**']

jobs:
  lint:
    name: Lint Backend
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set up Python
        uses: actions/setup-python@v4
        with:
          python-version: '3.12'

      - name: Install Ruff
        run: pip install ruff

      - name: Run Ruff
        working-directory: ./backend
        run: ruff check app/

  test:
    name: Test Backend
    runs-on: ubuntu-latest
    needs: lint
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set up Python
        uses: actions/setup-python@v4
        with:
          python-version: '3.12'

      - name: Install dependencies
        working-directory: ./backend
        run: |
          pip install -e .
          pip install pytest pytest-asyncio httpx aiosqlite

      - name: Run tests
        working-directory: ./backend
        env:
          SECRET_KEY: test-secret-key-for-ci-only
          DATABASE_URL: sqlite+aiosqlite:///test.db
        run: pytest __tests__/ -v

  build-and-push:
    name: Build and Push Docker Image
    runs-on: ubuntu-latest
    needs: test
    if: github.ref == 'refs/heads/main'
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Login to DockerHub
        uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}

      - name: Build and push
        uses: docker/build-push-action@v5
        with:
          context: ./backend
          file: ./backend/Dockerfile
          push: true
          tags: |
            ${{ secrets.DOCKERHUB_USERNAME }}/condocombat-backend:latest
            ${{ secrets.DOCKERHUB_USERNAME }}/condocombat-backend:${{ github.sha }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

---

## 📝 Pipeline do Frontend

Crie o arquivo `.github/workflows/frontend.yml`:

```yaml
# =============================================================================
# Pipeline do Frontend — Lint → Test → Build → Push
# =============================================================================
name: Frontend CI

on:
  push:
    branches: [main]
    paths: ['frontend/**']
  pull_request:
    branches: [main]
    paths: ['frontend/**']

jobs:
  lint:
    name: Lint Frontend
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set up Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'
          cache-dependency-path: frontend/package-lock.json

      - name: Install dependencies
        working-directory: ./frontend
        run: npm ci

      - name: Run ESLint
        working-directory: ./frontend
        run: npm run lint

  test:
    name: Test Frontend
    runs-on: ubuntu-latest
    needs: lint
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set up Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'
          cache-dependency-path: frontend/package-lock.json

      - name: Install dependencies
        working-directory: ./frontend
        run: npm ci

      - name: Run tests
        working-directory: ./frontend
        run: npm run test

  build-and-push:
    name: Build and Push Docker Image
    runs-on: ubuntu-latest
    needs: test
    if: github.ref == 'refs/heads/main'
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Login to DockerHub
        uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}

      - name: Build and push
        uses: docker/build-push-action@v5
        with:
          context: ./frontend
          file: ./frontend/Dockerfile
          push: true
          tags: |
            ${{ secrets.DOCKERHUB_USERNAME }}/condocombat-frontend:latest
            ${{ secrets.DOCKERHUB_USERNAME }}/condocombat-frontend:${{ github.sha }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

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
| Pipeline do backend | 25% | Lint → test → build → push funcionando |
| Pipeline do frontend | 20% | Lint → test → build → push funcionando |
| Boas práticas Docker | 10% | Multi-stage, usuário não-root, health checks |

---

## 📚 Referências

- [DockerHub — Repositórios](https://hub.docker.com/)
- [Docker — Boas práticas para Dockerfiles](https://docs.docker.com/develop/develop-images/dockerfile_best-practices/)
- [FastAPI — Implantação com Docker](https://fastapi.tiangolo.com/deployment/docker/)
- [Next.js — Implantação com Docker](https://nextjs.org/docs/pages/building-your-application/deploying#docker-image)
- [GitHub Actions — Documentação](https://docs.github.com/en/actions)
- [PostgreSQL — Docker Hub](https://hub.docker.com/_/postgres)
- [CondoCombat — Backend](../../backend/)
- [CondoCombat — Frontend](../../frontend/)

---

## 💡 Dicas

1. **Monorepo paths**: Os workflows usam `paths: ['backend/**']` e `paths: ['frontend/**']` para evitar execuções desnecessárias quando só o backend ou frontend mudar.

2. **Teste local com act**: Use [act](https://github.com/nektos/act) para testar as pipelines localmente:
   ```bash
   act -j lint-backend --container-architecture linux/amd64
   act -j test-frontend --container-architecture linux/amd64
   ```

3. **DockerHub Token**: Prefira tokens de acesso em vez de senha. Crie em DockerHub → Account Settings → Security.

4. **Cache do Docker**: As pipelines usam `cache-from` e `cache-to` do GitHub Actions para acelerar builds subsequentes.

5. **entrypoint.sh**: Não esqueça de dar permissão de execução: `chmod +x backend/entrypoint.sh`.

6. **SECRET_KEY**: O backend valida a SECRET_KEY na inicialização. Se não for definida, o container vai crashar com um `ValueError`.

7. **Health checks**: Todos os contêineres incluem health checks para o Docker Compose esperar que estejam saudáveis.

8. **Volumes PostgreSQL**: O volume `pgdata` garante persistência dos dados entre reinicializações.