import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "core/hcr3"))
from haproxy_route import change


class SharedPorts(unittest.TestCase):
    def test_install_and_remove_either_protocol_first(self):
        original = ("frontend multi_front\n    bind *:80\n    bind *:8080\n"
                    "    tcp-request inspect-delay 3s\n    tcp-request content accept if { req.len gt 0 }\n"
                    "    use_backend ssh_ws if { req.len gt 0 }\n    default_backend ssh_ws\n"
                    "backend ssh_ws\n    mode tcp\n")
        for first, second in (("dtunnel", "hcr"), ("hcr", "dtunnel")):
            for other_port in (80, 8080):
                with self.subTest(first=first, other_port=other_port), TemporaryDirectory() as tmp:
                    cfg = Path(tmp) / "haproxy.cfg"
                    cfg.write_text(original)
                    change(cfg, 80, False, first)
                    change(cfg, other_port, False, second)
                    both = cfg.read_text()
                    self.assertLess(both.index("use_backend dtunnel_local"), both.index("use_backend hcr3_local"))
                    self.assertLess(both.index("content track-sc0"), both.index("content accept"))
                    change(cfg, None, False, first)
                    remaining = cfg.read_text()
                    for name, route in (("dtunnel", "dtunnel_local"), ("hcr", "hcr3_local")):
                        self.assertEqual(route in remaining, name == second)
                    change(cfg, None, False, second)
                    self.assertEqual(cfg.read_text(), original)
