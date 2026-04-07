# 🚀 Tauri Implementation Guide: Replace Python Tray App

**Quick Start for Converting Your Python Setup to Tauri**

---

## Project Structure (After Migration)

```
odoo_backup_service/
├── src-tauri/                    # Rust backend (replaces Flask)
│   ├── Cargo.toml
│   ├── src/
│   │   ├── main.rs              # Tauri setup
│   │   ├── commands/
│   │   │   ├── mod.rs
│   │   │   ├── backup.rs        # backup_database command
│   │   │   └── minio.rs         # upload_to_minio command
│   │   ├── services/
│   │   │   ├── mod.rs
│   │   │   ├── odoo.rs          # OdooBackupManager (from Python)
│   │   │   ├── minio.rs         # MinIO S3 client
│   │   │   └── scheduler.rs     # Cron scheduler
│   │   └── config.rs            # Configuration loading
│   └── tauri.conf.json          # Tauri config + updater
├── src/                          # TypeScript/Vue frontend
│   ├── components/
│   │   ├── BackupForm.vue
│   │   ├── BackupStatus.vue
│   │   └── Settings.vue
│   ├── App.vue
│   └── main.ts
├── publish.bat                   # Adapted from your Electron version
├── package.json
├── tsconfig.json
└── vite.config.ts               # Frontend build config
```

---

## Step 1: Create Tauri Project

```bash
# Install Tauri CLI
npm install -D @tauri-apps/cli @tauri-apps/api

# Or use create-tauri-app (recommended)
npm install create-tauri-app
npm create tauri-app@latest -- \
  --project-name odoo-backup-service \
  --package-name com.example.backup-service \
  --manager npm \
  --ui vue \
  --typescript \
  --skip-git
```

---

## Step 2: Backend - Port Python Logic to Rust

### 2a. Cargo.toml Dependencies

```toml
[package]
name = "odoo-backup-service"
version = "0.1.0"
edition = "2021"

[build-dependencies]
tauri-build = "2.0"

[dependencies]
tauri = { version = "2.0", features = ["shell-open", "system-tray"] }
tauri-plugin-updater = "2.0"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
tokio = { version = "1", features = ["full"] }
reqwest = { version = "0.11", features = ["json"] }
chrono = { version = "0.4", features = ["serde"] }
chrono-tz = "0.8"  # For timezone like pytz
s3 = { version = "0.4", features = ["use-serde"] }
rusoto_s3 = "0.48"  # Alternative S3 client
schedule = "0.6"  # For cron jobs
log = "0.4"
env_logger = "0.11"
config = "0.13"  # For loading config.py equivalent
dirs = "5.0"  # For file paths
```

### 2b. Main Backend File (src-tauri/src/main.rs)

```rust
// src-tauri/src/main.rs
#![cfg_attr(
  all(not(debug_assertions), target_os = "windows"),
  windows_subsystem = "windows"
)]

mod commands;
mod services;
mod config;

use tauri::SystemTray;
use tauri::command;

#[derive(Clone, serde::Serialize)]
struct Payload {
    args: Vec<String>,
    cwd: String,
}

#[command]
fn greet(name: &str) -> String {
    format!("Hello, {}! You've been greeted from Rust!", name)
}

fn main() {
    // Initialize logger
    env_logger::init();
    
    // Create system tray
    let tray = SystemTray::new()
        .with_menu(
            tauri::SystemTrayMenu::new()
                .add_item(tauri::CustomMenuItem::new("show", "Show"))
                .add_item(tauri::CustomMenuItem::new("quit", "Quit"))
        );

    tauri::Builder::default()
        .setup(|app| {
            // Initialize scheduler in background
            let app_handle = app.handle().clone();
            std::thread::spawn(move || {
                services::scheduler::start_background_tasks(&app_handle);
            });
            Ok(())
        })
        .system_tray(tray)
        .on_system_tray_event(handle_system_tray_event)
        .invoke_handler(tauri::generate_handler![
            commands::backup::backup_database,
            commands::backup::get_backup_status,
            commands::minio::upload_to_minio,
            commands::minio::list_backups,
            commands::settings::get_config,
            commands::settings::update_config,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

fn handle_system_tray_event(
    app: &tauri::AppHandle,
    event: tauri::SystemTrayEvent,
) {
    match event {
        tauri::SystemTrayEvent::MenuItemClick { id, .. } => match id.as_str() {
            "show" => {
                let window = app.get_window("main").unwrap();
                window.show().unwrap();
                window.set_focus().unwrap();
            }
            "quit" => {
                std::process::exit(0);
            }
            _ => {}
        },
        _ => {}
    }
}
```

### 2c. Backup Command (src-tauri/src/commands/backup.rs)

```rust
// src-tauri/src/commands/backup.rs
use tauri::command;
use serde::{Serialize, Deserialize};
use crate::services::odoo::OdooBackupManager;
use crate::config::Config;

#[derive(Serialize, Deserialize, Clone)]
#[serde(crate = "serde")]
pub struct BackupResponse {
    pub success: bool,
    pub message: String,
    pub filename: Option<String>,
    pub timestamp: Option<String>,
}

#[derive(Serialize, Deserialize)]
#[serde(crate = "serde")]
pub struct BackupStatus {
    pub total_backups: u32,
    pub last_backup_time: Option<String>,
    pub last_backup_size: Option<String>,
    pub is_running: bool,
}

/// Backup Odoo database - replaces backup_database() from Python
#[command]
pub async fn backup_database(
    db_name: String,
    backup_format: Option<String>,  // "zip" or "dump"
) -> Result<BackupResponse, String> {
    let format = backup_format.unwrap_or_else(|| "zip".to_string());
    
    // Load config (replaces config.py)
    let config = Config::load().map_err(|e| e.to_string())?;
    
    // Create backup manager instance
    let manager = OdooBackupManager::new(
        config.odoo_url,
        config.odoo_master_password,
        config.local_tz,
    );
    
    // Execute backup
    match manager.backup_database(&db_name, &format).await {
        Ok((filename, size)) => {
            log::info!("Backup successful: {}", filename);
            Ok(BackupResponse {
                success: true,
                message: format!("Database '{}' backed up successfully", db_name),
                filename: Some(filename),
                timestamp: Some(chrono::Local::now().to_rfc3339()),
            })
        }
        Err(e) => {
            log::error!("Backup failed: {}", e);
            Err(format!("Backup failed: {}", e))
        }
    }
}

/// Get backup status - used by UI
#[command]
pub async fn get_backup_status() -> Result<BackupStatus, String> {
    // Read from local database or file system
    // Return statistics about previous backups
    Ok(BackupStatus {
        total_backups: 42,
        last_backup_time: Some("2024-04-01T10:30:00Z".to_string()),
        last_backup_size: Some("1.2 GB".to_string()),
        is_running: false,
    })
}
```

### 2d. MinIO/S3 Command (src-tauri/src/commands/minio.rs)

```rust
// src-tauri/src/commands/minio.rs
use tauri::command;
use serde::{Serialize, Deserialize};
use crate::services::minio::MinioClient;
use crate::config::Config;

#[derive(Serialize, Deserialize, Clone)]
#[serde(crate = "serde")]
pub struct UploadResponse {
    pub success: bool,
    pub message: String,
    pub object_name: Option<String>,
    pub size_mb: Option<f64>,
}

#[derive(Serialize, Deserialize, Clone)]
#[serde(crate = "serde")]
pub struct BackupFile {
    pub name: String,
    pub size_mb: f64,
    pub uploaded_at: String,
}

/// Upload backup file to MinIO - replaces boto3 logic
#[command]
pub async fn upload_to_minio(
    file_path: String,
    bucket: Option<String>,
) -> Result<UploadResponse, String> {
    let bucket = bucket.unwrap_or_else(|| "auto-backup".to_string());
    
    let config = Config::load().map_err(|e| e.to_string())?;
    let client = MinioClient::new(
        &config.minio_url,
        &config.access_key,
        &config.secret_key,
    ).map_err(|e| e.to_string())?;
    
    match client.upload_file(&file_path, &bucket).await {
        Ok((object_name, size_mb)) => {
            log::info!("Uploaded to MinIO: {}", object_name);
            Ok(UploadResponse {
                success: true,
                message: "File uploaded to MinIO successfully".to_string(),
                object_name: Some(object_name),
                size_mb: Some(size_mb),
            })
        }
        Err(e) => {
            log::error!("MinIO upload failed: {}", e);
            Err(format!("Upload failed: {}", e))
        }
    }
}

/// List backups in MinIO bucket
#[command]
pub async fn list_backups(
    bucket: Option<String>,
) -> Result<Vec<BackupFile>, String> {
    let bucket = bucket.unwrap_or_else(|| "auto-backup".to_string());
    
    let config = Config::load().map_err(|e| e.to_string())?;
    let client = MinioClient::new(
        &config.minio_url,
        &config.access_key,
        &config.secret_key,
    ).map_err(|e| e.to_string())?;
    
    client.list_backups(&bucket).await
        .map_err(|e| format!("Failed to list backups: {}", e))
}
```

### 2e. OdooBackupManager Service (src-tauri/src/services/odoo.rs)

```rust
// src-tauri/src/services/odoo.rs
use reqwest::Client;
use serde::Deserialize;

pub struct OdooBackupManager {
    odoo_url: String,
    master_password: String,
    local_tz: String,
    client: Client,
}

impl OdooBackupManager {
    pub fn new(odoo_url: String, master_password: String, local_tz: String) -> Self {
        Self {
            odoo_url: odoo_url.trim_end_matches('/').to_string(),
            master_password,
            local_tz,
            client: Client::new(),
        }
    }
    
    pub async fn backup_database(
        &self,
        db_name: &str,
        backup_format: &str,
    ) -> Result<(String, String), String> {
        let url = format!("{}/web/database/backup", self.odoo_url);
        
        let params = [
            ("master_pwd", self.master_password.as_str()),
            ("name", db_name),
            ("backup_format", backup_format),
        ];
        
        let response = self.client
            .post(&url)
            .form(&params)
            .send()
            .await
            .map_err(|e| format!("Request failed: {}", e))?;
        
        if response.status() != 200 {
            return Err(format!("Backup failed with status: {}", response.status()));
        }
        
        // Extract content-length for file size
        let size = response
            .headers()
            .get("content-length")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("0");
        
        // Generate filename
        let now = chrono::Local::now().format("%Y-%m-%d_%H-%M-%S");
        let extension = if backup_format == "zip" { "zip" } else { "dump" };
        let filename = format!("{}_{}.{}", db_name, now, extension);
        
        Ok((filename, size.to_string()))
    }
}
```

### 2f. MinIO Service (src-tauri/src/services/minio.rs)

```rust
// src-tauri/src/services/minio.rs
use std::path::Path;

pub struct MinioClient {
    // In production, use: https://crates.io/crates/s3
    endpoint: String,
    access_key: String,
    secret_key: String,
}

#[derive(serde::Serialize, Clone)]
pub struct BackupFile {
    pub name: String,
    pub size_mb: f64,
    pub uploaded_at: String,
}

impl MinioClient {
    pub fn new(
        endpoint: &str,
        access_key: &str,
        secret_key: &str,
    ) -> Result<Self, String> {
        Ok(Self {
            endpoint: endpoint.to_string(),
            access_key: access_key.to_string(),
            secret_key: secret_key.to_string(),
        })
    }
    
    pub async fn upload_file(
        &self,
        file_path: &str,
        bucket: &str,
    ) -> Result<(String, f64), String> {
        let path = Path::new(file_path);
        let file_size = std::fs::metadata(path)
            .map_err(|e| e.to_string())?
            .len() as f64 / (1024.0 * 1024.0);
        
        let object_name = path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("unknown")
            .to_string();
        
        // TODO: Implement actual S3 upload using rusoto_s3 or s3 crate
        log::info!("Uploading {} ({:.2} MB) to {}", file_path, file_size, bucket);
        
        Ok((object_name, file_size))
    }
    
    pub async fn list_backups(&self, bucket: &str) -> Result<Vec<BackupFile>, String> {
        // TODO: Implement list using S3 API
        Ok(vec![
            BackupFile {
                name: "backup_2024-04-01.zip".to_string(),
                size_mb: 1250.5,
                uploaded_at: "2024-04-01T10:30:00Z".to_string(),
            },
        ])
    }
}
```

### 2g. Configuration Loading (src-tauri/src/config.rs)

```rust
// src-tauri/src/config.rs
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    // Odoo Configuration
    pub odoo_url: String,
    pub odoo_master_password: String,
    
    // MinIO Configuration
    pub minio_url: String,
    pub access_key: String,
    pub secret_key: String,
    pub bucket: String,
    
    // Paths
    pub backup_dir: String,
    pub filestore_dir: String,
    
    // Other
    pub local_tz: String,
    pub db_name: String,
    pub max_files_dump: u32,
    pub password_login_ui: String,
}

impl Config {
    pub fn load() -> Result<Self, Box<dyn std::error::Error>> {
        // Load from environment variables or config file
        // Replaces config.py loading
        Ok(Self {
            odoo_url: std::env::var("ODOO_URL")
                .unwrap_or_else(|_| "http://localhost:18000".to_string()),
            odoo_master_password: std::env::var("ODOO_MASTER_PASSWORD")
                .map_err(|_| "ODOO_MASTER_PASSWORD not set".to_string())?,
            minio_url: std::env::var("MINIO_URL")
                .unwrap_or_else(|_| "http://192.168.1.211:9000".to_string()),
            access_key: std::env::var("MINIO_ACCESS_KEY").unwrap_or_default(),
            secret_key: std::env::var("MINIO_SECRET_KEY").unwrap_or_default(),
            bucket: "auto-backup".to_string(),
            backup_dir: "/data/projects/pg_dumps".to_string(),
            filestore_dir: "/odoo/.local/share/Odoo/filestore/".to_string(),
            local_tz: "Asia/Bangkok".to_string(),
            db_name: std::env::var("DB_NAME")
                .unwrap_or_else(|_| "sees".to_string()),
            max_files_dump: 7,
            password_login_ui: "autonsi1234".to_string(),
        })
    }
    
    pub fn config_dir() -> PathBuf {
        dirs::config_dir()
            .map(|p| p.join("odoo-backup-service"))
            .unwrap_or_else(|| PathBuf::from("."))
    }
}
```

---

## Step 3: Frontend - Vue UI

### 3a. Main App Component (src/App.vue)

```vue
<template>
  <div class="app">
    <header class="header">
      <h1>🔄 Odoo Backup Service</h1>
      <nav>
        <button 
          @click="activeTab = 'backup'"
          :class="{ active: activeTab === 'backup' }"
        >
          Backup
        </button>
        <button 
          @click="activeTab = 'history'"
          :class="{ active: activeTab === 'history' }"
        >
          History
        </button>
        <button 
          @click="activeTab = 'settings'"
          :class="{ active: activeTab === 'settings' }"
        >
          Settings
        </button>
      </nav>
    </header>

    <main class="content">
      <BackupForm v-if="activeTab === 'backup'" @backup="handleBackup" />
      <BackupHistory v-if="activeTab === 'history'" :backups="backups" />
      <Settings v-if="activeTab === 'settings'" @save="handleSettingsSave" />
    </main>

    <footer class="footer">
      <p>v{{ version }} • Auto-updates enabled</p>
    </footer>
  </div>
</template>

<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { invoke } from '@tauri-apps/api/tauri'
import BackupForm from './components/BackupForm.vue'
import BackupHistory from './components/BackupHistory.vue'
import Settings from './components/Settings.vue'

const activeTab = ref<'backup' | 'history' | 'settings'>('backup')
const backups = ref([])
const version = ref('0.1.0')

onMounted(async () => {
  try {
    const status = await invoke('get_backup_status')
    console.log('Backup status:', status)
  } catch (error) {
    console.error('Failed to load status:', error)
  }
})

const handleBackup = async (dbName: string) => {
  try {
    const result = await invoke('backup_database', { dbName, backupFormat: 'zip' })
    console.log('Backup result:', result)
    // Refresh history
  } catch (error) {
    console.error('Backup failed:', error)
  }
}

const handleSettingsSave = async (settings: any) => {
  try {
    await invoke('update_config', { config: settings })
    console.log('Settings saved')
  } catch (error) {
    console.error('Failed to save settings:', error)
  }
}
</script>

<style scoped>
.app {
  display: flex;
  flex-direction: column;
  height: 100vh;
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
}

.header {
  padding: 20px;
  background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
  color: white;
  box-shadow: 0 2px 8px rgba(0, 0, 0, 0.1);
}

.header h1 {
  margin: 0 0 15px 0;
  font-size: 24px;
}

.header nav {
  display: flex;
  gap: 10px;
}

.header button {
  padding: 8px 16px;
  border: none;
  background: rgba(255, 255, 255, 0.2);
  color: white;
  border-radius: 4px;
  cursor: pointer;
  transition: background 0.3s;
}

.header button.active {
  background: white;
  color: #667eea;
}

.content {
  flex: 1;
  padding: 20px;
  overflow-y: auto;
}

.footer {
  padding: 15px;
  background: #f5f5f5;
  border-top: 1px solid #ddd;
  text-align: center;
  font-size: 12px;
  color: #666;
}
</style>
```

### 3b. Backup Form Component (src/components/BackupForm.vue)

```vue
<template>
  <div class="backup-form">
    <h2>Create Backup</h2>
    
    <form @submit.prevent="submitBackup">
      <div class="form-group">
        <label for="db-name">Database Name *</label>
        <input 
          v-model="dbName"
          id="db-name"
          type="text"
          placeholder="e.g., sees"
          required
        />
      </div>

      <div class="form-group">
        <label>Backup Format *</label>
        <div class="radio-group">
          <label>
            <input v-model="backupFormat" type="radio" value="zip" />
            ZIP (with filestore)
          </label>
          <label>
            <input v-model="backupFormat" type="radio" value="dump" />
            DUMP (database only)
          </label>
        </div>
      </div>

      <div class="form-group">
        <label>
          <input v-model="uploadToMinio" type="checkbox" />
          Auto-upload to MinIO after backup
        </label>
      </div>

      <div class="button-group">
        <button type="submit" :disabled="isLoading" class="primary">
          {{ isLoading ? 'Backing up...' : 'Start Backup' }}
        </button>
      </div>

      <div v-if="status" :class="['status', status.type]">
        {{ status.message }}
      </div>
    </form>
  </div>
</template>

<script setup lang="ts">
import { ref } from 'vue'
import { invoke } from '@tauri-apps/api/tauri'

const emit = defineEmits<{
  backup: [dbName: string]
}>()

const dbName = ref('sees')
const backupFormat = ref('zip')
const uploadToMinio = ref(false)
const isLoading = ref(false)
const status = ref<{ type: string; message: string } | null>(null)

const submitBackup = async () => {
  isLoading.value = true
  status.value = null

  try {
    const result = await invoke('backup_database', {
      dbName: dbName.value,
      backupFormat: backupFormat.value,
    })
    
    status.value = {
      type: 'success',
      message: `✅ Backup completed: ${result.filename}`,
    }
    
    if (uploadToMinio.value) {
      // Queue MinIO upload
      await invoke('upload_to_minio', {
        filePath: result.filename,
        bucket: 'auto-backup',
      })
    }
    
    emit('backup', dbName.value)
  } catch (error) {
    status.value = {
      type: 'error',
      message: `❌ Backup failed: ${error}`,
    }
  } finally {
    isLoading.value = false
  }
}
</script>

<style scoped>
.backup-form {
  max-width: 500px;
  margin: 0 auto;
}

.form-group {
  margin-bottom: 20px;
}

.form-group label {
  display: block;
  margin-bottom: 8px;
  font-weight: 500;
}

.form-group input[type="text"],
.form-group input[type="password"],
.form-group select {
  width: 100%;
  padding: 10px;
  border: 1px solid #ddd;
  border-radius: 4px;
  font-size: 14px;
}

.radio-group {
  display: flex;
  gap: 20px;
}

.button-group {
  display: flex;
  gap: 10px;
}

.primary {
  flex: 1;
  padding: 10px;
  background: #667eea;
  color: white;
  border: none;
  border-radius: 4px;
  cursor: pointer;
  font-weight: 500;
}

.primary:hover:not(:disabled) {
  background: #5568d3;
}

.primary:disabled {
  opacity: 0.6;
  cursor: not-allowed;
}

.status {
  margin-top: 15px;
  padding: 12px;
  border-radius: 4px;
  font-size: 14px;
}

.status.success {
  background: #d4edda;
  color: #155724;
  border: 1px solid #c3e6cb;
}

.status.error {
  background: #f8d7da;
  color: #721c24;
  border: 1px solid #f5c6cb;
}
</style>
```

---

## Step 4: Configuration & Versioning

### 4a. tauri.conf.json (Updater Setup)

```json
{
  "buildIdentifier": "odoo-backup-service",
  "productName": "Odoo Backup Service",
  "version": "0.1.0",
  "identifier": "com.example.backup-service",
  "build": {
    "beforeBuildCommand": "npm run build",
    "beforeDevCommand": "npm run dev",
    "devPath": "http://localhost:5173",
    "frontendDist": "../dist"
  },
  "app": {
    "windows": [
      {
        "title": "Odoo Backup Service",
        "width": 800,
        "height": 600,
        "resizable": true,
        "fullscreen": false
      }
    ],
    "security": {
      "csp": null
    },
    "updater": {
      "active": true,
      "endpoints": ["https://releases.githubusercontent.com/repos/YOUR_GITHUB_ORG/odoo-backup-service/releases/latest"],
      "dialog": true,
      "pubkey": ""
    }
  },
  "bundle": {
    "active": true,
    "targets": ["nsis", "msi"],
    "nsis": {
      "artifactTemplate": "Odoo-Backup-Service_{{ version }}_x64_installer.exe",
      "installerIcon": "icons/icon.ico",
      "uninstallerIcon": "icons/icon.ico",
      "headerImage": "icons/header.bmp",
      "sidebarImage": "icons/installer.bmp"
    }
  }
}
```

### 4b. Publish Script (publish.bat - adapted from your electron version)

```bat
@echo off
REM ============================================================
REM  Odoo Backup Service - Publish New Version
REM  Adapted from electron-app/publish.bat for Tauri
REM ============================================================

if "%GH_TOKEN%"=="" (
    echo [ERROR] GH_TOKEN not set!
    echo Run: set GH_TOKEN=your_github_token
    pause
    exit /b 1
)

setlocal enabledelayedexpansion
set TYPE=%1
if "%TYPE%"=="" set TYPE=patch

echo Publishing %TYPE% release...

REM Get current version from Cargo.toml
for /f "tokens=3" %%v in ('findstr version src-tauri/Cargo.toml ^| findstr "^version"') do (
    set LOCAL_VER=%%v
    set "LOCAL_VER=!LOCAL_VER:"=!"
)

echo Local version: %LOCAL_VER%

REM Get latest GitHub version
for /f %%v in ('gh release list --exclude-drafts --exclude-pre-releases --limit 1 --json tagName --jq ".[0].tagName" 2^>nul') do (
    set GH_TAG=%%v
)

if "%GH_TAG%"=="" (
    set GH_VER=0.0.0
) else (
    set "GH_VER=%GH_TAG:~1%"
)

echo GitHub version: %GH_VER%

REM Bump version using cargo-edit
cargo set-version %TYPE%

REM Get new version
for /f "tokens=3" %%v in ('findstr version src-tauri/Cargo.toml ^| findstr "^version"') do (
    set NEW_VER=%%v
    set "NEW_VER=!NEW_VER:"=!"
)

echo New version: %NEW_VER%

echo Cleaning old builds...
if exist dist rmdir /s /q dist
if exist src-tauri/target\release rmdir /s /q src-tauri\target\release

echo Building Tauri app...
call npm run build
if errorlevel 1 (
    echo [ERROR] Build failed!
    pause
    exit /b 1
)

echo Building Tauri bundle...
call npm run tauri:build
if errorlevel 1 (
    echo [ERROR] Tauri build failed!
    pause
    exit /b 1
)

echo Creating GitHub release...
gh release create v%NEW_VER% ./src-tauri/target/release/bundle/nsis/Odoo-Backup-Service_* ^
    --title "v%NEW_VER%" ^
    --draft

echo [SUCCESS] Release v%NEW_VER% created!
echo.
echo Next steps:
echo 1. Review release details on GitHub
echo 2. Remove --draft flag to publish
echo 3. Users will receive auto-update notification

pause
```

---

## Step 5: Build & Test Locally

```bash
# Install dependencies
npm install

# Development mode (frontend hot-reload + Rust recompile)
npm run tauri dev

# Build for distribution
npm run tauri build

# Output: src-tauri/target/release/bundle/nsis/*.exe
```

---

## Step 6: GitHub Actions (Auto-Release)

Create `.github/workflows/publish.yml`:

```yaml
name: publish

on:
  push:
    tags:
      - 'v*'

jobs:
  publish-tauri:
    permissions:
      contents: write
    strategy:
      fail-fast: false
      matrix:
        platform: [windows-latest, ubuntu-20.04, macos-latest]
    runs-on: ${{ matrix.platform }}

    steps:
      - uses: actions/checkout@v4

      - name: setup node
        uses: actions/setup-node@v4
        with:
          node-version: '18'

      - name: setup rust
        uses: dtolnay/rust-toolchain@stable

      - name: install dependencies (ubuntu)
        if: matrix.platform == 'ubuntu-20.04'
        run: |
          sudo apt-get update && sudo apt-get install -y \
            libgtk-3-dev libayatana-appindicator3-dev librsvg2-dev

      - name: install frontend dependencies
        run: npm install

      - name: build tauri app
        uses: tauri-apps/tauri-action@dev
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        with:
          args: ''
          tagName: v__VERSION__
          releaseName: 'App v__VERSION__'
          releaseBody: 'See the assets to download this version and install.'
          releaseDraft: false
          prerelease: false
```

---

## Migration Checklist

- [ ] Create Tauri project structure
- [ ] Port `OdooBackupManager` from Python to Rust
- [ ] Port MinIO client from boto3 to Rust S3 client
- [ ] Create Vue UI components (BackupForm, History, Settings)
- [ ] Implement system tray integration
- [ ] Set up automatic update mechanism
- [ ] Create GitHub Actions workflow
- [ ] Adapt publish.bat for Tauri
- [ ] Test on Windows/Linux
- [ ] Test auto-update feature
- [ ] Document for team
- [ ] Deploy first release

---

## Next Steps

1. **Create GitHub repo** for this service
2. **Copy build from electron-app as template** (you already have the publish workflow)
3. **Start with backend first** (port OdooBackupManager)
4. **Add simple Vue UI** (don't need a complex frontend initially)
5. **Test locally** before publishing to GitHub releases
6. **Set up GitHub Actions** for CI/CD builds

---

**Questions?** Check the Tauri docs: https://tauri.app/
