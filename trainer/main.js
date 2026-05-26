        const { app, BrowserWindow, shell } = require('electron');
        const path = require('path');
        app.commandLine.appendSwitch('no-sandbox');
        function createWindow() {
          const win = new BrowserWindow({
            width: 1000,
            height: 700,
            minWidth: 860,
            minHeight: 600,
            x: 260,
            y: 120,
            title: 'Constructor Fabric Trainer',
            backgroundColor: '#07111f',
            webPreferences: { nodeIntegration: false, contextIsolation: true }
          });
          win.removeMenu();
          win.loadFile(path.join(__dirname, 'index.html'));
          win.webContents.setWindowOpenHandler(({ url }) => { shell.openExternal(url); return { action: 'deny' }; });
        }
        app.whenReady().then(createWindow);
        app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
        app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
