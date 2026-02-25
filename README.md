# BaSE Lab Local LLM

GPU 서버에서 로컬 LLM을 운영하기 위한 플랫폼입니다.

## 구성 요소

| 서비스 | 설명 |
|---|---|
| **vLLM** | GPU 가속 LLM 추론 서버 (비전 모델 지원) |
| **LiteLLM** | OpenAI 호환 API 게이트웨이 |
| **Backend** | FastAPI 기반 인증/채팅/파일업로드 API |
| **Frontend** | React 웹 UI (Nginx) |
| **PostgreSQL** | 사용자, API 키, 대화 내역 저장 |

## 멀티모달 지원

이미지와 문서를 첨부하여 LLM에 질문할 수 있습니다.

- **지원 이미지**: JPEG, PNG, GIF, WebP, BMP
- **지원 문서**: PDF, DOCX, XLSX, CSV, TXT
- **모델**: Qwen2.5-VL-3B-Instruct (비전 언어 모델)
- 이미지는 서버에서 자동 리사이즈 후 비전 모델에 직접 전달됩니다
- 문서는 텍스트로 추출되어 LLM에 전달됩니다

## 환경 설정

`.env.example`을 기반으로 환경에 맞는 설정 파일을 생성합니다.

### 로컬 개발 환경

```bash
cp .env.example .env.local
```

`.env.local`을 열어 아래 값들을 수정합니다:

```dotenv
DEPLOY_ENV=local
DEBUG=true
ALLOWED_ORIGINS=http://localhost:3000

# 시크릿 생성 후 입력
POSTGRES_PASSWORD=<openssl rand -hex 16>
JWT_SECRET_KEY=<openssl rand -hex 32>
LITELLM_MASTER_KEY=<echo "sk-master-$(openssl rand -hex 24)">
LITELLM_SALT_KEY=<openssl rand -hex 16>
LITELLM_UI_PASSWORD=<openssl rand -base64 18>
```

### 서버 배포 환경

```bash
cp .env.example .env.server
```

`.env.server`를 열어 아래 값들을 수정합니다:

```dotenv
DEPLOY_ENV=production
DEBUG=false
ALLOWED_ORIGINS=https://your-domain.com
LOG_LEVEL=WARNING

# 시크릿 생성 후 입력 (로컬과 다른 값 사용)
POSTGRES_PASSWORD=<openssl rand -hex 16>
JWT_SECRET_KEY=<openssl rand -hex 32>
LITELLM_MASTER_KEY=<echo "sk-master-$(openssl rand -hex 24)">
LITELLM_SALT_KEY=<openssl rand -hex 16>
LITELLM_UI_PASSWORD=<openssl rand -base64 18>
```

## 배포

### 최초 실행 (시딩 포함)

```bash
# 로컬
docker compose --env-file .env.local up -d

# 서버
docker compose --env-file .env.server up -d
```

최초 실행 시 `seed` 서비스가 자동으로 관리자 + 학생 계정을 생성합니다.
이후 재시작 시에는 DB에 사용자가 이미 존재하면 시딩을 건너뜁니다.

### 재시작 / 업데이트

```bash
# 전체 재시작
docker compose --env-file .env.local down
docker compose --env-file .env.local up -d

# 특정 서비스만 재빌드
docker compose --env-file .env.local build backend frontend
docker compose --env-file .env.local up -d backend frontend
```

### DB 초기화 (시딩 재실행)

```bash
docker compose --env-file .env.local down
docker volume rm llm-postgres-data
docker compose --env-file .env.local up -d
```

## ngrok으로 외부 접속 (선택)

기존 compose 파일을 그대로 사용하고, `docker-compose.ngrok.yml`만 오버라이드해서 터널을 추가합니다.

`.env.local` 또는 `.env.server`에 아래 값을 설정합니다:

```dotenv
NGROK_AUTHTOKEN=<ngrok token>
NGROK_TARGET=api-proxy:80
NGROK_BASIC_AUTH=<user:strong-password>
# NGROK_DOMAIN=<reserved-domain.ngrok-free.app>  # 선택
```

실행:

```bash
# 로컬 기본 구성 + ngrok
docker compose --env-file .env.local -f docker-compose.yml -f docker-compose.ngrok.yml up -d

# 서버 구성 + ngrok
docker compose --env-file .env.server -f docker-compose.server.yml -f docker-compose.ngrok.yml up -d
```

터널 URL 확인:

```bash
curl -s http://127.0.0.1:4040/api/tunnels
```

기본값(`NGROK_TARGET=api-proxy:80`)이면 ngrok URL이 API 프록시로 바로 연결됩니다.

## Vercel 프론트엔드 + API 프록시(502 방지)

Vercel에서 `/api/*`를 서버의 `:8080`으로 직접 rewrite할 때 502가 발생하면,
서버에 API 전용 리버스 프록시(`llm-api-proxy`, 포트 80/443)를 함께 띄우세요.

실행:

```bash
docker compose \
  --env-file .env.server \
  -f docker-compose.server.yml \
  -f docker-compose.api-proxy.yml \
  up -d backend api-proxy
```

Vercel `vercel.json` 예시:

```json
{
  "rewrites": [
    {
      "source": "/api/:path*",
      "destination": "https://<SERVER_IP>.nip.io/api/:path*"
    }
  ]
}
```

추가 권장:

- `.env.server`의 `BIND_ADDRESS=127.0.0.1` 유지 (백엔드 직접 외부 노출 최소화)
- `ALLOWED_ORIGINS`에 Vercel 도메인/커스텀 도메인 명시

## ngrok URL 자동 반영 (free 플랜)

ngrok free URL이 바뀔 때마다 `submodules/frontend/vercel.json`을 자동 갱신하고
필요 시 자동 push/배포 트리거를 실행할 수 있습니다.

1. 설정 파일 생성:

```bash
cp deploy/ngrok-sync.env.example deploy/ngrok-sync.env
```

2. 필요 값 수정:

- `AUTO_PUSH=true` 유지 시 `vercel.json` 변경 커밋 + `origin/main` push
- 자동 push를 쓰면 `GITHUB_USERNAME`, `GITHUB_TOKEN`(Fine-grained PAT) 설정
- `VERCEL_DEPLOY_HOOK_URL` 지정 시 push 후 Deploy Hook 호출
- GitHub 인증(credential helper/PAT)이 서버에서 동작해야 자동 push 가능

3. 단발 테스트:

```bash
./scripts/sync_ngrok_vercel.sh --once
```

4. systemd 등록:

```bash
sudo cp deploy/systemd/ngrok-vercel-sync.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ngrok-vercel-sync.service
sudo systemctl status ngrok-vercel-sync.service
```

## 기본 계정

| 계정 | 아이디 | 비밀번호 | 비고 |
|---|---|---|---|
| 관리자 | `admin` | `1234` | 첫 로그인 후 변경 권장 |
| 학생 | `1` ~ `100` | `1234` | 첫 로그인 후 변경 권장 |

## 주요 URL

| 환경 | 프론트엔드 | 백엔드 API | API 문서 (DEBUG=true) |
|---|---|---|---|
| 로컬 | `http://localhost:3000` | `http://localhost:8080/api/v1` | `http://localhost:8080/docs` |
| 서버 | `https://your-domain.com` | 리버스 프록시 경유 | 비활성화 |
