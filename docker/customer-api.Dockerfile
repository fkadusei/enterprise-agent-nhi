# Build context = repo root:  docker build -f docker/customer-api.Dockerfile -t agent-nhi/customer-api:demo .
FROM python:3.13-slim
WORKDIR /app
COPY src/customer_api/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt
COPY src/shared /app/shared
COPY src/customer_api /app
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "9000"]
