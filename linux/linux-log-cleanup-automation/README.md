# Automated Log Cleanup on Linux (AWS EC2 + WSL)

A hands-on Linux automation project, documented from zero: launch a server on AWS, connect to it from a Windows PC using WSL, build a log cleanup script that runs on a schedule with cron, and publish the result to GitHub.

## What this project does

An app server keeps filling up with old rotated log files, and nobody clears them by hand. This project automates that chore:

- A shell script deletes only the old rotated logs (`*.old`) and leaves the live log (`app.log`) untouched.
- The script prints exactly one summary line per run.
- A cron job runs the script every day at 02:00 and appends its output to a log file, so every run leaves a record.

## Skills practised

| Skill | Where it is used |
|---|---|
| AWS EC2 | Launching and terminating a Linux server |
| SSH and key pairs | Connecting securely to the server |
| WSL (Windows Subsystem for Linux) | Running a real Linux terminal on Windows |
| Shell scripting | The cleanup script |
| `find` with filters and `-delete` | Selecting and removing only `*.old` files |
| Cron | Scheduling the script |
| Redirection (`>`, `>>`, `2>&1`) | Logging output and errors |
| Permissions (`chmod`) | Making the script executable |
| Git and GitHub | Publishing the project |

## Repository structure

```
linux-log-cleanup-automation/
├── README.md              <- this file
├── scripts/
│   └── cleanup.sh         <- the cleanup script
├── crontab.txt            <- the cron entry
├── sample-cleanup.log     <- real output from a run
└── .gitignore             <- keeps secrets (like .pem keys) out of Git
```

---

## Overview of the workflow

```
Windows PC --(WSL Ubuntu)--SSH--> AWS EC2 (Ubuntu server)
                                      |
                       build script + cron job there
                                      |
              scp files back to WSL --> git push --> GitHub
```

1. Launch an EC2 server on AWS.
2. Install WSL (Ubuntu) on the Windows PC.
3. Copy the `.pem` key into WSL and fix its permissions.
4. SSH into the server.
5. Build and test the project on the server.
6. Copy the files back to the PC with `scp`.
7. Push them to GitHub.
8. Terminate the server to avoid charges.

---

## Part 1: Launch an EC2 instance on AWS

1. Sign in to the AWS Console and open **EC2**.
2. Choose your nearest region from the top-right region menu (for example, Asia Pacific (Mumbai)).
3. Click **Launch instance**.
4. Fill in the settings:

| Setting | Value |
|---|---|
| Name | `linux-cleanup-project` |
| AMI | Ubuntu Server 24.04 LTS (marked "Free tier eligible") |
| Instance type | `t2.micro` or `t3.micro` (whichever is marked free tier eligible) |
| Key pair | Click **Create new key pair** |

Why Ubuntu: cron comes preinstalled. Amazon Linux 2023 does not include it, which would add an extra install step.

5. Create the key pair:
   - Name: `devops-key`
   - Type: RSA
   - Format: `.pem`
   - The file downloads **once**. Keep it safe. Anyone who has this file can log in to your server.

6. Network settings:
   - Tick **Allow SSH traffic from**.
   - Choose **My IP** (safer than "Anywhere").

7. Leave storage at the default and click **Launch instance**.
8. Open the instance list and wait until **Instance state** shows `Running` and **Status check** shows `2/2 checks passed`.
9. Select the instance and copy the **Public IPv4 address**. This guide calls it `YOUR_PUBLIC_IP`.

> **Note:** "My IP" only allows the IP address you had when you launched. If your internet connection changes (new Wi-Fi, mobile hotspot, router restart), SSH will time out. Fix it under the instance's **Security** tab: edit the security group's inbound rule for SSH and choose **My IP** again.

---

## Part 2: Install WSL (Ubuntu) on Windows

WSL gives you a real Linux terminal inside Windows. SSH, `scp`, `chmod` and `git` all behave exactly as they do on a Linux machine.

1. Click the Start menu, type `cmd` or `PowerShell`, right-click it and choose **Run as administrator**.
2. Run:

```bash
wsl --install
```

This installs WSL and Ubuntu.

3. **Restart your PC** when it asks.
4. After the restart, Ubuntu opens automatically and finishes setting up. If it does not, open the Start menu and search for **Ubuntu**.
5. Create a Linux username and password when asked. These are only for your local WSL, not for AWS. When you type the password, nothing appears on screen. That is normal.
6. Confirm you are in Linux:

```bash
whoami
pwd
```

You should see your new username and a path such as `/home/yourname`.

From now on, run everything in this **Ubuntu (WSL) terminal**, not in CMD.

You can also reach it any time from CMD or PowerShell by typing:

```bash
wsl
```

---

## Part 3: Copy the `.pem` key into WSL

Your key downloaded to Windows (usually the `Downloads` folder). WSL can see Windows files under `/mnt/c/`.

1. Create a folder for SSH keys inside Linux:

```bash
mkdir -p ~/.ssh
```

2. Copy the key from Windows into that folder (replace `YOUR_WINDOWS_USERNAME`):

```bash
cp /mnt/c/Users/YOUR_WINDOWS_USERNAME/Downloads/devops-key.pem ~/.ssh/
```

Tip: to find your Windows username, run `ls /mnt/c/Users/`.

3. Restrict the key's permissions:

```bash
chmod 400 ~/.ssh/devops-key.pem
```

`400` means only you can read the file. SSH refuses keys that other users can read.

4. Check it:

```bash
ls -l ~/.ssh/devops-key.pem
```

Expected: `-r--------` at the start of the line.

**Why copy it into `~/.ssh` instead of using it from `/mnt/c/...`?** Permissions set with `chmod` do not work on Windows drives mounted in WSL, so SSH would reject the key as "too open". The Linux filesystem (`~/.ssh`) does honour them.

---

## Part 4: SSH into the server

```bash
ssh -i ~/.ssh/devops-key.pem ubuntu@YOUR_PUBLIC_IP
```

- `-i` tells SSH which key file to use.
- `ubuntu` is the default username on Ubuntu AMIs.
- Type `yes` when asked to trust the server's fingerprint (first connection only).

You are connected when the prompt changes to `ubuntu@ip-172-...:~$`.

Switch to the root user so the paths match the project exactly:

```bash
sudo -i
```

The prompt now ends with `#`, which means root.

---

## Part 5: Build the project on the server

All commands in this part run **on the EC2 server as root**.

### Step 0: Create the test files

This creates the "app server" situation: one live log and three old rotated logs.

```bash
mkdir -p /var/log/escbash-app
echo "service started" > /var/log/escbash-app/app.log
echo "old entries" > /var/log/escbash-app/app.log.1.old
echo "old entries" > /var/log/escbash-app/app.log.2.old
echo "old entries" > /var/log/escbash-app/app.log.3.old
ls -l /var/log/escbash-app/
```

What each part does:

- `mkdir -p` creates the folder (and does not complain if it already exists).
- `echo "text" > file` writes text into a file, creating it if needed.
- `ls -l` lists files with details.

Expected: four files: `app.log` and three `.old` files.

### Step 1: Write the script

```bash
mkdir -p /root/bin

cat > /root/bin/cleanup.sh << 'EOF'
#!/bin/bash
# cleanup.sh - delete rotated logs (*.old) and print one summary line per run

LOG_DIR="/var/log/escbash-app"

# Count the rotated logs first (live app.log never matches *.old)
count=$(find "$LOG_DIR" -maxdepth 1 -type f -name '*.old' | wc -l)

# Delete them
find "$LOG_DIR" -maxdepth 1 -type f -name '*.old' -delete

# Exactly one line of output per run
echo "$(date '+%Y-%m-%d %H:%M:%S') cleanup: removed $count old log file(s) from $LOG_DIR"
EOF

chmod +x /root/bin/cleanup.sh
ls -l /root/bin/cleanup.sh
```

How the script works:

| Part | Meaning |
|---|---|
| `#!/bin/bash` | Tells Linux to run the file with bash. Must be the first line. |
| `LOG_DIR="..."` | Stores the folder path in a variable. No spaces around `=`. |
| `find "$LOG_DIR"` | Searches that folder. |
| `-maxdepth 1` | Stays in that folder, ignores subfolders. |
| `-type f` | Matches regular files only. |
| `-name '*.old'` | Matches names ending in `.old`, so `app.log` is never touched. |
| `\| wc -l` | Counts the matches (one per line). |
| `$( ... )` | Runs a command and stores its output. |
| `-delete` | Removes the matched files. |
| `echo "..."` | Prints exactly one summary line, with a timestamp. |
| `<< 'EOF'` | A heredoc: writes everything up to `EOF` into the file. The quotes stop the shell from expanding `$` while writing. |
| `chmod +x` | Makes the script executable. Without it, cron cannot run it. |

Expected from `ls -l`: `-rwxr-xr-x` (the `x` characters mean executable).

**Check the file after writing it:**

```bash
cat /root/bin/cleanup.sh
```

Both `find` lines must contain `"$LOG_DIR"`, with the `$`. See the Troubleshooting section for what happens if the `$` is missing.

### Step 2: Schedule it with cron

```bash
(crontab -l 2>/dev/null; echo '0 2 * * * /root/bin/cleanup.sh >> /var/log/escbash-app/cleanup.log 2>&1') | crontab -
crontab -l
```

How it works:

- `crontab -l` prints existing jobs. `2>/dev/null` hides the "no crontab" error if there are none.
- The `echo` adds the new line.
- `| crontab -` installs the combined list, so existing jobs are never wiped.

A cron line has five time fields, then the command:

```
0   2   *   *   *   /root/bin/cleanup.sh >> /var/log/escbash-app/cleanup.log 2>&1
|   |   |   |   |
|   |   |   |   +-- day of week (* = every day)
|   |   |   +------ month (* = every month)
|   |   +---------- day of month (* = every day)
|   +-------------- hour (2 = 02:00)
+------------------ minute (0)
```

- `>>` appends to the log file (`>` would overwrite it).
- `2>&1` sends error messages to the same file, so failures are recorded too.
- The server clock is **UTC**, so 02:00 means 02:00 UTC. India time (IST) is UTC+5:30, so this is 07:30 IST.
- Absolute paths are used everywhere because cron runs with a minimal environment and a different working directory.

### Step 3: Make sure the log file exists

```bash
touch /var/log/escbash-app/cleanup.log
```

`touch` creates an empty file if it does not exist and is harmless if it does.

### Step 4: Run the script once manually

```bash
/root/bin/cleanup.sh >> /var/log/escbash-app/cleanup.log 2>&1
```

This runs the script exactly as cron would. The old logs are deleted immediately, and the first entry is written to `cleanup.log`. Nothing prints on screen because the output went into the file.

### Step 5: Verify

```bash
ls -l /var/log/escbash-app/
cat /var/log/escbash-app/cleanup.log
crontab -l
systemctl status cron --no-pager
```

Expected results:

- Only `app.log` and `cleanup.log` remain (the three `.old` files are gone).
- `cleanup.log` shows one line like:
  `2026-11-13 08:39:35 cleanup: removed 3 old log file(s) from /var/log/escbash-app`
- `crontab -l` shows the scheduled line.
- The cron service shows `active (running)`.

### Optional: prove cron really runs it

Waiting until 02:00 is slow. To test now, schedule it every minute temporarily:

```bash
echo "x" > /var/log/escbash-app/test.old
(crontab -l; echo '* * * * * /root/bin/cleanup.sh >> /var/log/escbash-app/cleanup.log 2>&1') | crontab -
```

Wait one to two minutes, then run:

```bash
cat /var/log/escbash-app/cleanup.log
```

A new line saying `removed 1` proves cron ran the script by itself.

**Then remove the every-minute entry**, otherwise it keeps running:

```bash
crontab -e
```

Delete the `* * * * *` line, save, and exit. In the default `nano` editor that is `Ctrl+O`, `Enter`, `Ctrl+X`. Confirm with `crontab -l`.

---

## Part 6: Package the project files

Still on the server as root. The folder goes in `/home/ubuntu` so the `ubuntu` user can copy it with `scp` (files in `/root` cannot be read by `ubuntu`).

```bash
mkdir -p /home/ubuntu/log-cleanup-project/scripts
cp /root/bin/cleanup.sh /home/ubuntu/log-cleanup-project/scripts/cleanup.sh
crontab -l > /home/ubuntu/log-cleanup-project/crontab.txt
cp /var/log/escbash-app/cleanup.log /home/ubuntu/log-cleanup-project/sample-cleanup.log

cat > /home/ubuntu/log-cleanup-project/.gitignore << 'EOF'
*.pem
*.key
.env
EOF

chown -R ubuntu:ubuntu /home/ubuntu/log-cleanup-project
ls -la /home/ubuntu/log-cleanup-project
```

If you run the every-minute test, make sure `crontab.txt` contains only the `0 2 * * *` line before you continue.

Leave the server:

```bash
exit
exit
```

The first `exit` leaves root, the second closes the SSH session. You are back in your WSL terminal.

---

## Part 7: Copy the files to your PC (WSL)

Run this in WSL (replace `YOUR_PUBLIC_IP`):

```bash
cd ~
scp -i ~/.ssh/devops-key.pem -r ubuntu@YOUR_PUBLIC_IP:/home/ubuntu/log-cleanup-project .
```

`scp` copies files over SSH, and `-r` copies a folder with everything inside it.

Check it:

```bash
ls -la ~/log-cleanup-project
```

Add this README to the folder (from where you saved it in Windows):

```bash
cp /mnt/c/Users/YOUR_WINDOWS_USERNAME/Downloads/README.md ~/log-cleanup-project/README.md
```

---

## Part 8: Push to GitHub

### One-time Git setup (WSL)

```bash
git config --global user.name "Your Name"
git config --global user.email "you@example.com"
```

### Create the repository

1. On github.com click **New repository**.
2. Name it `linux-log-cleanup-automation`.
3. Leave it empty: no README, no .gitignore, no licence.
4. Click **Create repository**.

### Push the project

```bash
cd ~/log-cleanup-project
git init
git add .
git status
```

Read `git status` before committing. You should see only `README.md`, `crontab.txt`, `sample-cleanup.log`, `scripts/cleanup.sh` and `.gitignore`. **If a `.pem` file ever appears, stop and do not commit it.**

```bash
git commit -m "Add automated log cleanup project"
git branch -M main
git remote add origin https://github.com/YOUR_USERNAME/linux-log-cleanup-automation.git
git push -u origin main
```

GitHub no longer accepts your account password for pushes. When asked for a password, paste a **Personal Access Token**:

GitHub -> Settings -> Developer settings -> Personal access tokens -> Generate new token (give it the `repo` scope).

Refresh the repository page to confirm the files are there.

---

## Part 9: Terminate the server

Once the files are visible on GitHub:

EC2 -> select the instance -> **Instance state** -> **Terminate instance**.

Stopping an instance is not the same as terminating it. A stopped instance still has storage that can be billed. Terminate it unless you want to keep practising.

You can also delete the key pair under EC2 -> Key Pairs if you will not reuse it.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `find: 'LOG_DIR': No such file or directory` and `removed 0 old log file(s)` | The `$` is missing in `find "LOG_DIR"`, so bash searches a folder literally named `LOG_DIR` | The line must read `find "$LOG_DIR" ...`. Rewrite the script with the heredoc and run `cat` to check. Debug with `bash -x /root/bin/cleanup.sh`. |
| `WARNING: UNPROTECTED PRIVATE KEY FILE!` | The key is readable by others | `chmod 400 ~/.ssh/devops-key.pem`, and keep the key in `~/.ssh`, not under `/mnt/c/`. |
| `Connection timed out` on SSH | Your IP changed, or SSH is not allowed in the security group | Edit the security group's SSH inbound rule and choose **My IP** again. Also check the instance is `Running`. |
| `Permission denied (publickey)` | Wrong username or wrong key | Use `ubuntu@...` for Ubuntu AMIs and the key you created when launching. |
| `scp: ... Permission denied` | Copying files that live in `/root` | Copy them to `/home/ubuntu` first (Part 6) and `chown` them to `ubuntu`. |
| `crontab: command not found` | Cron is not installed | `apt update && apt install -y cron` |
| Script works by hand but not from cron | Relative paths or a missing `chmod +x` | Use absolute paths everywhere and confirm `ls -l` shows `x`. |
| Cron runs at the "wrong" time | The server uses UTC | Convert times: IST = UTC + 5:30. |
| `git push` asks for a password and rejects it | Account passwords are no longer accepted | Use a Personal Access Token. |

## Debugging tips

- After writing any script, run `cat` on it and read it once.
- Run `bash -x script.sh` to print every command with its variables expanded.
- Check cron's own record with `grep CRON /var/log/syslog`.
- Test scripts by running them exactly the way cron will: with the full path and the same redirection.

## Key takeaways

- Automation needs three things: a script, a schedule, and a log of what happened.
- Cron runs with a minimal environment, so absolute paths and permissions matter.
- Forgetting `$` before a variable is a silent bug: the script runs but does the wrong thing.
- Never commit secrets such as `.pem` files. Use `.gitignore` and always read `git status` before committing.
- Always terminate cloud resources you no longer need.

## Tested on

- Ubuntu 24.04 LTS (AWS EC2)
- Windows with WSL 2 (Ubuntu)
