"""Encaminhamento HCR nos frontends públicos do VPS-MANAGER."""
import argparse
import fcntl
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import tempfile

BEGIN = "# VPS-MANAGER HCR3 BEGIN"
END = "# VPS-MANAGER HCR3 END"


def block(lines):
    return BEGIN + "\n" + "\n".join(lines) + "\n" + END + "\n"


def render(config, port, dt_port=None):
    config = re.sub(r"(?m)^" + BEGIN + r"\n[\s\S]*?^" + END + r"\n", "", config)
    if port is None and dt_port is None:
        return config
    front = re.search(r"(?ms)^frontend multi_front\s*\n(.*?)(?=^(?:frontend|backend|listen|defaults|global)\s|\Z)", config)
    if not front or any(not re.search(rf"(?m)^    bind \*:{p}(?:\s|$)", front[1])
                        for p in (port, dt_port) if p):
        raise ValueError("Porta ausente no frontend multi_front do VPS-MANAGER.")
    inspect = front[1].find("    tcp-request content accept")
    route = front[1].find("    use_backend")
    if min(inspect, route) < 0:
        raise ValueError("Frontend sem inspeção TCP ou sem rotas.")
    checks, rules, backends = [], [], []
    if dt_port:
        checks += [
            f"    acl dt_port dst_port {dt_port}",
            "    acl dt_mode req.payload(0,1) -m bin 00 01 02 03 04",
            "    acl dt_probe req.payload(0,1) -m bin 00",
            "    acl dt_seq0 req.payload(17,8) -m bin 0000000000000000",
            "    acl dt_sid req.payload(1,16),in_table(dtunnel_sessions) -m bool",
            "    tcp-request content reject if dt_port dt_mode !{ req.payload(0,29) -m found }",
            "    tcp-request content track-sc0 req.payload(1,16) table dtunnel_sessions if dt_port dt_probe dt_seq0",
            "    tcp-request content track-sc0 req.payload(1,16) table dtunnel_sessions if dt_port dt_mode dt_sid",
        ]
        rules.append("    use_backend dtunnel_local if dt_port dt_mode dt_sid")
        backends += ["backend dtunnel_sessions", "    stick-table type binary len 16 size 64k expire 10m peers dtunnel_sync",
                     "peers dtunnel_sync", f"    peer {socket.gethostname()} /run/haproxy/dtunnel-peers.sock",
                     "backend dtunnel_local", "    mode tcp", "    server dtunnel 127.0.0.1:18884"]
    if port:
        checks += [
            f"    acl hcr3_port dst_port {port}",
            "    acl hcr3_op req.payload(0,1) -m bin 01 02 03 04 05 06",
            "    acl hcr3_version req.payload(1,1) -m bin 01",
            "    acl hcr3_tls req.payload(0,2) -m bin 1603",
            "    tcp-request content reject if hcr3_port { req.payload(0,1) -m bin 01 02 03 04 05 06 16 } !{ req.payload(0,2) -m found }",
        ]
        rules += ["    use_backend hcr3_local if hcr3_port hcr3_op hcr3_version",
                  "    use_backend hcr3_local if hcr3_port hcr3_tls"]
        backends += ["backend hcr3_local", "    mode tcp", "    server hcr 127.0.0.1:18883 send-proxy"]
    start = front.start(1)
    return (config[:start+inspect] + block(checks) + config[start+inspect:start+route] +
            block(rules) + config[start+route:]).rstrip() + "\n" + block(backends)


def change(path, port, live, protocol):
    original = path.read_bytes()
    config = original.decode()
    def existing(label):
        match = re.search(rf"(?m)^    acl {label} dst_port (80|8080)$", config)
        return int(match[1]) if match else None
    hcr = port if protocol == "hcr" else existing("hcr3_port")
    dt = port if protocol == "dtunnel" else existing("dt_port")
    updated = render(config, hcr, dt).encode()
    if updated == original:
        return
    with tempfile.TemporaryDirectory(dir=path.parent) as folder:
        temp = Path(folder) / "haproxy.cfg"
        shutil.copy2(path, temp)
        temp.write_bytes(updated)
        if live:
            subprocess.run(["haproxy", "-c", "-f", str(temp)], check=True)
        os.replace(temp, path)
        if live:
            try:
                subprocess.run(["systemctl", "reload", "haproxy"], check=True)
            except subprocess.CalledProcessError:
                shutil.copy2(path, temp)
                temp.write_bytes(original)
                os.replace(temp, path)
                subprocess.run(["systemctl", "reload", "haproxy"], check=True)
                raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("config", type=Path)
    parser.add_argument("port", choices=("80", "8080", "remove"))
    parser.add_argument("--live", action="store_true")
    parser.add_argument("--protocol", choices=("hcr", "dtunnel"), default="hcr")
    args = parser.parse_args()
    with open(str(args.config) + ".route-lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        change(args.config, None if args.port == "remove" else int(args.port), args.live, args.protocol)
