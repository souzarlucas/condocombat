#!/bin/sh
set -eu

if [ -z "${SECRET_KEY:-}" ]; then
    echo "ERRO: SECRET_KEY não está definida."
    echo "Gere uma com: python -c 'import secrets; print(secrets.token_urlsafe(32))'"
    exit 1
fi

echo "Rodando migrations do Alembic..."
alembic upgrade head

echo "Iniciando servidor FastAPI..."
exec uvicorn app.main:app --host 0.0.0.0 --port 8000
