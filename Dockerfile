# 核心镜像：Node 22 slim 保证了环境的现代性与轻量化
FROM node:22-slim

# 1. 安装系统依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    git openssh-client build-essential python3 python3-pip \
    g++ make ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# 2. 安装 Hugging Face 命令行工具
RUN pip3 install --no-cache-dir huggingface_hub --break-system-packages

# 3. 构建环境优化
RUN update-ca-certificates && \
    git config --global http.sslVerify false && \
    git config --global url."https://github.com/".insteadOf ssh://git@github.com/

# 4. 全局安装 OpenClaw
RUN npm install -g openclaw@latest --unsafe-perm

# 5. 设置环境变量
ENV PORT=7860 \
    OPENCLAW_GATEWAY_MODE=local \
    HOME=/root

# 6. 核心同步引擎 (sync.py)
RUN echo 'import os, sys, tarfile\n\
from huggingface_hub import HfApi, hf_hub_download\n\
from datetime import datetime, timedelta\n\
api = HfApi()\n\
repo_id = os.getenv("HF_DATASET")\n\
token = os.getenv("HF_TOKEN")\n\
\n\
def restore():\n\
    try:\n\
        print(f"--- [SYNC] 启动恢复流程, 目标仓库: {repo_id} ---")\n\
        if not repo_id or not token: \n\
            print("--- [SYNC] 跳过恢复: 未配置 HF_DATASET 或 HF_TOKEN ---")\n\
            return False\n\
        files = api.list_repo_files(repo_id=repo_id, repo_type="dataset", token=token)\n\
        now = datetime.now()\n\
        for i in range(5):\n\
            day = (now - timedelta(days=i)).strftime("%Y-%m-%d")\n\
            name = f"backup_{day}.tar.gz"\n\
            if name in files:\n\
                print(f"--- [SYNC] 发现备份文件: {name}, 正在下载... ---")\n\
                path = hf_hub_download(repo_id=repo_id, filename=name, repo_type="dataset", token=token)\n\
                with tarfile.open(path, "r:gz") as tar: tar.extractall(path="/root/.openclaw/")\n\
                print(f"--- [SYNC] 恢复成功! 数据已覆盖至 /root/.openclaw/ ---")\n\
                return True\n\
        print("--- [SYNC] 未找到最近 5 天的备份包 ---")\n\
    except Exception as e: print(f"--- [SYNC] 恢复异常: {e} ---")\n\
\n\
def backup():\n\
    try:\n\
        day = datetime.now().strftime("%Y-%m-%d")\n\
        name = f"backup_{day}.tar.gz"\n\
        print(f"--- [SYNC] 正在执行全量备份: {name} ---")\n\
        with tarfile.open(name, "w:gz") as tar:\n\
            for target in ["sessions", "workspace", "agents", "memory", "openclaw.json"]:\n\
                full_path = f"/root/.openclaw/{target}"\n\
                if os.path.exists(full_path):\n\
                    tar.add(full_path, arcname=target)\n\
        api.upload_file(path_or_fileobj=name, path_in_repo=name, repo_id=repo_id, repo_type="dataset", token=token)\n\
        print(f"--- [SYNC] 备份上传成功! ---")\n\
    except Exception as e: print(f"--- [SYNC] 备份失败: {e} ---")\n\
\n\
if __name__ == "__main__":\n\
    if len(sys.argv) > 1 and sys.argv[1] == "backup": backup()\n\
    else: restore()' > /usr/local/bin/sync.py

# 7. 容器入口脚本 (start-openclaw)
RUN echo '#!/bin/bash\n\
set -e\n\
mkdir -p /root/.openclaw/sessions\n\
mkdir -p /root/.openclaw/workspace\n\
\n\
python3 /usr/local/bin/sync.py restore\n\
\n\
CLEAN_BASE=$(echo "$OPENAI_API_BASE" | sed "s|/chat/completions||g" | sed "s|/v1/|/v1|g" | sed "s|/v1$|/v1|g")\n\
\n\
cat > /root/.openclaw/openclaw.json <<EOF\n\
{\n\
  "models": {\n\
    "providers": {\n\
      "siliconflow": {\n\
        "baseUrl": "$CLEAN_BASE",\n\
        "apiKey": "$OPENAI_API_KEY",\n\
        "api": "openai-completions",\n\
        "models": [{ "id": "$MODEL", "name": "DeepSeek", "contextWindow": 128000 }]\n\
      }\n\
    }\n\
  },\n\
  "agents": { "defaults": { "model": { "primary": "siliconflow/$MODEL" } } },\n\
  "gateway": {\n\
    "mode": "local", "bind": "lan", "port": $PORT,\n\
    "trustedProxies": ["0.0.0.0/0", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"],\n\
    "auth": { "mode": "token", "token": "${OPENCLAW_GATEWAY_PASSWORD:-Cen156159.}" },\n\
    "controlUi": { \n\
      "allowInsecureAuth": true,\n\
      "allowedOrigins": ["https://guolicen-openclaw-ai.hf.space"]\n\
    }\n\
  }\n\
}\n\
EOF\n\
\n\
(while true; do sleep 10800; python3 /usr/local/bin/sync.py backup; done) &\n\
\n\
openclaw doctor --fix\n\
exec openclaw gateway run --port $PORT\n\
' > /usr/local/bin/start-openclaw && chmod +x /usr/local/bin/start-openclaw

EXPOSE 7860
CMD ["/usr/local/bin/start-openclaw"]
