'use strict';

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('textEntry', {
  submit: (text) => ipcRenderer.send('text-entry:submit', text),
  cancel: () => ipcRenderer.send('text-entry:cancel'),
});
