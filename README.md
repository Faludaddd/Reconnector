# Reconnector

A native iOS app and Python backend that replaces Discord for controlling a Roblox farming bot on Android.

## Architecture

```
┌─────────────────┐         HTTP + WebSocket         ┌──────────────────────────┐
│                 │ ←──────────────────────────────→ │                          │
│  iPhone (iOS)   │    (Local WiFi, port 8080)       │  Android Tablet (Termux) │
│                 │                                  │                          │
│  SwiftUI App    │                                  │  Python FastAPI Server   │
└─────────────────┘                                  └──────────────────────────┘
```

## Setup

### Backend (Android/Termux)

1. Install dependencies:
   ```bash
   pkg install python python-pip
   pip install fastapi uvicorn websockets
   ```

2. Create `.env` file:
   ```bash
   echo "AUTH_TOKEN=your_secret_token_here" > ~/reconnector/.env
   ```

3. Start the server:
   ```bash
   python ~/reconnector/Backend/reconnector_api.py
   ```

### iOS App

1. Open `iOS/Reconnector.xcodeproj` in Xcode.
2. Build and install on your iPhone.
3. Open the app, go to Settings, enter your tablet's IP address and the auth token.
