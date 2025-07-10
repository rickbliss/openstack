#!/usr/bin/env bash
##############################################################################
# deploy.sh – Run kolla-ansible deploy with syslog streaming and timing info
##############################################################################

set -euo pipefail

echo "Starting Reconfigure"

# Capture start timestamp (both human-readable and epoch seconds)
START_TS="$(date '+%Y-%m-%d %H:%M:%S')"
START_EPOCH=$(date +%s)

# Activate virtualenv
source /opt/kolla-venv/bin/activate
echo "disable ceph orch"
sudo ceph orch pause
# Clear ansible log
echo '' > /etc/kolla/ansible.log
# Start tailing the log in the background with per-line timestamp
tail -f /etc/kolla/ansible.log | logger -t ansible-reconfig -n syslog.localdomain -d -P 5140 &
echo "after tail"
# Store PID of tail process so we can kill it later if needed
TAIL_PID=$!

# Run kolla-ansible deploy
kolla-ansible reconfigure -i /etc/kolla/multinode -v

# Capture end timestamp
END_TS="$(date '+%Y-%m-%d %H:%M:%S')"
END_EPOCH=$(date +%s)

# Compute duration
DURATION_SEC=$((END_EPOCH - START_EPOCH))
DURATION_FMT=$(printf '%02d:%02d:%02d' $((DURATION_SEC/3600)) $(( (DURATION_SEC/60)%60 )) $((DURATION_SEC%60)))

# Stop tail process
kill $TAIL_PID

sudo ceph orch resume
echo 'ceph orch RESUMED.'
# Display summary
echo "=========================================="
echo "Reconfig started:  $START_TS"
echo "Reconfig finished: $END_TS"
echo "Duration:        $DURATION_FMT (HH:MM:SS)"
echo "=========================================="
