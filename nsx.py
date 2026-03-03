#!/usr/bin/env python3
"""
NSX 4.x SNAT Connection & Top Talkers Query Tool
===================================================
Connects to VMware NSX Manager (Policy API) and retrieves all
Source NAT (SNAT) rules configured on every Tier-0 and Tier-1 gateway,
including per-rule traffic statistics and a ranked "top talkers" summary.

Requirements:
    pip install requests tabulate

Usage:
    python nsx_snat_query.py --host nsx-manager.example.com --user admin
    python nsx_snat_query.py --host nsx-manager.example.com --user admin --insecure
    python nsx_snat_query.py --host nsx-manager.example.com --user admin --top 10
    python nsx_snat_query.py --host nsx-manager.example.com --user admin --sort-by bytes
    python nsx_snat_query.py --host nsx-manager.example.com --user admin --json snat.json
"""

import argparse
import getpass
import json
import sys
from datetime import datetime

import requests
from requests.auth import HTTPBasicAuth
from tabulate import tabulate

# Suppress InsecureRequestWarning when --insecure is used
import urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)


class NSXClient:
    """Lightweight client for the NSX 4.x Policy API."""

    def __init__(self, host: str, username: str, password: str, verify_ssl: bool = True, port: int = 443):
        self.base_url = f"https://{host}:{port}"
        self.policy_url = f"{self.base_url}/policy/api/v1"
        self.session = requests.Session()
        self.session.auth = HTTPBasicAuth(username, password)
        self.session.verify = verify_ssl
        self.session.headers.update({
            "Content-Type": "application/json",
            "Accept": "application/json",
        })

    # ------------------------------------------------------------------ #
    #  Generic helpers
    # ------------------------------------------------------------------ #
    def _get(self, path: str, params: dict | None = None) -> dict:
        """GET with automatic pagination (cursor-based)."""
        results = []
        url = f"{self.policy_url}{path}"

        while url:
            resp = self.session.get(url, params=params)
            resp.raise_for_status()
            data = resp.json()
            results.extend(data.get("results", []))
            cursor = data.get("cursor")
            if cursor and data.get("result_count", 0) > len(results):
                params = params or {}
                params["cursor"] = cursor
            else:
                url = None
                params = None

        return results

    def test_connection(self) -> bool:
        """Verify credentials and connectivity."""
        resp = self.session.get(f"{self.policy_url}/infra")
        resp.raise_for_status()
        return True

    # ------------------------------------------------------------------ #
    #  Gateway (router) discovery
    # ------------------------------------------------------------------ #
    def get_tier0_gateways(self) -> list[dict]:
        return self._get("/infra/tier-0s")

    def get_tier1_gateways(self) -> list[dict]:
        return self._get("/infra/tier-1s")

    # ------------------------------------------------------------------ #
    #  NAT rule queries
    # ------------------------------------------------------------------ #
    def get_nat_rules(self, gateway_type: str, gateway_id: str) -> list[dict]:
        """
        Retrieve NAT rules for a gateway.

        gateway_type: 'tier-0s' or 'tier-1s'
        gateway_id:   the gateway's id field
        """
        path = f"/infra/{gateway_type}/{gateway_id}/nat/USER/nat-rules"
        return self._get(path)

    def get_snat_rules(self, gateway_type: str, gateway_id: str) -> list[dict]:
        """Return only SNAT rules for a given gateway."""
        all_rules = self.get_nat_rules(gateway_type, gateway_id)
        return [r for r in all_rules if r.get("action") == "SNAT"]

    # ------------------------------------------------------------------ #
    #  NAT statistics (live connection counts)
    # ------------------------------------------------------------------ #
    def get_nat_statistics(self, gateway_type: str, gateway_id: str) -> list[dict]:
        """
        Get NAT statistics (active sessions / packet counts) from the
        Policy API realized-state endpoint for the specified gateway.
        """
        path = f"/infra/{gateway_type}/{gateway_id}/nat/USER/statistics"
        try:
            return self._get(path)
        except requests.exceptions.HTTPError:
            # Some deployments don't expose stats at this path
            return []

    def get_nat_rule_statistics(self, gateway_type: str, gateway_id: str,
                                rule_id: str) -> dict:
        """
        Get per-rule realized statistics including byte/packet counters
        and active session counts from the edge transport nodes.
        """
        path = (f"/infra/{gateway_type}/{gateway_id}"
                f"/nat/USER/nat-rules/{rule_id}/statistics")
        try:
            results = self._get(path)
            # Aggregate across edge nodes if multiple results
            totals = {
                "active_sessions": 0,
                "total_bytes_in": 0,
                "total_bytes_out": 0,
                "total_bytes": 0,
                "total_packets_in": 0,
                "total_packets_out": 0,
                "total_packets": 0,
                "edge_nodes": [],
            }
            for node_stat in results:
                rs = node_stat.get("rule_statistics", node_stat)
                totals["active_sessions"] += _int(rs.get("active_sessions"))
                totals["total_bytes_in"] += _int(rs.get("bytes_in"))
                totals["total_bytes_out"] += _int(rs.get("bytes_out"))
                totals["total_packets_in"] += _int(rs.get("packets_in"))
                totals["total_packets_out"] += _int(rs.get("packets_out"))
                totals["total_bytes"] += (
                    _int(rs.get("total_bytes"))
                    or _int(rs.get("bytes_in")) + _int(rs.get("bytes_out"))
                )
                totals["total_packets"] += (
                    _int(rs.get("total_packets"))
                    or _int(rs.get("packets_in")) + _int(rs.get("packets_out"))
                )
                edge = node_stat.get("transport_node_id") or node_stat.get("edge_node_path", "")
                if edge:
                    totals["edge_nodes"].append(edge)
            return totals
        except requests.exceptions.HTTPError:
            return {}

    def get_gateway_interface_stats(self, gateway_type: str, gateway_id: str) -> list[dict]:
        """
        Fetch interface statistics for a gateway — useful for seeing
        aggregate throughput on the router's uplink/downlink interfaces.
        """
        path = f"/infra/{gateway_type}/{gateway_id}/locale-services"
        try:
            locale_services = self._get(path)
            all_stats = []
            for ls in locale_services:
                ls_id = ls["id"]
                iface_path = (f"/infra/{gateway_type}/{gateway_id}"
                              f"/locale-services/{ls_id}/interfaces")
                try:
                    interfaces = self._get(iface_path)
                    for iface in interfaces:
                        iface_id = iface["id"]
                        stat_path = (f"/infra/{gateway_type}/{gateway_id}"
                                     f"/locale-services/{ls_id}"
                                     f"/interfaces/{iface_id}/statistics")
                        try:
                            stats = self._get(stat_path)
                            for s in stats:
                                s["interface_name"] = iface.get("display_name", iface_id)
                                s["gateway_name"] = gateway_id
                            all_stats.extend(stats)
                        except requests.exceptions.HTTPError:
                            pass
                except requests.exceptions.HTTPError:
                    pass
            return all_stats
        except requests.exceptions.HTTPError:
            return []


def _int(val) -> int:
    """Safely cast to int, defaulting to 0."""
    if val is None:
        return 0
    try:
        return int(val)
    except (ValueError, TypeError):
        return 0


def _human_bytes(nbytes: int) -> str:
    """Convert bytes to human-readable string."""
    if nbytes == 0:
        return "0 B"
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(nbytes) < 1024:
            return f"{nbytes:.1f} {unit}"
        nbytes /= 1024
    return f"{nbytes:.1f} PB"


def _human_count(n: int) -> str:
    """Shorten large numbers: 1234567 -> 1.2M."""
    if n == 0:
        return "0"
    for unit, threshold in [("G", 1_000_000_000), ("M", 1_000_000), ("K", 1_000)]:
        if abs(n) >= threshold:
            return f"{n / threshold:.1f}{unit}"
    return str(n)


def collect_snat_data(client: NSXClient) -> list[dict]:
    """Walk every T0/T1 gateway and collect SNAT rules + per-rule stats."""
    rows = []

    for gw_type, label in [("tier-0s", "Tier-0"), ("tier-1s", "Tier-1")]:
        gateways = (client.get_tier0_gateways() if gw_type == "tier-0s"
                    else client.get_tier1_gateways())

        for gw in gateways:
            gw_id = gw["id"]
            gw_name = gw.get("display_name", gw_id)
            print(f"  Querying {label} gateway: {gw_name} …")

            snat_rules = client.get_snat_rules(gw_type, gw_id)

            # Bulk stats as a fallback
            bulk_stats_map: dict[str, dict] = {}
            try:
                bulk_stats = client.get_nat_statistics(gw_type, gw_id)
                for s in bulk_stats:
                    rule_id = s.get("rule_id") or s.get("id")
                    if rule_id:
                        bulk_stats_map[rule_id] = s
            except Exception:
                pass

            if not snat_rules:
                rows.append({
                    "gateway_type": label,
                    "gateway": gw_name,
                    "rule_id": "—",
                    "rule_name": "(no SNAT rules)",
                    "source_network": "",
                    "destination_network": "",
                    "translated_network": "",
                    "service": "",
                    "enabled": "",
                    "logging": "",
                    "active_sessions": 0,
                    "total_packets": 0,
                    "total_bytes": 0,
                    "bytes_in": 0,
                    "bytes_out": 0,
                    "packets_in": 0,
                    "packets_out": 0,
                })
                continue

            for rule in snat_rules:
                rid = rule.get("id", "")

                # Try per-rule stats first (more detailed), fall back to bulk
                per_rule = client.get_nat_rule_statistics(gw_type, gw_id, rid)
                bulk = bulk_stats_map.get(rid, {})

                active = (per_rule.get("active_sessions")
                          or _int(bulk.get("active_sessions")))
                total_pkts = (per_rule.get("total_packets")
                              or _int(bulk.get("total_packets")))
                total_bytes = (per_rule.get("total_bytes")
                               or _int(bulk.get("total_bytes")))
                bytes_in = per_rule.get("total_bytes_in", 0)
                bytes_out = per_rule.get("total_bytes_out", 0)
                pkts_in = per_rule.get("total_packets_in", 0)
                pkts_out = per_rule.get("total_packets_out", 0)

                rows.append({
                    "gateway_type": label,
                    "gateway": gw_name,
                    "rule_id": rid,
                    "rule_name": rule.get("display_name", rid),
                    "source_network": rule.get("source_network", "ANY"),
                    "destination_network": rule.get("destination_network", "ANY"),
                    "translated_network": rule.get("translated_network", ""),
                    "service": rule.get("service", "ANY"),
                    "enabled": str(rule.get("enabled", True)),
                    "logging": str(rule.get("logging", False)),
                    "active_sessions": active,
                    "total_packets": total_pkts,
                    "total_bytes": total_bytes,
                    "bytes_in": bytes_in,
                    "bytes_out": bytes_out,
                    "packets_in": pkts_in,
                    "packets_out": pkts_out,
                })

    return rows


def print_table(rows: list[dict]) -> None:
    """Pretty-print the collected data."""
    if not rows:
        print("\n  No gateways found.")
        return

    display_rows = []
    for r in rows:
        display_rows.append({
            "gateway_type": r["gateway_type"],
            "gateway": r["gateway"],
            "rule_id": r["rule_id"],
            "rule_name": r["rule_name"],
            "source_network": r["source_network"],
            "destination_network": r["destination_network"],
            "translated_network": r["translated_network"],
            "service": r["service"],
            "enabled": r["enabled"],
            "logging": r["logging"],
            "active_sessions": _human_count(r["active_sessions"]) if r["active_sessions"] else "",
            "total_packets": _human_count(r["total_packets"]) if r["total_packets"] else "",
            "total_bytes": _human_bytes(r["total_bytes"]) if r["total_bytes"] else "",
        })

    headers = {
        "gateway_type": "Type",
        "gateway": "Gateway",
        "rule_id": "Rule ID",
        "rule_name": "Rule Name",
        "source_network": "Source",
        "destination_network": "Destination",
        "translated_network": "Translated (SNAT IP)",
        "service": "Service",
        "enabled": "Enabled",
        "logging": "Log",
        "active_sessions": "Active Sessions",
        "total_packets": "Packets",
        "total_bytes": "Bytes",
    }

    print(tabulate(display_rows, headers=headers, tablefmt="grid"))


# ------------------------------------------------------------------ #
#  Top Talkers
# ------------------------------------------------------------------ #

SORT_KEYS = {
    "bytes":    "total_bytes",
    "packets":  "total_packets",
    "sessions": "active_sessions",
}


def print_top_talkers(rows: list[dict], top_n: int = 10,
                      sort_by: str = "bytes") -> None:
    """
    Print a ranked list of the highest-traffic SNAT rules.

    sort_by: 'bytes', 'packets', or 'sessions'
    """
    sort_field = SORT_KEYS.get(sort_by, "total_bytes")

    # Filter out placeholder rows (no real rules)
    real = [r for r in rows if r["rule_id"] != "—"]
    if not real:
        print("\n  No SNAT rules to rank.")
        return

    ranked = sorted(real, key=lambda r: r.get(sort_field, 0), reverse=True)[:top_n]

    print(f"\n{'=' * 80}")
    print(f"  TOP {min(top_n, len(ranked))} SNAT TALKERS  (sorted by {sort_by})")
    print(f"{'=' * 80}\n")

    talker_rows = []
    for i, r in enumerate(ranked, 1):
        talker_rows.append({
            "rank": i,
            "gateway": f"{r['gateway_type']} / {r['gateway']}",
            "rule_name": r["rule_name"],
            "source": r["source_network"],
            "snat_ip": r["translated_network"],
            "sessions": _human_count(r["active_sessions"]),
            "packets_in": _human_count(r["packets_in"]),
            "packets_out": _human_count(r["packets_out"]),
            "bytes_in": _human_bytes(r["bytes_in"]),
            "bytes_out": _human_bytes(r["bytes_out"]),
            "total_bytes": _human_bytes(r["total_bytes"]),
        })

    headers = {
        "rank": "#",
        "gateway": "Gateway",
        "rule_name": "Rule",
        "source": "Source Network",
        "snat_ip": "SNAT IP",
        "sessions": "Sessions",
        "packets_in": "Pkts In",
        "packets_out": "Pkts Out",
        "bytes_in": "Bytes In",
        "bytes_out": "Bytes Out",
        "total_bytes": "Total Bytes",
    }

    print(tabulate(talker_rows, headers=headers, tablefmt="grid"))

    # Summary totals
    total_sessions = sum(r["active_sessions"] for r in real)
    total_bytes = sum(r["total_bytes"] for r in real)
    total_pkts = sum(r["total_packets"] for r in real)

    print(f"\n  Aggregate across all SNAT rules:")
    print(f"    Active sessions : {_human_count(total_sessions)}")
    print(f"    Total packets   : {_human_count(total_pkts)}")
    print(f"    Total bytes     : {_human_bytes(total_bytes)}")

    if len(ranked) > 0 and total_bytes > 0:
        top_bytes = sum(r["total_bytes"] for r in ranked)
        pct = (top_bytes / total_bytes) * 100
        print(f"    Top {len(ranked)} account for : {pct:.1f}% of total byte volume")


def export_json(rows: list[dict], filepath: str) -> None:
    with open(filepath, "w") as f:
        json.dump(rows, f, indent=2)
    print(f"\n  Results exported to {filepath}")


# ------------------------------------------------------------------ #
#  CLI
# ------------------------------------------------------------------ #
def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Query all SNAT rules/connections from VMware NSX 4.x gateways."
    )
    p.add_argument("--host", required=True, help="NSX Manager hostname or IP")
    p.add_argument("--port", type=int, default=443, help="NSX Manager port (default 443)")
    p.add_argument("--user", required=True, help="NSX username (e.g. admin)")
    p.add_argument("--password", default=None, help="NSX password (prompted if omitted)")
    p.add_argument("--insecure", action="store_true", help="Disable SSL certificate verification")
    p.add_argument("--json", dest="json_file", default=None, metavar="FILE",
                    help="Export results to a JSON file")
    p.add_argument("--top", type=int, default=10, metavar="N",
                    help="Show top N talkers (default 10, 0 to disable)")
    p.add_argument("--sort-by", choices=["bytes", "packets", "sessions"],
                    default="bytes",
                    help="Sort top talkers by: bytes, packets, or sessions (default: bytes)")
    return p.parse_args()


def main() -> None:
    args = parse_args()
    password = args.password or getpass.getpass(f"Password for {args.user}@{args.host}: ")

    client = NSXClient(
        host=args.host,
        username=args.user,
        password=password,
        verify_ssl=not args.insecure,
        port=args.port,
    )

    print(f"\n{'=' * 60}")
    print(f"  NSX SNAT Query — {args.host}")
    print(f"  {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"{'=' * 60}\n")

    # Verify connectivity
    try:
        client.test_connection()
        print("  ✓ Connected to NSX Manager\n")
    except requests.exceptions.SSLError:
        print("  ✗ SSL verification failed. Re-run with --insecure or fix certificates.", file=sys.stderr)
        sys.exit(1)
    except requests.exceptions.ConnectionError as e:
        print(f"  ✗ Connection failed: {e}", file=sys.stderr)
        sys.exit(1)
    except requests.exceptions.HTTPError as e:
        print(f"  ✗ Authentication failed: {e}", file=sys.stderr)
        sys.exit(1)

    # Collect SNAT data
    rows = collect_snat_data(client)

    # Full rule listing
    print()
    print_table(rows)

    # Top talkers
    if args.top > 0:
        print_top_talkers(rows, top_n=args.top, sort_by=args.sort_by)

    if args.json_file:
        export_json(rows, args.json_file)

    snat_count = sum(1 for r in rows if r["rule_id"] != "—")
    print(f"\n  Total SNAT rules found: {snat_count}\n")


if __name__ == "__main__":
    main()
