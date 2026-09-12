# Build context = repo root:  docker build -f docker/agent.Dockerfile -t agent-nhi/agent:demo .
#
# The agent image deliberately contains NO secrets — not even a placeholder.
# It idles (sleep infinity); demo.sh execs agent.py inside it so each run
# fetches a fresh SVID live in front of the audience.
FROM python:3.13-slim
WORKDIR /app
COPY src/agent/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt
COPY src/shared /app/shared
COPY src/agent /app
CMD ["sleep", "infinity"]
