# Build context = repo root:  docker build -f docker/tool-server.Dockerfile -t agent-nhi/tool-server:demo .
FROM python:3.13-slim
WORKDIR /app
COPY src/tool_server/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt
COPY src/shared /app/shared
COPY src/tool_server /app
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
