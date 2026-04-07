// --- Auto-Update Checker ---
(function() {
    const CHECK_INTERVAL = 6 * 60 * 60 * 1000; // 6 hours

    async function checkForUpdate() {
        try {
            const res = await fetch(`${window.API_BASE_URL}/api/system/update_check`);
            if (!res.ok) return;

            const data = await res.json();
            if (data.update_available) {
                showUpdateBanner(data);
            }
        } catch (e) {
            // Silently ignore update check failures
        }
    }

    function showUpdateBanner(data) {
        const banner = document.getElementById('update-banner');
        const message = document.getElementById('update-message');
        const link = document.getElementById('update-link');

        if (!banner) return;

        message.textContent = `New version ${data.latest_version} available! (current: ${data.current_version})`;
        if (data.download_url) {
            link.href = data.download_url;
            link.style.display = '';
        } else {
            link.style.display = 'none';
        }

        banner.classList.remove('d-none');
    }

    // Check on load (after 5 seconds delay)
    setTimeout(checkForUpdate, 5000);

    // Check periodically
    setInterval(checkForUpdate, CHECK_INTERVAL);
})();
