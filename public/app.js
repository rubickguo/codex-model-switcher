document.addEventListener('DOMContentLoaded', () => {
  // Elements - Mode Toggle
  const toggleGpt = document.getElementById('toggle-gpt');
  const toggleDeepseek = document.getElementById('toggle-deepseek');
  const panelGpt = document.getElementById('panel-gpt');
  const panelDeepseek = document.getElementById('panel-deepseek');

  // Elements - Status
  const codexStatus = document.getElementById('codex-status');
  const bridgeStatus = document.getElementById('bridge-status');
  const activeModel = document.getElementById('active-model');
  const sessionsStatus = document.getElementById('sessions-status');
  const btnRestartCodex = document.getElementById('btn-restart-codex');

  // Elements - Form
  const deepseekForm = document.getElementById('deepseek-form');
  const providerSelect = document.getElementById('provider-select');
  const urlGroup = document.getElementById('url-group');
  const baseUrlInput = document.getElementById('base-url-input');
  const apiKeyInput = document.getElementById('api-key-input');
  const btnToggleKey = document.getElementById('btn-toggle-key');
  const btnApplyGpt = document.getElementById('btn-apply-gpt');

  // Elements - Models
  const modelProSelect = document.getElementById('model-pro-select');
  const modelProCustom = document.getElementById('model-pro-custom');
  const modelFlashSelect = document.getElementById('model-flash-select');
  const modelFlashCustom = document.getElementById('model-flash-custom');

  // Elements - Backups & Logs
  const backupsList = document.getElementById('backups-list');
  const consoleOutput = document.getElementById('console-output');
  const btnClearLogs = document.getElementById('btn-clear-logs');
  const btnRefreshLogs = document.getElementById('btn-refresh-logs');

  let activeMode = 'gpt';

  // State polling interval timers
  let statusInterval = null;
  let logsInterval = null;

  // Init Form Visibility Helpers
  function updateFormVisibilities() {
    // Show/hide base URL input
    if (providerSelect.value === 'custom') {
      urlGroup.classList.remove('hidden');
      baseUrlInput.required = true;
    } else {
      urlGroup.classList.add('hidden');
      baseUrlInput.required = false;
    }

    // Custom model inputs
    if (modelProSelect.value === 'custom_pro') {
      modelProCustom.classList.remove('hidden');
      modelProCustom.required = true;
    } else {
      modelProCustom.classList.add('hidden');
      modelProCustom.required = false;
    }

    if (modelFlashSelect.value === 'custom_flash') {
      modelFlashCustom.classList.remove('hidden');
      modelFlashCustom.required = true;
    } else {
      modelFlashCustom.classList.add('hidden');
      modelFlashCustom.required = false;
    }
  }

  // Event Listeners for Visibility triggers
  providerSelect.addEventListener('change', updateFormVisibilities);
  modelProSelect.addEventListener('change', updateFormVisibilities);
  modelFlashSelect.addEventListener('change', updateFormVisibilities);

  // Toggle API Key view
  btnToggleKey.addEventListener('click', () => {
    if (apiKeyInput.type === 'password') {
      apiKeyInput.type = 'text';
      btnToggleKey.textContent = '🙈';
    } else {
      apiKeyInput.type = 'password';
      btnToggleKey.textContent = '👁️';
    }
  });

  // Switch tab display helper
  function switchTab(mode) {
    activeMode = mode;
    if (mode === 'gpt') {
      toggleGpt.classList.add('active');
      toggleDeepseek.classList.remove('active');
      panelGpt.classList.add('active');
      panelDeepseek.classList.remove('active');
    } else {
      toggleGpt.classList.remove('active');
      toggleDeepseek.classList.add('active');
      panelGpt.classList.remove('active');
      panelDeepseek.classList.add('active');
    }
  }

  toggleGpt.addEventListener('click', () => switchTab('gpt'));
  toggleDeepseek.addEventListener('click', () => switchTab('deepseek'));

  // API Call - Fetch Status
  async function fetchStatus() {
    try {
      const res = await fetch('/api/status');
      if (!res.ok) throw new Error('HTTP ' + res.status);
      const status = await res.json();

      // Codex app badge
      if (status.codexRunning) {
        codexStatus.textContent = '运行中';
        codexStatus.className = 'status-badge badge-on';
      } else {
        codexStatus.textContent = '已停止';
        codexStatus.className = 'status-badge badge-off';
      }

      // Bridge badge
      if (status.bridgeRunning) {
        bridgeStatus.textContent = '运行中 (8787)';
        bridgeStatus.className = 'status-badge badge-on';
      } else {
        bridgeStatus.textContent = '已停止';
        bridgeStatus.className = 'status-badge badge-off';
      }

      // Model display
      if (status.currentConfig.provider === 'deepseek_bridge') {
        const upstream = status.bridgeConfig ? status.bridgeConfig.upstreamModel : 'deepseek-pro';
        activeModel.textContent = `DeepSeek (${upstream})`;
        activeModel.className = 'status-value safe-status';
        if (!statusInterval) {
          switchTab('deepseek');
        }
      } else {
        activeModel.textContent = `官方 (${status.currentConfig.model})`;
        activeModel.className = 'status-value';
        if (!statusInterval) {
          switchTab('gpt');
        }
      }

      // Sessions badge
      sessionsStatus.textContent = `${status.sessionsCount} 聊天 (100% 安全)`;

      // Prefill key if saved
      if (status.hasSavedKey && apiKeyInput.value === '') {
        apiKeyInput.value = '••••••••';
      }
    } catch (err) {
      console.error('Failed to fetch status:', err);
    }
  }

  // API Call - Fetch Backups list
  async function fetchBackups() {
    try {
      const res = await fetch('/api/backups');
      if (!res.ok) throw new Error('HTTP ' + res.status);
      const backups = await res.json();

      if (backups.length === 0) {
        backupsList.innerHTML = `<tr><td colspan="4" class="empty-state">暂无备份文件</td></tr>`;
        return;
      }

      backupsList.innerHTML = backups.map(b => {
        const dateStr = new Date(b.date).toLocaleString();
        const sizeStr = (b.size / 1024).toFixed(2) + ' KB';
        // Parse a readable tag if possible
        let desc = b.name;
        if (b.name.includes('pre-restore')) {
          desc = '还原前自动备份';
        } else if (b.name.includes('pre-patch') || b.name.includes('setup')) {
          desc = '设置前备份';
        } else {
          desc = '系统自动备份';
        }
        return `
          <tr>
            <td>
              <span class="backup-filename" title="${b.path}">${desc}</span>
              <div class="field-desc">${b.name}</div>
            </td>
            <td>${dateStr}</td>
            <td>${sizeStr}</td>
            <td>
              <button class="btn-restore-table" data-path="${b.path}">还原此备份</button>
            </td>
          </tr>
        `;
      }).join('');

      // Add restore triggers
      document.querySelectorAll('.btn-restore-table').forEach(btn => {
        btn.addEventListener('click', async (e) => {
          const path = e.target.getAttribute('data-path');
          if (confirm(`确认还原此备份吗？此操作会重启 Codex 并断开 DeepSeek 网桥。`)) {
            appendLog(`[Client] 正在还原备份: ${path}`);
            try {
              const res = await fetch('/api/restore-backup', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ filepath: path })
              });
              const data = await res.json();
              if (data.success) {
                appendLog(`[Success] ${data.message}`);
                alert("还原成功！");
                refreshAll();
              } else {
                throw new Error(data.error);
              }
            } catch (err) {
              appendLog(`[Error] 还原失败: ${err.message}`);
              alert("还原失败: " + err.message);
            }
          }
        });
      });
    } catch (err) {
      console.error('Failed to fetch backups:', err);
    }
  }

  // API Call - Fetch Logs
  async function fetchLogs() {
    try {
      const res = await fetch('/api/logs');
      if (!res.ok) throw new Error('HTTP ' + res.status);
      const logs = await res.json();
      consoleOutput.textContent = logs.join('\n');
      // Scroll to bottom
      consoleOutput.parentElement.scrollTop = consoleOutput.parentElement.scrollHeight;
    } catch (err) {
      console.error('Failed to fetch logs:', err);
    }
  }

  function appendLog(line) {
    const timestamp = new Date().toLocaleTimeString();
    consoleOutput.textContent += `\n[${timestamp}] ${line}`;
    consoleOutput.parentElement.scrollTop = consoleOutput.parentElement.scrollHeight;
  }

  // Action - Switch to GPT Mode
  btnApplyGpt.addEventListener('click', async () => {
    appendLog("[Client] 正在切换至官方 OpenAI (GPT) 模式...");
    btnApplyGpt.disabled = true;
    try {
      const res = await fetch('/api/switch', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ mode: 'gpt' })
      });
      const data = await res.json();
      if (data.success) {
        appendLog(`[Success] ${data.message}`);
        alert("官方模式启用成功！");
        refreshAll();
      } else {
        throw new Error(data.error);
      }
    } catch (err) {
      appendLog(`[Error] 切换失败: ${err.message}`);
      alert("切换失败: " + err.message);
    } finally {
      btnApplyGpt.disabled = false;
    }
  });

  // Action - Switch to DeepSeek Mode
  deepseekForm.addEventListener('submit', async () => {
    const provider = providerSelect.value;
    const apiKey = apiKeyInput.value;
    const baseUrl = baseUrlInput.value;

    let modelPro = modelProSelect.value;
    if (modelPro === 'custom_pro') {
      modelPro = modelProCustom.value.trim();
    }
    
    let modelFlash = modelFlashSelect.value;
    if (modelFlash === 'custom_flash') {
      modelFlash = modelFlashCustom.value.trim();
    }

    const btn = document.getElementById('btn-apply-deepseek');
    btn.disabled = true;
    appendLog(`[Client] 正在切换至 DeepSeek 模式 (服务商: ${provider})...`);

    try {
      const res = await fetch('/api/switch', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          mode: 'deepseek',
          provider,
          apiKey,
          baseUrl,
          modelPro,
          modelFlash
        })
      });
      const data = await res.json();
      if (data.success) {
        appendLog(`[Success] ${data.message}`);
        alert("DeepSeek 桥接配置应用成功！");
        refreshAll();
      } else {
        throw new Error(data.error);
      }
    } catch (err) {
      appendLog(`[Error] 配置失败: ${err.message}`);
      alert("配置失败: " + err.message);
    } finally {
      btn.disabled = false;
    }
  });

  // Action - Restart Codex only
  btnRestartCodex.addEventListener('click', async () => {
    appendLog("[Client] 正在重启 Codex...");
    try {
      const res = await fetch('/api/restart-codex', { method: 'POST' });
      const data = await res.json();
      if (data.success) {
        appendLog("[Success] Codex 重启成功！");
      }
    } catch (err) {
      appendLog(`[Error] 重启 Codex 失败: ${err.message}`);
    }
  });

  // Log UI tools
  btnClearLogs.addEventListener('click', () => {
    consoleOutput.textContent = '';
  });

  btnRefreshLogs.addEventListener('click', fetchLogs);

  // Refresh helper
  function refreshAll() {
    fetchStatus();
    fetchBackups();
    fetchLogs();
  }

  // Setup loop updates
  refreshAll();
  statusInterval = setInterval(fetchStatus, 3000);
  logsInterval = setInterval(fetchLogs, 3000);
  setInterval(fetchBackups, 10000); // Backups check every 10s
});
