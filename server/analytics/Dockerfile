FROM python:3.12-slim
WORKDIR /app
COPY download_gateway.py /app/download_gateway.py
USER 65534:65534
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 GATEWAY_BIND=0.0.0.0
EXPOSE 8080
CMD ["python", "/app/download_gateway.py"]
