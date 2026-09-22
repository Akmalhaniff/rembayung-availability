FROM mcr.microsoft.com/powershell:7.4-ubuntu-22.04
RUN apt-get update && apt-get install -y git cron && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY fetch-availability.ps1 .
COPY availability.json opened.json* ./
RUN git config --global user.name "rembayung-bot" && git config --global user.email "bot@fly.io"
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh
CMD ["/app/start.sh"]
