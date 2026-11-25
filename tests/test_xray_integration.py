"""Execute com python3 -m unittest discover -s tests (bot requer python-telegram-bot 20.7)."""
import asyncio
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "core/xray"))
import xray_accounts as accounts

loader = importlib.machinery.SourceFileLoader("provision", str(ROOT / "core/xray/provision"))
provision = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(provision)


class Integration(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.tmp = Path(temp.name)
        self.config = self.tmp / "config.json"
        self.db = self.tmp / "users.db"
        subprocess.run(
            ["bash", "-c", 'ENGINE_LIB=1 source "$1"; eng build "$2" "$3" 0 1',
             "bash", str(ROOT / "core/xray_manager.sh"), str(self.tmp / "empty"), str(self.config)],
            check=True, capture_output=True,
        )
        for target, values in [(accounts, dict(CONFIG_PATH=str(self.config), USER_DB=str(self.db))),
                               (provision, dict(CONFIG=self.config, DB=self.db, VPS=self.tmp))]:
            p = patch.multiple(target, **values)
            p.start()
            self.addCleanup(p.stop)

    def test_profiles_and_duplicate_user(self):
        original = self.config.read_bytes()
        for tag in ("vless-ws", "vless-grpc", "vless-xhttp"):
            with self.subTest(tag=tag), patch.object(accounts, "managed_tag", return_value=tag), \
                 patch.object(accounts, "_get_active_domain", return_value="vpn.example.org"), \
                 patch.object(accounts, "reload_xray_user", return_value=True):
                self.config.write_bytes(original)
                self.db.unlink(missing_ok=True)
                summary = provision.mutate("xray", "maria", ["7"])
                uuid = self.db.read_text().split("|")[1]
                self.assertTrue(summary.endswith("UUID: " + uuid))
                self.assertIn(f"{uuid}@vpn.example.org:443?", summary)
                cfg = json.loads(self.config.read_text())
                self.assertTrue(all(i["listen"] == "127.0.0.1" for i in cfg["inbounds"]))
                clients = next(i["settings"]["clients"] for i in cfg["inbounds"] if i["tag"] == tag)
                self.assertEqual(clients[0]["id"], uuid)
                with self.assertRaisesRegex(ValueError, "já existe"):
                    provision.mutate("xray", "maria", ["7"])
                self.assertEqual(len(self.db.read_text().splitlines()), 1)
                self.assertIn("removido", provision.mutate("delete", "maria", []))

    def test_runtime_failure_restores_config_and_db(self):
        original = self.config.read_bytes()
        with patch.object(accounts, "reload_xray_user", side_effect=RuntimeError("API")), \
             patch.object(subprocess, "run") as restart:
            with self.assertRaises(RuntimeError):
                provision.mutate("xray", "maria", ["7"])
            restart.assert_called_once_with(["systemctl", "restart", "xray"], check=True)
        self.assertEqual(self.config.read_bytes(), original)
        self.assertFalse(self.db.exists())

    def test_existing_ssh_does_not_change_password(self):
        with patch.object(provision, "connection_info", return_value=[]), \
             patch.object(subprocess, "run", return_value=SimpleNamespace(returncode=9)) as run:
            with self.assertRaisesRegex(ValueError, "disponível"):
                provision.request(["ssh", "maria", "teste123", "30", "3"])
            self.assertEqual([call.args[0][0] for call in run.call_args_list], ["useradd"])
        self.assertFalse((self.tmp / "limite_maria").exists())

    def test_ssh_bot_paths(self):
        with patch.dict(os.environ, BOT_TOKEN="test", ADMIN_ID="123"):
            import botxray as bot
        for active, answer in ((False, None), (True, "não"), (True, "sim")):
            with self.subTest(active=active, answer=answer):
                response = {"ssh": "Conta SSH criada\nLimite SSH: 3", "active": "sim" if active else "não",
                            "xray": "UUID: exemplo"}
                with patch.object(bot, "provision", side_effect=lambda action, *args: response[action]) as create:
                    msg = SimpleNamespace(reply_text=AsyncMock())
                    update = SimpleNamespace(message=msg, effective_user=SimpleNamespace(id=123),
                                             effective_chat=SimpleNamespace(type="private"))
                    context = SimpleNamespace(user_data={})
                    for value in ["maria", "A Senha!", "30", "3"] + ([answer] if answer else []):
                        msg.text = value
                        state = asyncio.run(bot.ssh_input(update, context))
                    self.assertEqual(state, bot.SELECTING_ACTION)
                    self.assertEqual(context.user_data, {})
                    self.assertEqual(create.call_args_list[0].args, ("ssh", "maria", "A Senha!", "30", "3"))
                    self.assertEqual(msg.reply_text.await_args.args[0].endswith("UUID: exemplo"), answer == "sim")
