const root = document.querySelector('#app-root');
let mode = 'visual';
let wearableState = 'listening';
let selectedScreen = 'today';
let theme = 'dark';

const icon = (name) => `<i data-lucide="${name}"></i>`;

const tabbar = (active = 'today', wireframe = false) => `
  <nav class="tabbar ${wireframe ? 'wire-tabs' : ''}">
    ${[
      ['today', 'house', 'Today'],
      ['transcripts', 'notebook-tabs', 'Transcripts'],
      ['ask', 'message-circle', 'Ask'],
    ].map(([id, glyph, label]) => `
      <div class="tab ${active === id ? 'active' : ''}">${icon(glyph)}<span>${label}</span></div>
    `).join('')}
  </nav>`;

function todayVisual(state) {
  const cfg = {
    listening: {
      className: '', status: 'Listening', battery: '—', action: 'Pause listening', actionClass: '', actionIcon: 'pause',
      alert: '',
    },
    muted: {
      className: 'muted', status: 'Muted', battery: '—', action: 'Resume listening', actionClass: 'resume', actionIcon: 'mic',
      alert: `<div class="alert">${icon('shield-check')}<span>Microphone is off. Bluetooth stays connected so you can resume at any time.</span></div>`,
    },
    connecting: {
      className: 'connecting', status: 'Connecting…', battery: '—', action: 'Connecting to wearable…', actionClass: 'reconnect', actionIcon: 'loader-circle',
      alert: `<div class="alert">${icon('radio')}<span>Keep Echo Wearable nearby while the secure connection is restored.</span></div>`,
    },
    offline: {
      className: 'offline', status: 'Offline', battery: '—', action: 'Reconnect wearable', actionClass: 'reconnect', actionIcon: 'refresh-cw',
      alert: `<div class="alert">${icon('triangle-alert')}<span>Wearable has been offline for 3 minutes. Recent speech may be waiting on the device.</span></div>`,
    },
  }[state];

  return `
    <section class="screen">
      <div class="status-space"></div>
      <div class="content">
        <header class="screen-header">
          <h2>Today</h2>
          <button class="icon-button" aria-label="Settings">${icon('settings')}</button>
        </header>
        <div class="device-row ${cfg.className}">
          <span class="pulse"></span>
          <span class="label">Echo Wearable</span>
          <span class="state">${cfg.status}</span>
          <span class="battery">${cfg.battery}</span>
          ${icon('chevron-right')}
        </div>
        ${cfg.alert}

        <section class="section">
          <div class="section-title"><h3>Latest memory</h3><button class="text-link">See all</button></div>
          <article class="transcript">
            <div class="meta"><span>10:42</span><span>·</span><span>You</span><span>·</span><span>Completed</span></div>
            <p>Remember to send the revised proposal to Elena before Friday afternoon.</p>
          </article>
        </section>

        <section class="section">
          <div class="section-title"><h3>Open tasks</h3><button class="text-link">3 tasks</button></div>
          <div class="task"><span class="check"></span><div><p>Send Elena the revised proposal</p><small>Due Friday</small></div></div>
          <div class="task"><span class="check"></span><div><p>Book the train to Milan</p><small>From this morning</small></div></div>
        </section>

        <section class="section">
          <div class="section-title"><h3>Daily summary</h3></div>
          <div class="summary"><p>You discussed the launch timeline, captured three follow-ups, and mentioned Elena and Marco.</p></div>
        </section>
      </div>
      <button class="privacy-control ${cfg.actionClass}">${icon(cfg.actionIcon)}<span>${cfg.action}</span></button>
      ${tabbar('today')}
    </section>`;
}

const visualHeader = (title, actionIcon = '') => `
  <div class="status-space"></div>
  <header class="screen-header">
    <h2>${title}</h2>
    ${actionIcon ? `<button class="icon-button">${icon(actionIcon)}</button>` : ''}
  </header>`;

function transcriptsVisual() {
  const row = ({time, text, status, speaker = '', pending = false}) => `
    <article class="timeline-row">
      <time>${time}</time>
      <div class="timeline-copy">
        <p class="${pending ? 'pending-copy' : ''}">${text}</p>
        <div class="timeline-meta ${pending ? 'pending-meta' : ''}">
          ${pending ? '<span class="mini-spinner"></span>' : ''}<span>${status}${speaker ? ` · ${speaker}` : ''}</span>
        </div>
      </div>
      ${pending ? '' : icon('chevron-right')}
    </article>`;

  return `<section class="screen">
    <div class="content">${visualHeader('Transcripts')}
      <div class="live-line"><span class="dot green"></span><span>Wearable connected</span></div>
      <div class="search-field">${icon('search')}<span>Search transcripts</span></div>
      <div class="date-heading">Today</div>
      ${row({time:'11:06',text:'Transcribing recent audio…',status:'Transcribing',pending:true})}
      ${row({time:'10:42',text:'Remember to send the revised proposal to Elena before Friday afternoon.',status:'Completed',speaker:'You'})}
      ${row({time:'09:18',text:'The launch review moved to Tuesday morning. Marco will share the updated metrics.',status:'Completed',speaker:'Other'})}
      <div class="date-heading">Yesterday</div>
      ${row({time:'18:30',text:'Book the early train to Milan and reserve a quiet room near the station.',status:'Completed'})}
      ${row({time:'14:12',text:'The prototype battery should last a full working day.',status:'Completed',speaker:'You'})}
    </div>${tabbar('transcripts')}
  </section>`;
}

function askVisual() {
  return `<section class="screen chat-screen">
    <div class="content">${visualHeader('Ask Echo','history')}
      <div class="chat-day">Today</div>
      <div class="message user-message">What did I promise Elena?</div>
      <div class="message assistant-message">
        <p>You said you would send Elena the revised proposal before Friday afternoon.</p>
        <button class="source-link">${icon('notebook-tabs')} 1 transcript source</button>
      </div>
      <div class="message user-message">Create a calendar reminder for Friday at 2 PM.</div>
      <div class="action-proposal">
        <div class="action-icon">${icon('calendar-plus')}</div>
        <div><strong>Create calendar event?</strong><p>Send revised proposal to Elena<br><span>Friday · 2:00 PM</span></p></div>
        <div class="action-buttons"><button class="secondary-button">Cancel</button><button class="primary-button">Confirm</button></div>
      </div>
    </div>
    <div class="composer"><button>${icon('mic')}</button><span>Ask your memory…</span><button class="send">${icon('arrow-up')}</button></div>
    ${tabbar('ask')}
  </section>`;
}

function settingsVisual() {
  const row = (glyph, title, subtitle) => `<div class="settings-row"><span class="settings-icon">${icon(glyph)}</span><div><strong>${title}</strong><p>${subtitle}</p></div>${icon('chevron-right')}</div>`;
  return `<section class="screen">
    <div class="content">${visualHeader('Settings')}
      <div class="settings-section">DEVICE</div>
      ${row('radio-tower','Echo Wearable','Connected · Listening')}
      ${row('cloud','Connection','Server, cellular data and roaming')}
      ${row('shield','Privacy','Retention, mute and deletion')}
      <div class="settings-section">ECHO</div>
      ${row('workflow','Automations','Apps, rules and action history')}
      ${row('activity','Diagnostics','BLE, buffer and backend status')}
      ${row('info','About','Version, licenses and logout')}
    </div>
  </section>`;
}

function onboardingVisual() {
  return `<section class="screen onboarding-screen">
    <div class="content">${visualHeader('Pair wearable')}
      <div class="stepper"><span class="done"></span><span class="done"></span><span class="active"></span><span></span></div>
      <div class="pair-visual"><div class="signal signal-1"></div><div class="signal signal-2"></div><div class="wearable-glyph">${icon('radio-tower')}</div></div>
      <div class="onboarding-copy"><h3>Keep Echo nearby</h3><p>We’re looking for your wearable. Make sure it is powered on and the external antenna is connected.</p></div>
      <div class="found-device"><span class="dot blue"></span><div><strong>Echo Wearable</strong><p>Ready to pair</p></div><button class="primary-button">Connect</button></div>
    </div>
    <div class="onboarding-help">Can’t find it? <button class="text-link">Troubleshoot</button></div>
  </section>`;
}

function deviceVisual() {
  const metric = (label, value, tone = '') => `<div class="metric-row"><span>${label}</span><strong class="${tone}">${value}</strong></div>`;
  return `<section class="screen">
    <div class="content">${visualHeader('Echo Wearable','x')}
      <div class="device-hero"><div class="device-orbit"><div class="wearable-glyph">${icon('radio-tower')}</div></div><h3>Listening</h3><p><span class="dot green"></span> Securely connected</p></div>
      <div class="metric-list">
        ${metric('Battery','Not available')}
        ${metric('Audio buffer','Empty','positive')}
        ${metric('Last upload','Just now')}
        ${metric('Firmware','0.1.0')}
      </div>
      <button class="full-row-button">${icon('pause')} Pause listening</button>
      <button class="danger-link">Forget wearable</button>
    </div>
  </section>`;
}

const wfHeader = (title, action = '') => `
  <div class="status-space"></div>
  <header class="screen-header"><h2>${title}</h2>${action ? `<span class="wf-chip">${action}</span>` : ''}</header>`;

const lines = (count = 2) => Array.from({ length: count }, (_, i) => `<div class="wf-line ${i === count - 1 ? 'short' : ''}"></div>`).join('');

function wireframeToday() {
  return `<section class="screen"><div class="content">${wfHeader('Today', 'Settings')}
    <div class="wf-block"><div class="wf-row"><span class="wf-icon"></span><div class="wf-copy"><div class="wf-label"></div>${lines(1)}</div><span class="wf-chip">Listening</span></div></div>
    <div class="wf-stack">
      <div><div class="wf-label"></div><div class="wf-block" style="margin-top:10px">${lines(3)}</div></div>
      <div><div class="wf-label"></div><div class="wf-row"><span class="wf-icon"></span><div class="wf-copy">${lines(2)}</div></div><div class="wf-row"><span class="wf-icon"></span><div class="wf-copy">${lines(2)}</div></div></div>
      <div><div class="wf-label"></div><div class="wf-block" style="margin-top:10px">${lines(3)}</div></div>
    </div>
  </div><div class="wf-footer-action">Pause listening</div>${tabbar('today', true)}</section>`;
}

function wireframeTranscripts() {
  const row = (pending = false) => `<div class="wf-row"><span style="font-size:11px">10:42</span><div class="wf-copy">${lines(pending ? 1 : 3)}</div><span class="wf-chip">${pending ? 'Pending' : 'Done'}</span></div>`;
  return `<section class="screen"><div class="content">${wfHeader('Transcripts', 'Live')}
    <div class="wf-input">Search transcripts</div>
    <div class="wf-stack"><div class="wf-label"></div>${row(true)}${row()}${row()}<div class="wf-label" style="margin-top:18px"></div>${row()}${row()}</div>
  </div>${tabbar('transcripts', true)}</section>`;
}

function wireframeAsk() {
  return `<section class="screen"><div class="content">${wfHeader('Ask Echo', 'History')}
    <div class="wf-stack" style="margin-top:80px"><div class="wf-block"><div class="wf-label"></div>${lines(2)}</div><div style="display:flex;gap:8px;flex-wrap:wrap"><span class="wf-chip">Open tasks</span><span class="wf-chip">Yesterday</span><span class="wf-chip">People</span></div></div>
  </div><div style="position:absolute;left:16px;right:16px;bottom:82px;display:grid;grid-template-columns:1fr 48px;gap:8px"><div class="wf-input">Ask your memory…</div><div class="wf-button">↑</div></div>${tabbar('ask', true)}</section>`;
}

function wireframeSettings() {
  const row = (label) => `<div class="wf-row"><span class="wf-icon"></span><div class="wf-copy"><strong style="font-size:13px">${label}</strong>${lines(1)}</div><span>›</span></div>`;
  return `<section class="screen"><div class="content">${wfHeader('Settings')}
    <div class="wf-stack"><div class="wf-label"></div>${row('Device')}${row('Connection')}${row('Privacy')}<div class="wf-label" style="margin-top:18px"></div>${row('Automations')}${row('Diagnostics')}${row('About')}</div>
  </div></section>`;
}

function wireframeOnboarding() {
  return `<section class="screen"><div class="content">${wfHeader('Connect Echo')}
    <div style="display:flex;gap:6px;margin:12px 0 40px"><span class="wf-line" style="margin:0;flex:1;background:#4d5156"></span><span class="wf-line" style="margin:0;flex:1"></span><span class="wf-line" style="margin:0;flex:1"></span><span class="wf-line" style="margin:0;flex:1"></span></div>
    <div class="wf-stack"><div class="wf-label"></div>${lines(2)}<div class="wf-input">Server URL</div><div class="wf-input">API key</div></div>
  </div><div class="wf-footer-action">Continue</div></section>`;
}

function wireframeDevice() {
  const row = (name, value) => `<div class="wf-row"><div class="wf-copy"><strong style="font-size:13px">${name}</strong></div><span style="font-size:12px">${value}</span></div>`;
  return `<section class="screen"><div class="content">${wfHeader('Echo Wearable')}
    <div class="wf-block" style="text-align:center;padding:28px"><div class="wf-icon" style="margin:auto;width:56px;height:56px"></div><h3>Listening</h3><span class="wf-chip">Connected</span></div>
    <div class="wf-stack">${row('Battery','72%')}${row('Buffer','Empty')}${row('Last sync','Now')}${row('Firmware','0.1.0')}</div>
    <div class="wf-button" style="margin-top:28px">Forget wearable</div>
  </div></section>`;
}

function render() {
  root.className = `app-shell theme-${theme} ${mode === 'wireframe' ? 'wireframe' : ''}`;
  if (mode === 'visual') {
    root.innerHTML = ({
      today: () => todayVisual(wearableState),
      transcripts: transcriptsVisual,
      ask: askVisual,
      settings: settingsVisual,
      onboarding: onboardingVisual,
      device: deviceVisual,
    }[selectedScreen])();
  }
  else {
    root.innerHTML = ({
      today: wireframeToday,
      transcripts: wireframeTranscripts,
      ask: wireframeAsk,
      settings: wireframeSettings,
      onboarding: wireframeOnboarding,
      device: wireframeDevice,
    }[selectedScreen])();
  }
  lucide.createIcons({ attrs: { 'stroke-width': 1.8 } });
}

function selectButton(group, target) {
  group.querySelectorAll('button').forEach((button) => button.classList.toggle('active', button === target));
}

document.querySelector('#mode-control').addEventListener('click', (event) => {
  const button = event.target.closest('button');
  if (!button) return;
  mode = button.dataset.mode;
  selectButton(event.currentTarget, button);
  document.querySelector('#theme-control-wrap').classList.toggle('hidden', mode !== 'visual');
  document.querySelector('#state-control-wrap').classList.toggle('hidden', mode !== 'visual' || selectedScreen !== 'today');
  render();
});

document.querySelector('#theme-control').addEventListener('click', (event) => {
  const button = event.target.closest('button');
  if (!button) return;
  theme = button.dataset.theme;
  selectButton(event.currentTarget, button);
  render();
});

document.querySelector('#state-control').addEventListener('click', (event) => {
  const button = event.target.closest('button');
  if (!button) return;
  wearableState = button.dataset.state;
  selectButton(event.currentTarget, button);
  render();
});

document.querySelector('#screen-control').addEventListener('click', (event) => {
  const button = event.target.closest('button');
  if (!button) return;
  selectedScreen = button.dataset.screen;
  selectButton(event.currentTarget, button);
  document.querySelector('#state-control-wrap').classList.toggle('hidden', mode !== 'visual' || selectedScreen !== 'today');
  render();
});

render();
