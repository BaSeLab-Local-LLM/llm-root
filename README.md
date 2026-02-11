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
