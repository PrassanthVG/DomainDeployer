# GitHub Releases & API Automation Guide

This guide explains how automated releases work in this repository (`PrassanthVG/DomainDeployer`), how to interact with GitHub Releases using the REST API for private repositories, and how to automate asset downloads using scripts or webhooks.

---

## 1. Automated Workflow Overview

Every time code is pushed to the `main` branch, the GitHub Actions workflow [`.github/workflows/release.yml`](.github/workflows/release.yml) automatically:
1. Generates a semantic tag and title (e.g. `v1.0.1`, `Release v1.0.1`).
2. Creates a `.zip` archive containing the entire repository code (excluding `.git`).
3. Publishes a GitHub Release and uploads the `.zip` archive as an asset (named `release-<run_number>.zip`).

---

## 2. Authentication Requirements

Since this is a **private repository**, all API requests must include a GitHub Personal Access Token (PAT) with `repo` permissions (or `contents: read`).

Set your token as an environment variable in your terminal/server:

```bash
export GITHUB_TOKEN="ghp_your_actual_token_here"
```

---

## 3. GitHub REST API Endpoints

### 3.1. List All Releases
Fetch all releases in chronological order (latest first):

```bash
curl -s -L \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/PrassanthVG/DomainDeployer/releases"
```

---

### 3.2. Get the Latest Release Info
Fetch the metadata of the latest published release:

```bash
curl -s -L \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/PrassanthVG/DomainDeployer/releases/latest"
```

---

### 3.3. Download the Release Asset (.zip) via API

> [!IMPORTANT]
> To download a **binary asset file** from a private repo:
> 1. You **must** use the asset's API URL (`https://api.github.com/repos/OWNER/REPO/releases/assets/<ASSET_ID>`).
> 2. You **must** set the header `-H "Accept: application/octet-stream"`.
> 3. You **must** use the `-L` (follow redirects) flag.

#### Step-by-Step Shell Script (`download_latest_release.sh`):

```bash
#!/bin/bash
set -e

REPO="PrassanthVG/DomainDeployer"
GITHUB_TOKEN="${GITHUB_TOKEN:-your_token_here}"

echo "Fetching latest release metadata..."
LATEST_RELEASE=$(curl -s -L \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  "https://api.github.com/repos/$REPO/releases/latest")

TAG_NAME=$(echo "$LATEST_RELEASE" | grep -o '"tag_name": *"[^"]*"' | head -n 1 | cut -d '"' -f 4)
ASSET_URL=$(echo "$LATEST_RELEASE" | grep -o 'https://api.github.com/repos/'$REPO'/releases/assets/[0-9]*' | head -n 1)
ASSET_NAME=$(echo "$LATEST_RELEASE" | grep -o '"name": *"release-[0-9]*.zip"' | head -n 1 | cut -d '"' -f 4)

if [ -z "$ASSET_URL" ]; then
    echo "Error: No downloadable asset found for release $TAG_NAME"
    exit 1
fi

ASSET_NAME="${ASSET_NAME:-release.zip}"

echo "Latest Release: $TAG_NAME"
echo "Downloading Asset: $ASSET_NAME from $ASSET_URL"

# Download binary asset
curl -s -L \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Accept: application/octet-stream" \
  "$ASSET_URL" \
  -o "$ASSET_NAME"

echo "Download complete: $ASSET_NAME"

# Optional: Extract zip contents
# unzip -o "$ASSET_NAME" -d "./latest_code"
```

---

### 3.4. Download Source Code Archive Directly (Tarball or Zipball)

If you just want the repository source snapshot at the release tag (without custom uploaded assets):

```bash
# Download Zipball
curl -s -L \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/PrassanthVG/DomainDeployer/zipball/v1.0.1" \
  -o "source_code.zip"

# Download Tarball
curl -s -L \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/PrassanthVG/DomainDeployer/tarball/v1.0.1" \
  -o "source_code.tar.gz"
```

---

## 4. Automation with Webhook (Instant Server Update)

To automatically download code onto your deployment server whenever a new release is published:

### Step 1: Configure Webhook on GitHub
1. Open your repository on GitHub.
2. Go to **Settings** > **Webhooks** > **Add webhook**.
3. **Payload URL**: `https://your-server-domain.com/webhook/github-release`
4. **Content type**: `application/json`
5. **Secret**: `your_webhook_secret_key`
6. Under **Which events would you like to trigger this webhook?**:
   - Choose **Let me select individual events**.
   - Check **Releases** (uncheck *Pushes* if you only want finished releases).
7. Click **Add webhook**.

---

### Step 2: Sample Webhook Receiver Server (Node.js / Express)

```javascript
const express = require('express');
const axios = require('axios');
const fs = require('fs');
const path = require('path');

const app = express();
app.use(express.json());

const GITHUB_TOKEN = process.env.GITHUB_TOKEN;

app.post('/webhook/github-release', async (req, res) => {
  const event = req.body;

  // Trigger only when a new release is published
  if (event.action === 'published' && event.release) {
    const release = event.release;
    console.log(`New release published: ${release.tag_name}`);

    const zipAsset = release.assets.find(a => a.name.endsWith('.zip'));

    if (zipAsset) {
      console.log(`Downloading asset: ${zipAsset.name} from ${zipAsset.url}`);
      
      const response = await axios({
        method: 'get',
        url: zipAsset.url,
        headers: {
          Authorization: `Bearer ${GITHUB_TOKEN}`,
          Accept: 'application/octet-stream',
        },
        responseType: 'stream',
      });

      const destPath = path.join(__dirname, zipAsset.name);
      const writer = fs.createWriteStream(destPath);
      response.data.pipe(writer);

      writer.on('finish', () => {
        console.log(`Successfully saved ${destPath}`);
        // Run deployment script / unzip / docker compose restart here
      });
    }
  }

  res.status(200).send('Webhook processed');
});

app.listen(3000, () => console.log('Webhook server running on port 3000'));
```

---

### Step 3: Sample Python Script (Fetch Latest Release & Extract)

```python
import os
import requests
import zipfile

REPO = "PrassanthVG/DomainDeployer"
TOKEN = os.getenv("GITHUB_TOKEN", "YOUR_TOKEN_HERE")

headers = {
    "Authorization": f"Bearer {TOKEN}",
    "Accept": "application/vnd.github+json",
}

# 1. Get latest release
res = requests.get(f"https://api.github.com/repos/{REPO}/releases/latest", headers=headers)
res.raise_for_status()
release_data = res.json()
print(f"Latest Release Tag: {release_data['tag_name']}")

# 2. Find asset URL
assets = release_data.get("assets", [])
zip_asset = next((a for a in assets if a["name"].endswith(".zip")), None)

if not zip_asset:
    print("No zip asset found.")
    exit(1)

asset_api_url = zip_asset["url"]
file_name = zip_asset["name"]

# 3. Download binary asset
print(f"Downloading {file_name}...")
download_headers = {
    "Authorization": f"Bearer {TOKEN}",
    "Accept": "application/octet-stream",
}
with requests.get(asset_api_url, headers=download_headers, stream=True) as r:
    r.raise_for_status()
    with open(file_name, "wb") as f:
        for chunk in r.iter_content(chunk_size=8192):
            f.write(chunk)

print(f"Downloaded {file_name} successfully.")

# 4. Extract
with zipfile.ZipFile(file_name, 'r') as zip_ref:
    zip_ref.extractall("./deployed_code")
print("Extracted files to ./deployed_code")
```

---

## 5. Summary Cheat Sheet

| Task | HTTP Method | URL / Header |
|---|---|---|
| **List Releases** | `GET` | `https://api.github.com/repos/PrassanthVG/DomainDeployer/releases` |
| **Get Latest Release** | `GET` | `https://api.github.com/repos/PrassanthVG/DomainDeployer/releases/latest` |
| **Download Asset File** | `GET` | Asset URL (`.../releases/assets/<ID>`) with header `Accept: application/octet-stream` |
| **Download Source Zip** | `GET` | `https://api.github.com/repos/PrassanthVG/DomainDeployer/zipball/<TAG>` |
