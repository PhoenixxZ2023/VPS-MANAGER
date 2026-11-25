"""Bot administrativo do VPS-MANAGER, adaptado do XRAY2026."""

from __future__ import annotations

import base64
import hashlib
import io
import json
import logging
import os
import re
import subprocess
from datetime import datetime

from xray_accounts import _is_valid_nick

from telegram import InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.ext import (
    Application,
    CallbackQueryHandler,
    CommandHandler,
    ContextTypes,
    ConversationHandler,
    MessageHandler,
    filters,
)

# --- CONFIGURAÇÃO VIA VARIÁVEIS DE AMBIENTE ---
_token = os.environ.get("BOT_TOKEN", "").strip()
_admin = os.environ.get("ADMIN_ID", "").strip()
if not _token or not _admin:
    raise EnvironmentError(
        "BOT_TOKEN e ADMIN_ID devem estar definidos.\n"
        "Verifique /opt/XrayTools/.bot_env e EnvironmentFile= no botxray.service."
    )
BOT_TOKEN = _token
try:
    ADMIN_ID = int(_admin)
except ValueError:
    raise EnvironmentError(f"ADMIN_ID deve ser inteiro, obtido: '{_admin}'")

(
    SELECTING_ACTION,
    GET_USERNAME_CREATE,
    GET_EXPIRY_DAYS_CREATE,
    GET_USER_TO_DELETE,
    GET_USER_TO_BLOCK,
    GET_USER_TO_UNBLOCK,
    GET_USER_TO_RENEW,
    GET_DAYS_TO_RENEW,
) = range(8)


# =============================================================
# FUNÇÕES DE SISTEMA
# =============================================================

SSH_NAME, SSH_PASS, SSH_DAYS, SSH_LIMIT, SSH_XRAY = range(8, 13)

logger = logging.getLogger(__name__)
logging.getLogger("httpx").setLevel(logging.WARNING)

def provision(action, *args):
    proc = subprocess.run(
        ["sudo", "-n", "/etc/vps-manager/core/xray/provision"],
        input=json.dumps([action, *args]), text=True, capture_output=True,
    )
    return proc.stdout.strip() or "Falha ao executar o cadastro. Consulte o serviço do bot."


async def ssh_input(update, context):
    if not is_admin(update):
        return
    data = context.user_data
    value = update.message.text
    if "user" not in data:
        if not _is_valid_nick(value, strict_create=True):
            await update.message.reply_text("Nome inválido. Use 2–32 caracteres, começando com uma letra.")
            return SSH_NAME
        data["user"] = value
        await update.message.reply_text("Senha SSH:")
        return SSH_PASS
    if "pass" not in data and "summary" not in data:
        if not value or not value.isprintable() or ":" in value:
            await update.message.reply_text("Informe uma senha sem dois-pontos ou quebras de linha.")
            return SSH_PASS
        data["pass"] = value
        await update.message.reply_text("Validade em dias (1–3650):")
        return SSH_DAYS
    if "days" not in data:
        if not re.fullmatch(r"[1-9][0-9]{0,3}", value) or int(value) > 3650:
            await update.message.reply_text("Informe de 1 a 3650 dias.")
            return SSH_DAYS
        data["days"] = value
        await update.message.reply_text("Limite de conexões SSH:")
        return SSH_LIMIT
    if "summary" not in data:
        if not re.fullmatch(r"[1-9][0-9]{0,4}", value) or int(value) > 65535:
            await update.message.reply_text("Informe um limite entre 1 e 65535.")
            return SSH_LIMIT
        result = provision("ssh", data["user"], data.pop("pass"), data["days"], value)
        if result.startswith("Conta SSH criada") and provision("active") == "sim":
            data["summary"] = result
            await update.message.reply_text("Conta SSH criada. Deseja criar também o acesso Xray? (sim/não)")
            return SSH_XRAY
    else:
        choice = value.strip().lower()
        if choice not in ("s", "sim", "n", "não", "nao"):
            await update.message.reply_text("Responda sim ou não.")
            return SSH_XRAY
        result = data["summary"]
        if choice in ("s", "sim"):
            result += "\n" + provision("xray", data["user"], data["days"])
    data.clear()
    await update.message.reply_text(result, reply_markup=build_menu())
    return SELECTING_ACTION


def is_admin(update: Update) -> bool:
    return update.effective_user is not None and update.effective_user.id == ADMIN_ID and update.effective_chat.type == "private"


def build_menu() -> InlineKeyboardMarkup:
    keyboard = [
        [InlineKeyboardButton("Criar SSH / conexões da VPS", callback_data="ssh_start")],
        [
            InlineKeyboardButton("Criar somente Xray",        callback_data="create_start"),
            InlineKeyboardButton("🗑️ REMOVER",      callback_data="delete_start"),
        ],
        [
            InlineKeyboardButton("⛔ SUSPENDER",    callback_data="block_start"),
            InlineKeyboardButton("✅ REATIVAR",     callback_data="unblock_start"),
        ],
        [
            InlineKeyboardButton("🔄 RENOVAR",      callback_data="renew_start"),
            InlineKeyboardButton("📋 LISTAR (TXT)", callback_data="list_users"),
        ],
        [
            InlineKeyboardButton("📊 VER CONSUMO",  callback_data="usage_list"),
            InlineKeyboardButton("📥 BACKUP",       callback_data="backup_start"),
        ],
        [
            InlineKeyboardButton("❌ SAIR",         callback_data="cancel"),
        ],
    ]
    return InlineKeyboardMarkup(keyboard)


async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update):
        return
    context.user_data.clear()
    await update.message.reply_text(
        "*VPS-MANAGER* • SSH e Xray",
        reply_markup=build_menu(),
        parse_mode="Markdown",
    )
    return SELECTING_ACTION


async def button_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update):
        return

    query = update.callback_query
    await query.answer()

    if query.data == "close_file":
        await query.message.delete()
        return SELECTING_ACTION

    if query.data == "cancel":
        await query.edit_message_text("Painel Fechado.", reply_markup=None)
        return ConversationHandler.END

    if query.data == "ssh_start":
        context.user_data.clear()
        await query.edit_message_text("Nome do usuário SSH:")
        return SSH_NAME

    if query.data == "create_start":
        await query.edit_message_text(
            "Nome do usuário (2–32 caracteres):", parse_mode="Markdown"
        )
        return GET_USERNAME_CREATE

    if query.data == "delete_start":
        await query.edit_message_text("Nome para remover:", parse_mode="Markdown")
        return GET_USER_TO_DELETE

    if query.data == "block_start":
        await query.edit_message_text(
            "Nome para ⛔ SUSPENDER:", parse_mode="Markdown"
        )
        return GET_USER_TO_BLOCK

    if query.data == "unblock_start":
        await query.edit_message_text(
            "Nome para ✅ REATIVAR:", parse_mode="Markdown"
        )
        return GET_USER_TO_UNBLOCK

    if query.data == "renew_start":
        await query.edit_message_text(
            "Nome para 🔄 RENOVAR:", parse_mode="Markdown"
        )
        return GET_USER_TO_RENEW

    if query.data == "list_users":
        report = provision("list")
        f = io.BytesIO(report.encode("utf-8"))
        f.name = "usuarios.txt"
        close_btn = InlineKeyboardMarkup(
            [[InlineKeyboardButton("🗑 Fechar Lista", callback_data="close_file")]]
        )
        await context.bot.send_document(
            chat_id=update.effective_chat.id,
            document=f,
            caption="📂 *Lista gerada*",
            parse_mode="Markdown",
            reply_markup=close_btn,
        )
        await query.edit_message_text(
            "✅ *Lista enviada abaixo!*\nEscolha outra opção:",
            parse_mode="Markdown",
            reply_markup=build_menu(),
        )
        return SELECTING_ACTION

    if query.data == "usage_list":
        report = provision("usage")
        f = io.BytesIO(report.encode("utf-8"))
        f.name = "consumo.txt"
        close_btn = InlineKeyboardMarkup(
            [[InlineKeyboardButton("🗑 Fechar Relatório", callback_data="close_file")]]
        )
        await context.bot.send_document(
            chat_id=update.effective_chat.id,
            document=f,
            caption="📊 *Relatório de Consumo de Dados gerado*",
            parse_mode="Markdown",
            reply_markup=close_btn,
        )
        await query.edit_message_text(
            "✅ *Relatório de consumo enviado!*",
            parse_mode="Markdown",
            reply_markup=build_menu(),
        )
        return SELECTING_ACTION

    if query.data == "backup_start":
        await query.edit_message_text("📦 Gerando Backup...", parse_mode="Markdown")

        date_str = datetime.now().strftime("%Y%m%d_%H%M")
        try:
            archive = base64.b64decode(provision("backup"), validate=True)
        except ValueError:
            await query.edit_message_text("Falha ao gerar o backup Xray.", reply_markup=build_menu())
            return SELECTING_ACTION
        await context.bot.send_document(
            chat_id=update.effective_chat.id,
            document=io.BytesIO(archive),
            filename=f"xray-{date_str}.tar.gz",
            caption="Backup das contas e da configuração Xray. SHA256 " + hashlib.sha256(archive).hexdigest(),
        )
        await query.edit_message_text("Backup enviado.", reply_markup=build_menu())
        return SELECTING_ACTION

    await query.edit_message_text("Reiniciando...", reply_markup=build_menu())
    return SELECTING_ACTION


async def unexpected_button(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    return await button_handler(update, context)


async def input_handler(
    update: Update, context: ContextTypes.DEFAULT_TYPE, mode: str
):
    if not is_admin(update):
        return SELECTING_ACTION
    if not update.message or not update.message.text:
        return SELECTING_ACTION

    text = update.message.text.strip().lower()

    if mode == "create_nick":
        if not _is_valid_nick(text, strict_create=True):
            await update.message.reply_text(
                "❌ *Nome Inválido!*\n\nRegras:\n• Entre 2 e 32 caracteres\n"
                "• Comece com uma letra minúscula. Use letras, números, hífen ou sublinhado\n\nTente outro:",
                parse_mode="Markdown",
            )
            return GET_USERNAME_CREATE
        context.user_data["nick"] = text
        await update.message.reply_text(
            f"Validade (dias) para `{text}`:", parse_mode="Markdown"
        )
        return GET_EXPIRY_DAYS_CREATE

    if mode == "create_days":
        if not text.isdigit() or not (1 <= int(text) <= 3650):
            await update.message.reply_text("❌ Informe um número de dias entre 1 e 3650.")
            return GET_EXPIRY_DAYS_CREATE
        msg = provision("xray", context.user_data["nick"], text)
        await update.message.reply_text(msg, reply_markup=build_menu())
        return SELECTING_ACTION

    if mode == "delete":
        if not _is_valid_nick(text):
            await update.message.reply_text("❌ Nome de usuário inválido.", reply_markup=build_menu())
            return SELECTING_ACTION
        msg = provision("delete", text)
        await update.message.reply_text(msg, reply_markup=build_menu())
        return SELECTING_ACTION

    if mode == "block":
        if not _is_valid_nick(text):
            await update.message.reply_text("❌ Nome de usuário inválido.", reply_markup=build_menu())
            return SELECTING_ACTION
        msg = provision("block", text)
        await update.message.reply_text(msg, reply_markup=build_menu())
        return SELECTING_ACTION

    if mode == "unblock":
        if not _is_valid_nick(text):
            await update.message.reply_text("❌ Nome de usuário inválido.", reply_markup=build_menu())
            return SELECTING_ACTION
        msg = provision("unblock", text)
        await update.message.reply_text(msg, reply_markup=build_menu())
        return SELECTING_ACTION

    if mode == "renew_nick":
        if not _is_valid_nick(text):
            await update.message.reply_text("❌ Nome de usuário inválido.", reply_markup=build_menu())
            return SELECTING_ACTION
        context.user_data["renew_nick"] = text
        await update.message.reply_text(
            f"Quantos dias deseja adicionar para `{text}`?", parse_mode="Markdown"
        )
        return GET_DAYS_TO_RENEW

    if mode == "renew_days":
        if not text.isdigit() or not (1 <= int(text) <= 3650):
            await update.message.reply_text("❌ Informe um número de dias entre 1 e 3650.")
            return GET_DAYS_TO_RENEW
        msg = provision("renew", context.user_data["renew_nick"], text)
        await update.message.reply_text(msg, reply_markup=build_menu())
        return SELECTING_ACTION

    logger.warning("input_handler: modo desconhecido '%s'", mode)
    await update.message.reply_text("❌ Operação inválida.", reply_markup=build_menu())
    return SELECTING_ACTION


# Wrappers assíncronos
async def h_create_nick(u, c): return await input_handler(u, c, "create_nick")
async def h_create_days(u, c): return await input_handler(u, c, "create_days")
async def h_delete(u, c):      return await input_handler(u, c, "delete")
async def h_block(u, c):       return await input_handler(u, c, "block")
async def h_unblock(u, c):     return await input_handler(u, c, "unblock")
async def h_renew_nick(u, c):  return await input_handler(u, c, "renew_nick")
async def h_renew_days(u, c):  return await input_handler(u, c, "renew_days")


async def cancel_op(u, c):
    c.user_data.clear()
    await u.message.reply_text("Cancelado.", reply_markup=build_menu())
    return SELECTING_ACTION


# =============================================================
# MAIN
# =============================================================

def main():
    app = Application.builder().token(BOT_TOKEN).build()

    conv = ConversationHandler(
        entry_points=[
            CommandHandler("start", start),
            CommandHandler("menu",  start),
        ],
        states={
            **{state: [MessageHandler(filters.TEXT & ~filters.COMMAND, ssh_input)]
               for state in (SSH_NAME, SSH_PASS, SSH_DAYS, SSH_LIMIT, SSH_XRAY)},
            SELECTING_ACTION: [CallbackQueryHandler(button_handler)],
            GET_USERNAME_CREATE: [
                MessageHandler(filters.TEXT & ~filters.COMMAND, h_create_nick),
                CallbackQueryHandler(unexpected_button),
            ],
            GET_EXPIRY_DAYS_CREATE: [
                MessageHandler(filters.TEXT & ~filters.COMMAND, h_create_days),
                CallbackQueryHandler(unexpected_button),
            ],
            GET_USER_TO_DELETE: [
                MessageHandler(filters.TEXT & ~filters.COMMAND, h_delete),
                CallbackQueryHandler(unexpected_button),
            ],
            GET_USER_TO_BLOCK: [
                MessageHandler(filters.TEXT & ~filters.COMMAND, h_block),
                CallbackQueryHandler(unexpected_button),
            ],
            GET_USER_TO_UNBLOCK: [
                MessageHandler(filters.TEXT & ~filters.COMMAND, h_unblock),
                CallbackQueryHandler(unexpected_button),
            ],
            GET_USER_TO_RENEW: [
                MessageHandler(filters.TEXT & ~filters.COMMAND, h_renew_nick),
                CallbackQueryHandler(unexpected_button),
            ],
            GET_DAYS_TO_RENEW: [
                MessageHandler(filters.TEXT & ~filters.COMMAND, h_renew_days),
                CallbackQueryHandler(unexpected_button),
            ],
        },
        fallbacks=[CommandHandler("cancel", cancel_op)],
        allow_reentry=True,
    )
    app.add_handler(conv)
    logger.info("TURBONET XRAY Bot V1.4.3 iniciado. Admin ID: %d", ADMIN_ID)
    app.run_polling()


if __name__ == "__main__":
    main()
