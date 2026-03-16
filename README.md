# OpenCode Docker

Docker image for OpenCode with essential development tools.

## Included Tools

- Node.js 22
- Python 3
- Git
- Go (install via script if needed)
- Vim / Nano
- Tmux
- OpenCode CLI (`opencode-ai`)

## Required Environment Variables

| Variable | Description |
|----------|-------------|
| `OPENCODE_SERVER_USERNAME` | Server username |
| `OPENCODE_SERVER_PASSWORD` | Server password |

The container will exit immediately if these variables are not set.

## Usage

```bash
docker run -d \
  -e OPENCODE_SERVER_USERNAME=your_username \
  -e OPENCODE_SERVER_PASSWORD=your_password \
  -p 4096:4096 \
  -v $(pwd)/workspace:/workspace \
  ghcr.io/your-org/opencode-docker:latest
```

## Docker Compose

```yaml
version: '3.8'
services:
  opencode:
    image: ghcr.io/your-org/opencode-docker:latest
    environment:
      - OPENCODE_SERVER_USERNAME=your_username
      - OPENCODE_SERVER_PASSWORD=your_password
    ports:
      - "4096:4096"
    volumes:
      - ./workspace:/workspace
```
