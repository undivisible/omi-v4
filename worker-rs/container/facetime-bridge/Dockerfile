FROM python:3.12-slim-bookworm

# Agora's Server Gateway SDK ships a native x86_64-linux-gnu shared object, so
# the image is glibc and amd64 by construction. Cloudflare Containers require
# linux/amd64 anyway.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY bridge.py /app/bridge.py

# Nothing is written to disk and nothing is bound outward except the control
# port the Durable Object talks to.
RUN useradd --create-home --uid 10001 bridge
USER bridge

EXPOSE 8080

CMD ["python", "/app/bridge.py"]
