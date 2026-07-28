FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

RUN groupadd --system aiclip && useradd --system --gid aiclip --home /srv/app aiclip
WORKDIR /srv/app
COPY requirements.txt .
RUN pip install --requirement requirements.txt
COPY app ./app
USER aiclip
EXPOSE 8080
CMD ["sh", "-c", "exec uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8080} --proxy-headers --forwarded-allow-ips='*'"]
