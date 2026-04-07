/** @odoo-module **/

import { registry } from "@web/core/registry";
import { session } from "@web/session";

export const minioService = {
    dependencies: ["orm", "notification", "bus_service"],
    async start(env, { orm, notification, bus_service }) {
        let serviceUrlCache = null;

        // --- Status Check Logic ---
        bus_service.addChannel("minio.check.status");
        bus_service.subscribe("minio.check.status", async (payload) => {
            const baseUrl = await getServiceUrl() || "http://localhost:9999";
            try {
                const res = await fetch(`${baseUrl}/api/system/status`);
                if (res.ok) {
                    const data = await res.json();
                    // Add context
                    data.ip = window.location.hostname;
                    data.hostname = "Browser Client"; // Can't real hostname from browser

                    // Report back to Odoo
                    await orm.call("minio.device", "update_heartbeat", [data.client_id, data]);
                    console.log("MinIO Device Heartbeat sent.");
                }
            } catch (e) {
                console.warn("MinIO Client verification failed (offline?)", e);
                // Report OFFLINE status back to Odoo
                // We need the client_id. Since we can't get it from the offline service,
                // we rely on the payload from the bus signal if available?
                // Wait, the payload has client_id!
                if (payload.client_id) {
                    await orm.call("minio.device", "update_heartbeat", [payload.client_id, {
                        status: 'offline',
                        hostname: 'Unknown (Offline)'
                    }]);
                    console.log("MinIO Device reported OFFLINE.");
                }
            }
        });
        async function getServiceUrl() {
            if (serviceUrlCache) return serviceUrlCache;
            try {
                const configId = await orm.call('minio.config', 'get_default_config', []);
                if (configId) {
                    const [config] = await orm.read('minio.config', [configId], ['client_service_url']);
                    if (config && config.client_service_url) {
                        serviceUrlCache = config.client_service_url;
                        return serviceUrlCache;
                    }
                }
            } catch (e) {
                console.warn("Failed to fetch MinIO config", e);
            }
            return null;
        }

        async function localFetch(endpoint, options = {}) {
            const baseUrl = await getServiceUrl() || "http://localhost:9999";
            const url = `${baseUrl}${endpoint}`;
            try {
                const response = await fetch(url, options);

                // Special handling for Login endpoint (401 is expected result for failed login)
                if (endpoint === "/api/auth/login" && response.status === 401) {
                    return response;
                }

                if (!response.ok) {
                    if (response.status === 401) {
                        const err = new Error("Authentication failed");
                        err.status = 401;
                        // Try to read body
                        try {
                            const data = await response.json();
                            if (data.auth_required) err.auth_required = true;
                        } catch (e) { }
                        throw err;
                    }
                    throw new Error(`Local service error! status: ${response.status}`);
                }
                return response;
            } catch (error) {
                console.error("MinIO Local API Error:", error);
                throw error;
            }
        }

        async function serverFetch(endpoint, options = {}) {
            // Priority: call Odoo Server proxy first for browsing/viewing
            const url = `/minio${endpoint}`;
            try {
                const response = await fetch(url, options);
                if (!response.ok) {
                    throw new Error(`Odoo Server error! status: ${response.status}`);
                }
                return response;
            } catch (error) {
                console.error("MinIO Server API Error:", error);
                throw error;
            }
        }

        const listCache = new Map();

        // --- Auto-Config Logic (Rule: Smart Config) ---
        let configSynced = false;

        const ensureConfig = async () => {
            // Skip if already synced successfully in this page session
            if (configSynced) return;

            try {
                const odooUrl = window.location.origin;
                const db = session.db;
                if (!db || !odooUrl) return;

                const baseUrl = await getServiceUrl() || 'http://localhost:9999';

                // 1. Check if Go service already has MinIO config
                try {
                    const statusRes = await fetch(`${baseUrl.replace(/\/+$/, '')}/api/system/status`);
                    if (statusRes.ok) {
                        const status = await statusRes.json();
                        if (status.minio_connected) {
                            // Go service already configured and connected
                            configSynced = true;
                            return;
                        }
                    }
                } catch (_) {
                    // Service unreachable — will try to send config below
                }

                // 2. Fetch MinIO config from Odoo
                let minioConfig = {};
                try {
                    const cfgResult = await orm.call('minio.config', 'get_default_config', []);
                    if (cfgResult) {
                        const [cfg] = await orm.read('minio.config', [cfgResult], [
                            'endpoint', 'access_key', 'secret_key', 'bucket_name'
                        ]);
                        if (cfg) {
                            const ep = (cfg.endpoint || '').trim();
                            minioConfig = {
                                minio_endpoint: ep,
                                minio_access_key: (cfg.access_key || '').trim(),
                                minio_secret_key: (cfg.secret_key || '').trim(),
                                minio_bucket: (cfg.bucket_name || '').trim(),
                                minio_secure: ep.startsWith('https://'),
                            };
                        }
                    }
                } catch (e) {
                    console.debug('ensureConfig: could not read minio.config from Odoo', e);
                }

                // 3. Send to Go service
                try {
                    const payload = { url: odooUrl, db, ...minioConfig };
                    const res = await fetch(`${baseUrl.replace(/\/+$/, '')}/api/config/auto_set`, {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify(payload)
                    });
                    const data = await res.json();
                    if (data.provisioned) {
                        console.log('MinIO service auto-provisioned with config from Odoo.');
                        notification.add('MinIO service connected and configured automatically.', { type: 'success' });
                    }
                    // Only mark synced if Go service confirmed config is working
                    // Check status again to verify MinIO is actually connected
                    try {
                        const verifyRes = await fetch(`${baseUrl.replace(/\/+$/, '')}/api/system/status`);
                        if (verifyRes.ok) {
                            const verifyStatus = await verifyRes.json();
                            configSynced = !!verifyStatus.minio_connected;
                        }
                    } catch (_) {
                        // If verify fails, still mark as synced to avoid infinite retries
                        configSynced = true;
                    }
                } catch (err) {
                    // Go service unreachable — don't set configSynced so we retry next time
                    console.debug('ensureConfig: Go service unreachable', err);
                }
            } catch (e) {
                console.warn('ensureConfig error', e);
            }
        };

        // Execute on page load (non-blocking)
        ensureConfig();

        return {
            /**
             * Upload files with real-time progress tracking via SSE
             * @param {FileList} files - Files to upload
             * @param {string} remotePath - Remote path prefix
             * @param {string} taskId - Task ID for tracking
             * @param {Function} onProgress - Progress callback (percent)
             * @param {AbortSignal} abortSignal - Abort signal
             */

            /**
             * Listen to task progress via SSE
             * @param {string} taskId 
             * @param {Function} onProgress 
             * @returns {Function} closer - Function to close the connection
             */
            listenToTaskProgress(taskId, onProgress) {
                let eventSource = null;
                let lastPercent = 0;
                let isActive = true;

                getServiceUrl().then(baseUrl => {
                    if (!isActive) return;
                    const effectiveUrl = baseUrl || "http://localhost:9999";
                    try {
                        console.log(`[SSE] Connecting for task ${taskId}...`);
                        eventSource = new EventSource(`${effectiveUrl}/api/upload/progress/${taskId}`);

                        eventSource.onmessage = (event) => {
                            if (!isActive) {
                                eventSource.close();
                                return;
                            }
                            try {
                                const data = JSON.parse(event.data);
                                if (data.status === 'complete') {
                                    // Make sure we hit 100%
                                    onProgress(100);
                                    eventSource.close();
                                    return;
                                }
                                if (data.percent !== undefined) {
                                    if (data.percent > lastPercent) {
                                        lastPercent = data.percent;
                                        onProgress(Math.round(data.percent));
                                    }
                                }
                            } catch (e) {
                                console.warn("SSE parse error:", e);
                            }
                        };

                        eventSource.onerror = (err) => {
                            if (eventSource.readyState !== 2) {
                                console.warn("SSE connection error:", err);
                            }
                        };
                    } catch (e) {
                        console.warn("Failed to setup SSE:", e);
                    }
                });

                return () => {
                    isActive = false;
                    if (eventSource) {
                        console.log(`[SSE] Closing connection for task ${taskId}`);
                        eventSource.close();
                    }
                };
            },

            async uploadStream(paths, remotePath = "", taskId = null, onProgress = () => { }, abortSignal = null) {
                await ensureConfig();
                return new Promise((resolve, reject) => {
                    const effectiveTaskId = taskId || `upload_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;

                    const payload = {
                        paths: paths,
                        path: remotePath,
                        task_id: effectiveTaskId,
                        odoo_session: session.session_id,
                    };

                    // 1. Setup SSE listener
                    const closeSSE = this.listenToTaskProgress(effectiveTaskId, onProgress);

                    // 2. Send the Upload Request
                    localFetch("/api/upload", {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify(payload),
                        signal: abortSignal
                    }).then(response => {
                        return response.json();
                    }).then(data => {
                        if (closeSSE) closeSSE();
                        if (data.success) {
                            onProgress(100);
                            listCache.delete(remotePath);
                            resolve(data);
                        } else {
                            reject(new Error(data.error || "Upload failed"));
                        }
                    }).catch(err => {
                        if (closeSSE) closeSSE();
                        reject(err);
                    });
                });
            },

            // Legacy upload wrapper (if needed by other components)
            async upload(files, remotePath = "", taskId = null) {
                return this.uploadStream(files, remotePath, taskId);
            },

            async listObjects(path = "", forceRefresh = false) {
                if (!forceRefresh && listCache.has(path)) {
                    serverFetch(`/api/list?path=${encodeURIComponent(path)}`).then(r => r.json()).then(data => {
                        listCache.set(path, data);
                    }).catch(() => { });
                    return listCache.get(path);
                }

                const response = await serverFetch(`/api/list?path=${encodeURIComponent(path)}`);
                const data = await response.json();
                listCache.set(path, data);
                return data;
            },

            async getBucketInfo() {
                const response = await serverFetch("/api/bucket");
                return response.json();
            },

            async pickAndSync(type, currentPath, extraParams = {}) {
                await ensureConfig();
                console.log("minioService.pickAndSync called with:", { type, currentPath, extraParams });
                // Pass Odoo session so Go service can call /minio/sync_metadata with auth
                const body = JSON.stringify({
                    type,
                    current_path: currentPath,
                    odoo_session: session.session_id,
                    ...extraParams,
                });
                console.log("Payload body:", body);

                const response = await localFetch("/api/pick_sync", {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: body
                });
                return response.json();
            },

            async getTaskStatus(taskId) {
                const response = await localFetch(`/api/task/${taskId}`);
                return response.json();
            },

            async getTasks() {
                const response = await localFetch("/api/tasks");
                return response.json();
            },

            async deleteTask(taskId) {
                const response = await localFetch(`/api/task/${taskId}`, { method: 'DELETE' });
                return response.json();
            },

            async downloadObject(path) {
                const response = await serverFetch(`/api/download?path=${encodeURIComponent(path)}`);
                return response.blob();
            },

            getDownloadUrl(path, preview = false) {
                let url = `/minio/api/download?path=${encodeURIComponent(path)}`;
                if (preview) url += "&preview=true";
                return Promise.resolve(url);
            },

            async deleteObject(path, isFolder = false) {
                const response = await serverFetch("/api/delete", {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ path, is_folder: isFolder })
                });
                // Invalidate parent cache
                const parent = path.split('/').filter(Boolean).slice(0, -1).join('/');
                listCache.delete(parent);
                return response.json();
            },

            async startDownloadTask(paths, extraParams = {}) {
                const response = await localFetch("/api/download_async", {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ paths, ...extraParams })
                });
                return response.json();
            },

            async downloadZip(paths) {
                const response = await serverFetch("/api/download_zip", {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ paths })
                });
                if (!response.ok) {
                    const error = await response.json();
                    throw new Error(error.error || "Zip creation failed");
                }
                return response.blob();
            },

            async cancelTask(taskId) {
                const response = await localFetch(`/api/task/${taskId}/cancel`, {
                    method: 'POST'
                });
                return response.json();
            },

            async getAuthStatus() {
                try {
                    const response = await localFetch("/api/auth/status");
                    return response.json();
                } catch (e) {
                    return null;
                }
            },

            async login(url, db, username, password) {
                const response = await localFetch("/api/auth/login", {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ url, db, username, password })
                });
                // Check if response is ok, but localFetch throws if !ok?
                // Wait, localFetch handles !ok by throwing.
                // But our API returns 401 if login fail.
                // We should probably modify localFetch to return response, OR handle it here.
                // But localFetch implementation (lines 59-72) throws Error if !response.ok.
                // Authentication endpoint likely returns 401 on failure.
                // So we need to catch it.
                // Return json anyway if possible.
                // However, updated localFetch wrapper:
                return response.json();
            },

            async logout() {
                const response = await localFetch("/api/auth/logout", { method: 'POST' });
                return response.json();
            }
        };
    },
};

registry.category("services").add("minio_service", minioService);
