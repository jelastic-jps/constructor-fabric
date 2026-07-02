        #!/bin/bash
        export HOME="${HOME:-/home/developer}"
        export PATH=${HOME}/studio/.venv/bin:${HOME}/.local/bin:/usr/local/bin:/opt/node-current/bin:$PATH
        exec ${HOME}/studio/auto-bootstrap.sh
