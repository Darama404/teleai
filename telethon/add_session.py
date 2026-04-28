#!/usr/bin/env python3
"""
Add new Telethon session interactively.
Jalankan sekali untuk setiap user baru:
  python3 add_session.py
"""

from telethon.sync import TelegramClient
from dotenv import load_dotenv
import os
import sys

load_dotenv()

api_id_str = os.getenv('API_ID')
api_hash = os.getenv('API_HASH')

if not api_id_str or not api_hash:
    print("ERROR: API_ID atau API_HASH belum diset! Pastikan .env sudah dibuat dari .env.example")
    sys.exit(1)

API_ID = int(api_id_str)
API_HASH = api_hash
SESSIONS_DIR = 'sessions'

os.makedirs(SESSIONS_DIR, exist_ok=True)

print("=== Tambah Session Baru ===")
username = input("Masukkan username (tanpa @), contoh: soy -> ").strip().lower()

if not username:
    print("ERROR: Username tidak boleh kosong!")
    sys.exit(1)

session_path = os.path.join(SESSIONS_DIR, username)

if os.path.exists(f"{session_path}.session"):
    confirm = input(f"Session '{username}' sudah ada! Overwrite? (y/n): ").strip().lower()
    if confirm != 'y':
        print("Dibatalkan.")
        sys.exit(0)

print(f"\nLogin untuk akun @{username}...")
print("Masukkan nomor HP dengan format internasional, contoh: +628123456789\n")

client = TelegramClient(session_path, API_ID, API_HASH)

try:
    client.start()
    me = client.get_me()
    print(f"\n✅ Berhasil login sebagai: {me.first_name} (@{me.username})")
    print(f"   Session tersimpan di: {session_path}.session")
    print(f"\n📝 Jangan lupa tambahkan '{username}' ke SESSIONS di .env!")
    print(f"   Contoh: SESSIONS=soy,{username}")
except Exception as e:
    print(f"\n❌ Gagal login: {e}")
finally:
    client.disconnect()