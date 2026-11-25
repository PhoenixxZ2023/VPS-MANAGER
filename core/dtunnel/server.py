"""Ponto de entrada do serviço BHTTP DTunnel do VPS-MANAGER."""
import argparse
from pathlib import Path
import sys
import threading

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import BHTTP

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("host", choices=("0.0.0.0", "127.0.0.1"))
    parser.add_argument("port", type=int)
    parser.add_argument("--ssh-port", type=int, default=22)
    args = parser.parse_args()
    BHTTP.CONFIG["proxy"]["target"]["port"] = args.ssh_port
    sessions = {}
    pool = BHTTP.IPPool(BHTTP.CONFIG["server"]["virtual_subnet_cidr"])
    threading.Thread(target=BHTTP.cleanup_sessions, args=(sessions, pool), daemon=True).start()
    BHTTP.start_listener(args.host, args.port, False, sessions, pool)
