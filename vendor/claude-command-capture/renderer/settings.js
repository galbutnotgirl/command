'use strict';

const el = (id) => document.getElementById(id);
let defaults = null;

function fillForm(settings) {
  el('skill').value = settings.skill || '';
  el('promptTemplate').value = settings.promptTemplate || '';
  el('imagePromptTemplate').value = settings.imagePromptTemplate || '';
  el('cliCommand').value = settings.cli.command || '';
  el('cliCwd').value = settings.cli.cwd || '';
  el('cliExtraArgs').value = (settings.cli.extraArgs || []).join('\n');
  el('hotkeyText').value = settings.hotkeys.text || '';
  el('hotkeyClipboard').value = settings.hotkeys.clipboard || '';
  el('hotkeySelection').value = settings.hotkeys.selection || '';
  el('hotkeyScreenshot').value = settings.hotkeys.screenshot || '';
  el('notifications').checked = !!settings.notifications;
}

function readForm() {
  return {
    skill: el('skill').value.trim(),
    promptTemplate: el('promptTemplate').value,
    imagePromptTemplate: el('imagePromptTemplate').value,
    cli: {
      command: el('cliCommand').value.trim() || 'claude',
      baseArgs: ['-p'],
      extraArgs: el('cliExtraArgs')
        .value.split('\n')
        .map((line) => line.trim())
        .filter(Boolean),
      cwd: el('cliCwd').value.trim(),
    },
    hotkeys: {
      text: el('hotkeyText').value.trim(),
      clipboard: el('hotkeyClipboard').value.trim(),
      selection: el('hotkeySelection').value.trim(),
      screenshot: el('hotkeyScreenshot').value.trim(),
    },
    notifications: el('notifications').checked,
  };
}

function setStatus(message) {
  el('status').textContent = message;
  if (message) {
    setTimeout(() => {
      if (el('status').textContent === message) el('status').textContent = '';
    }, 4000);
  }
}

async function init() {
  const { settings, defaults: d } = await window.settingsApi.get();
  defaults = d;
  fillForm(settings);
}

el('save').addEventListener('click', async () => {
  await window.settingsApi.save(readForm());
  setStatus('Saved. Hotkeys re-registered.');
});

el('reset').addEventListener('click', () => {
  if (defaults) {
    fillForm(defaults);
    setStatus('Defaults restored — press Save to apply.');
  }
});

el('cli-test').addEventListener('click', async () => {
  const result = el('cli-test-result');
  result.className = '';
  result.textContent = 'Testing…';
  const { ok, output } = await window.settingsApi.testCli(el('cliCommand').value.trim());
  result.className = ok ? 'ok' : 'err';
  result.textContent = ok ? `OK: ${output}` : `Failed: ${output}`;
});

init();
