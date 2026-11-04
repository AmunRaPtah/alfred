FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        espeak-ng \
        ffmpeg \
        git \
    && rm -rf /var/lib/apt/lists/*

# HF Spaces docker runtime executes as uid 1000 by convention; make a
# writable home + HF cache dir so model downloads at startup don't fail
# on permission errors.
RUN useradd -m -u 1000 alfred
ENV HOME=/home/alfred \
    HF_HOME=/home/alfred/.cache/huggingface \
    PYTHONUNBUFFERED=1 \
    PORT=7860

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

RUN mkdir -p $HF_HOME && chown -R alfred:alfred /app /home/alfred

USER alfred

EXPOSE 7860

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "7860"]
