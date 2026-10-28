# logwatch analyzer — Python + Anthropic SDK เท่านั้น
FROM python:3.12-slim
RUN pip install --no-cache-dir --disable-pip-version-check anthropic
COPY logwatch.py /app/logwatch.py
# รันเป็น nobody — ไม่มีสิทธิ root ใน container
USER 65534:65534
ENV PYTHONUNBUFFERED=1 HOME=/tmp
ENTRYPOINT ["python", "/app/logwatch.py"]
