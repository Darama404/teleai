# Soy Oncall System Deployment Guide

This repository contains the **Soy Oncall** system, a two-part architecture designed to manage sysadmin alerts and auto-reply on Telegram using Groq LLM/Vision and Telethon.

## Architecture Overview

The system consists of two separate components:
1. **Telethon Service** (`telethon/telethon.py`): A Flask HTTP API wrapped around a Telethon user-client to send "human-like" replies using your own Telegram user account. This runs as a `systemd` background service.
2. **Oncall Polling Bot** (`oncall/co2pushover.sh`): A bash script that polls the Telegram Bot API for mentions. It integrates with Groq for text/image scope detection, uses Pushover for escalations outside of working hours, and commands the Telethon Service to send replies. 

## Prerequisites for Fresh Server

Update your server and install the necessary dependencies:

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y python3 python3-venv python3-pip jq curl bc
```

## Deployment Steps

### 1. Clone the Repository
By default, the provided `systemd` service assumes the project is located at `/home/ubuntu/soy-oncall`.

```bash
cd /origin/path
git clone <your-repo-url> /home/ubuntu/soy-oncall
cd /home/ubuntu/soy-oncall
```
*(If your user is not `ubuntu` or you deploy it elsewhere, make sure to edit `soy.service` to match your paths, user, and group.)*

### 2. Setup Python Virtual Environment (Telethon Service)

```bash
cd /home/ubuntu/soy-oncall/telethon
python3 -m venv ../venv
source ../venv/bin/activate
pip install -r requirements.txt
```

### 3. Configuration (`.env`)

You need to set up the environment variables for both components before creating a session or starting the service.

**For Telethon API Service:**
```bash
cd /home/ubuntu/soy-oncall/telethon
cp .env.example .env
nano .env # Edit the required fields (API_ID, API_HASH, SESSIONS, API_TOKEN)
```

**For Oncall Bash Script:**
```bash
cd /home/ubuntu/soy-oncall/oncall
cp .env.example .env
nano .env # Edit all the fields (BOT_TOKEN, BOT_USERNAME, TEAM_USERNAMES, etc.)
```

### 4. Generate Telethon Sessions
The `telethon.py` service looks for pre-existing session files in the `sessions/` folder (e.g. `sessions/soy.session`). 
To interactively log into Telegram and generate a new session file directly on your server, use the provided `add_session.py` script:

```bash
cd /home/ubuntu/soy-oncall/telethon
# Make sure to activate the virtual environment first if you haven't
source ../venv/bin/activate

# Add the new session (requires the API_ID and API_HASH set in .env)
python3 add_session.py
```
*Follow the on-screen prompts to log in (it will ask for your phone number and the OTP code sent to your Telegram app).*

### 5. Setup & Start Telethon Systemd Service

Copy the systemd service file, reload the daemon, and start the service:

```bash
sudo cp /home/ubuntu/soy-oncall/soy.service /etc/systemd/system/soy-oncall.service
sudo systemctl daemon-reload
sudo systemctl enable soy-oncall
sudo systemctl start soy-oncall
```

Check the logs to make sure the Flask server and Telethon sessions started correctly:
```bash
sudo journalctl -u soy-oncall -f
```

### 6. Start the Oncall Bot (co2pushover.sh)

The shell script runs an infinite loop querying the Telegram Bot API. You can run it inside a `tmux`/`screen` session, or create another `systemd` service for it.

**Using tmux:**
```bash
tmux new -s oncall-bot
cd /home/ubuntu/soy-oncall/oncall
chmod +x co2pushover.sh
./co2pushover.sh
# Press Ctrl+B, then D to detach.
```

## Upgrading/Updating

To pull new changes and restart the system:
```bash
cd /home/ubuntu/soy-oncall
git pull
sudo systemctl restart soy-oncall
```
For the shell script, simply stop the old loop and run the new script version.
