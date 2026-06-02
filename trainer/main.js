const { app, BrowserWindow, shell } = require('electron');
const path = require('path');
app.commandLine.appendSwitch('no-sandbox');
function createWindow() {
  const win = new BrowserWindow({
    width: 900,
    height: 620,
    minWidth: 760,
    minHeight: 500,
    x: 100,
    y: 50,
    title: 'Constructor Fabric Trainer',
    backgroundColor: '#162a42',
    webPreferences: { nodeIntegration: false, contextIsolation: true }
  });
  win.removeMenu();
  win.loadFile(path.join(__dirname, 'index.html'));
  win.webContents.setWindowOpenHandler(({ url }) => { shell.openExternal(url); return { action: 'deny' }; });
}
app.whenReady().then(createWindow);
app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
