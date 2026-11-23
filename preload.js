const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('godal', {
  min: () => ipcRenderer.send('win:min'),
  max: () => ipcRenderer.send('win:max'),
  close: () => ipcRenderer.send('win:close'),
  info: () => ipcRenderer.invoke('sys:info'),
  watch: (cb) => { ipcRenderer.on('sys:tick', (_e, d) => cb(d)); ipcRenderer.send('sys:watch'); },
  run: (mode) => ipcRenderer.invoke('run:start', mode),
  onEvent: (cb) => ipcRenderer.on('run:event', (_e, d) => cb(d)),
  onDone: (cb) => ipcRenderer.on('run:done', (_e, d) => cb(d))
});
