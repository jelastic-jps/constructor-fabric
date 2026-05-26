# Constructor Fabric manifest source

This directory splits the JPS into logical source files, mirroring the way typical
Jelastic JPS repositories are organized (for example: manifest + configs + scripts + images + success/addon folders).

Layout:
- manifest.jps: assembled/publishable JPS artifact
- scripts/: operational shell scripts extracted from the monolithic manifest
- configs/: desktop/panel/file-manager configuration snippets
- trainer/: Electron trainer app files
- images/: wallpaper/media assets used by the showcase
- assets/: copied media assets and convenience files from the current worktree

Source reference repos on GitHub often use multi-folder layouts like:
- README.md
- manifest.jps
- configs/
- scripts/
- images/
- success/
- addon/

This local split is meant to make future edits easier: one file per concern instead of a single monolith.
