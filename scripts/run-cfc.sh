        #!/bin/bash
        export HOME="${HOME:-/home/developer}"
        export PATH=${HOME}/cyber-constructor/.venv/bin:${HOME}/.local/bin:/usr/local/bin:/opt/node-current/bin:$PATH
        exec ${HOME}/cyber-constructor/auto-bootstrap.sh
