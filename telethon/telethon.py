#!/usr/bin/env python3
"""
Soy Oncall Server - Multi Session version
"""

from flask import Flask, request, jsonify
from telethon import TelegramClient
from telethon.tl.functions.messages import SetTypingRequest
from telethon.tl.types import SendMessageTypingAction, SendMessageCancelAction
import asyncio
import threading
import os
from dotenv import load_dotenv
import logging

load_dotenv()
app = Flask(__name__)

logging.basicConfig(level=logging.INFO)
log = logging.getLogger(__name__)

# ── Config ────────────────────────────────────────────────
API_ID        = int(os.getenv('API_ID'))
API_HASH      = os.getenv('API_HASH')
SESSION_NAMES = [s.strip() for s in os.getenv('SESSIONS', 'soy').split(',')]
SESSIONS_DIR  = 'sessions'
API_TOKEN     = os.getenv('API_TOKEN', '')

# ── Event loop di thread terpisah ─────────────────────────
loop = asyncio.new_event_loop()

def start_loop(loop):
    asyncio.set_event_loop(loop)
    loop.run_forever()

threading.Thread(target=start_loop, args=(loop,), daemon=True).start()

# ── Load semua session ────────────────────────────────────
clients = {}

async def start_all_clients():
    for name in SESSION_NAMES:
        session_path = os.path.join(SESSIONS_DIR, name)

        if not os.path.exists(f"{session_path}.session"):
            log.warning(f"⚠️  Session file tidak ditemukan: {session_path}.session — skip!")
            continue

        try:
            c = TelegramClient(session_path, API_ID, API_HASH)
            await c.start()
            me = await c.get_me()
            clients[name] = c
            log.info(f"✅ Client '{name}' started! (@{me.username})")
        except Exception as e:
            log.error(f"❌ Gagal start client '{name}': {e}")

future = asyncio.run_coroutine_threadsafe(start_all_clients(), loop)
future.result(timeout=60)

if not clients:
    log.error("❌ Tidak ada client yang berhasil start! Cek session files dan .env")


# ── Auth Helper ───────────────────────────────────────────
def check_token():
    """Validasi API token dari header X-API-Token"""
    if not API_TOKEN:
        return True  # Jika API_TOKEN tidak di-set, skip auth
    token = request.headers.get('X-API-Token', '')
    return token == API_TOKEN

def get_client(session_name):
    """Ambil client berdasarkan session name, fallback ke session pertama"""
    client = clients.get(session_name)
    if not client:
        if clients:
            fallback = list(clients.keys())[0]
            log.warning(f"⚠️  Session '{session_name}' tidak ditemukan, fallback ke '{fallback}'")
            return clients[fallback], fallback
        return None, None
    return client, session_name


# ── Typing Indicator Helper ───────────────────────────────
async def _send_with_typing(client, chat_id, message, reply_to=None):
    """
    Simulate typing indicator sebelum kirim pesan.
    Durasi typing ~50ms per karakter, min 1s, max 4s.
    """
    try:
        await client(SetTypingRequest(
            peer=chat_id,
            action=SendMessageTypingAction()
        ))

        typing_duration = min(max(len(message) * 0.08, 2.0), 8.0)
        log.info(f"   ⌨️  Typing indicator aktif ({typing_duration:.1f}s)...")
        await asyncio.sleep(typing_duration)

        await client.send_message(chat_id, message, reply_to=reply_to)

    finally:
        await client(SetTypingRequest(
            peer=chat_id,
            action=SendMessageCancelAction()
        ))


# ── Routes ────────────────────────────────────────────────

@app.route('/health', methods=['GET'])
def health():
    return jsonify({
        'status'  : 'running',
        'sessions': list(clients.keys()),
        'total'   : len(clients)
    })


@app.route('/send', methods=['POST'])
def send():
    """Kirim pesan baru tanpa reply"""
    if not check_token():
        return jsonify({'status': 'error', 'message': 'Unauthorized'}), 401

    data    = request.json
    chat_id = data.get('chat_id')
    message = data.get('message', '')
    session = data.get('session', SESSION_NAMES[0])

    if not chat_id:
        return jsonify({'status': 'error', 'message': 'chat_id wajib diisi'}), 400
    if not message:
        return jsonify({'status': 'error', 'message': 'message wajib diisi'}), 400

    client, session = get_client(session)
    if not client:
        return jsonify({'status': 'error', 'message': 'Tidak ada session yang aktif'}), 503

    try:
        future = asyncio.run_coroutine_threadsafe(
            _send_with_typing(client, chat_id, message),
            loop
        )
        future.result(timeout=30)
        log.info(f"✅ [{session}] Sent to {chat_id}")
        return jsonify({'status': 'ok', 'session': session})

    except Exception as e:
        log.error(f"❌ Gagal kirim pesan: {e}")
        return jsonify({'status': 'error', 'message': str(e)}), 500


@app.route('/reply', methods=['POST'])
def reply():
    """Kirim pesan sebagai reply ke message tertentu"""
    if not check_token():
        return jsonify({'status': 'error', 'message': 'Unauthorized'}), 401

    data     = request.json
    chat_id  = data.get('chat_id')
    message  = data.get('message', 'Ok akan kami cek!')
    reply_to = data.get('reply_to_message_id')
    session  = data.get('session', SESSION_NAMES[0])

    if not chat_id:
        return jsonify({'status': 'error', 'message': 'chat_id wajib diisi'}), 400

    client, session = get_client(session)
    if not client:
        return jsonify({'status': 'error', 'message': 'Tidak ada session yang aktif'}), 503

    try:
        future = asyncio.run_coroutine_threadsafe(
            _send_with_typing(client, chat_id, message, reply_to=reply_to),
            loop
        )
        future.result(timeout=30)
        log.info(f"✅ [{session}] Replied to {chat_id}, message_id={reply_to}")
        return jsonify({'status': 'ok', 'session': session})

    except Exception as e:
        log.error(f"❌ Gagal kirim pesan: {e}")
        return jsonify({'status': 'error', 'message': str(e)}), 500


@app.route('/sessions', methods=['GET'])
def list_sessions():
    """Lihat semua session yang aktif"""
    return jsonify({
        'sessions': list(clients.keys()),
        'total'   : len(clients)
    })


if __name__ == '__main__':
    app.run(host='127.0.0.1', port=8000, threaded=True)