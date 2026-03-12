# My Evernote - Reverse-Engineered API Map

## Architecture Overview

Evernote's web client uses **ion-conduit** - a Web Worker-based sync engine with local SQLite (WASM).
Note CRUD operations happen locally in SQLite and sync via Thrift binary protocol through the conduit worker.
The REST APIs below are used for auth, settings, billing, resources, and AI features.

## Authentication Flow (OAuth2 PKCE)

### 1. Check Email
```
POST https://accounts.evernote.com/api/checkEmail
Content-Type: application/x-www-form-urlencoded

email={email}&hCaptchaResponse={token}

Response: {"status":"success","isCodeLoginEnabled":false}
```

### 2. Check Password
```
POST https://accounts.evernote.com/api/checkPassword
Content-Type: application/x-www-form-urlencoded

email={email}&password={password}&hCaptchaResponse={token}

Response: {"status":"verify2FA"} or {"status":"success"}
```

### 3. Check 2FA (if enabled)
```
POST https://accounts.evernote.com/api/check2FA
Content-Type: application/x-www-form-urlencoded

totp={code}

Response: {"status":"success"}
```

### 4. Get Auth Token
```
POST https://accounts.evernote.com/auth/token
Content-Type: application/json

{
  "code": "{authorization_code}",
  "code_verifier": "{pkce_verifier}",
  "client_id": "evernote-web-client",
  "redirect_uri": "https://www.evernote.com/client/web",
  "grant_type": "authorization_code"
}

Response: {
  "access_token": "eyJ...(JWT containing mono_authn_token)",
  "token_type": "bearer",
  "expires_in": 3600,
  "refresh_token": "..."
}
```

The JWT `access_token` contains a `mono_authn_token` field which is the classic Evernote Thrift auth token:
`S=s24:U=...:E=...:C=...:P=...:A=...:V=...:H=...`

## API Endpoints

### Identity & Settings
```
POST https://api.evernote.com/bsp/v1/orion/identity/settings
Authorization: Bearer {access_token}

Body: {
  "device_environment": "production",
  "device_id": "{uuid}",
  "app_version": "11.4.4",
  "build_number": 11004004,
  "product_user_id": "EN{userId}",
  "app_language": "en",
  "user_service_level": "ADVANCED",
  "bsp_id": "evernote_web"
}
```

### Messages/Notifications
```
POST https://api.evernote.com/bsp/v1/messages/pull
Authorization: Bearer {access_token}

Body: {"product_user_id":"EN{userId}","bsp_id":"evernote_web"}
Response: {"messages":[]}
```

### AI Copilot
```
POST https://api.evernote.com/v1/ai/copilot/send
Authorization: Bearer {access_token}

Body: JSON string with type and params, e.g.:
{
  "type": "threads.list",
  "params": {"limit":9999,"order":"desc"},
  "metadata": {
    "current_note_id": null,
    "current_notebook_id": null,
    ...
  }
}
```

### Billing
```
GET https://www.evernote.com/billy/api/v1/paymentmethod
GET https://www.evernote.com/billy/api/consumer/nextServiceLevel
GET https://www.evernote.com/billy/api/consumer/paymentTerm
```

### Resources & Files
```
GET https://www.evernote.com/file/v1/f/{fileId}
GET https://public.www.evernote.com/resources/s24/{resourceId}
GET https://public.www.evernote.com/resources/note/thumbnail/s24/{noteId}?t={timestamp}
GET https://www.evernote.com/shard/s24/user/{userId}/photo?t=0&size=56
```

### Feature Flags
```
GET https://update.evernote.com/enclients/web/features_rollout.json
```

## Conduit/Sync Layer

The conduit uses two Web Workers:
- `IonConduitWorker.action?type=conduit` - main conduit worker (Thrift sync)
- `IonConduitWorker.action?type=sqlite` - SQLite WASM worker

Communication uses **Comlink** (proxy-based RPC over MessageChannel).
Data syncs via Thrift binary protocol to Evernote's NoteStore.

### Classic Thrift API (via mono_authn_token)

The `mono_authn_token` from the JWT can be used with Evernote's classic Thrift endpoints:
- `https://www.evernote.com/shard/s{N}/notestore` - NoteStore
- `https://www.evernote.com/edam/user` - UserStore

Key: `s24` = shard ID, `3040484` = user ID

## Key Constants
- Client ID: `evernote-web-client`
- Consumer Key: `en-web`
- App Version: `11.4.4`
- Conduit Version: `2.97.0`
- hCaptcha Site Key: `9236f198-f154-4aa9-8f4d-2e7ce9aedb5b`
