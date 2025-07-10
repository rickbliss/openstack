for h in bc00 bc02 bc03; 
  do 
    echo "Stopping corosync on $h"
    ssh "$h" "sudo podman stop hacluster_corosync"
    echo "Stopping pacemaker on $h"
    ssh "$h" "sudo podman stop hacluster_pacemaker"
  done
echo "Done."    
