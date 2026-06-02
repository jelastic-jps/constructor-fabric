#!/bin/bash
# Run the original startup.sh as root first (for system setup)
sudo /startup.sh

# Then run any commands as the developer user
exec "$@"
