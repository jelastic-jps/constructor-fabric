# Constructor Fabric manifest source

This directory splits the JPS into logical source files, mirroring the way typical
Jelastic JPS repositories are organized (for example: manifest + configs + scripts + images + success/addon folders).

Layout:
- manifest.jps: assembled/publishable JPS artifact
- Dockerfile: Docker Hub image build for the Constructor Fabric node
- scripts/: operational shell scripts extracted from the monolithic manifest
- configs/: desktop/panel/file-manager configuration snippets
- trainer/: interactive Trainer for code-server — extension/ (webview backend + check runner), ui/ (renderer), content/ (curriculum + TaskLite brief); single source of truth for all training content
- docs/trainer/: Trainer requirements and design — living documents, kept current as the Trainer evolves
- images/: wallpaper/media assets used by the showcase
- assets/: copied media assets and convenience files from the current worktree

Published runtime image:
- sstimss/constructor-fabric (date-tagged, pinned in manifest.jps)

Source reference repos on GitHub often use multi-folder layouts like:
- README.md
- manifest.jps
- configs/
- scripts/
- images/
- success/
- addon/

This local split is meant to make future edits easier: one file per concern instead of a single monolith.
