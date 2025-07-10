#!/usr/bin/env bash
set -euo pipefail

echo "🔍 Getting list of slow OSDs..."
SLOW_OSDS=$(sudo ceph health detail --format json | jq -r '.checks.BLUESTORE_SLOW_OP_ALERT.detail[].message' | awk '{print $1}' | sort -u)

if [[ -z "$SLOW_OSDS" ]]; then
  echo "✅ No slow OSDs found."
  exit 0
fi

echo "⚠️  Slow OSDs detected: $SLOW_OSDS"
echo ""

# Loop over OSD IDs
for osd in $SLOW_OSDS; do
  osd_id="${osd#osd.}"
  echo "→ Fetching metadata for OSD $osd_id..."

  sudo ceph osd metadata "$osd_id" | jq -r '
    {
      osd_id: .id,
      host: .container_hostname,
      device_ids: .device_ids,
      device_paths: .device_paths,
      size_tib: ((.bluestore_bdev_size | tonumber) / (1024*1024*1024*1024)),
      rotational: .rotational
    }'
  echo ""
done

