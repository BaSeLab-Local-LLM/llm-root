sudo cp /home/miruware/llm-root/deploy/systemd/ngrok-vercel-sync.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ngrok-vercel-sync.service
sudo systemctl status ngrok-vercel-sync.service
journalctl -u ngrok-vercel-sync.service -f


# 즉시 1회만 검사
/home/miruware/llm-root/scripts/sync_ngrok_vercel.sh --once
