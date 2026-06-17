# Claude Code Cross-Platform Docker Sandbox

This repository provides a lightweight, ephemeral Docker sandbox for running Anthropic's Claude Code CLI tool completely isolated from your host operating system.

It is tailored to run natively on **Standard Debian Linux** environments and **ChromeOS Linux Developer Environments (Crostini)** using an identical, automated setup.

---

## How it Works

Claude Code requires terminal access to execute build commands, modify your codebase, and run scripts. To prevent accidental host modifications or dependency pollution, this architecture utilizes a **"Sidecar/Volume-Mounted" Docker Sandbox**:

* **Isolation:** Claude runs inside an isolated Debian container with access *only* to the single project directory you explicitly launch it from.
* **Ephemerality:** The sandbox instance is automatically destroyed (`--rm`) when it exits, ensuring every project workflow starts from a pristine state.
* **Cross-Platform Host Integration:** The user inside the container is explicitly pinned to UID 1000, matching the native default user settings of both standard Debian systems and Crostini to prevent file permission mismatches.

---

## Repository Structure

* Dockerfile.claude: Defines the Node.js/Debian base sandbox image
* install.sh: Automates Docker install, image builds, and alias injection
* launch-interactive.sh: Core script wrapping the standard Claude UX
* launch-scripted.sh: Core script wrapping autonomous execution mode
* README.md: This documentation file

---

## Installation and Setup

### 1. Configure Your Host API Key

Because Claude Code runs natively using an interactive browser OAuth session, it stores credentials locally. Because the Docker container cannot access your host's filesystem, **you must use a standard Anthropic API Key.**

1. Generate an API Key at the Anthropic Console.
2. Open your host profile configuration:
`nano ~/.bashrc`
3. Append your key to the bottom of the file:
`export ANTHROPIC_API_KEY="sk-ant-api03-your-actual-api-key"`
4. Save and exit (Ctrl+O, Enter, Ctrl+X), then reload your terminal configuration:
`source ~/.bashrc`

### 2. Deploy the Sandbox Repository

Clone your repository onto the machine and execute the installation manager script:

```bash
cd ~
git clone <your-repository-url> claude-sandbox-repo
cd claude-sandbox-repo

# Ensure scripts are executable
chmod +x install.sh launch-interactive.sh launch-scripted.sh

# Run the unified environment setup
./install.sh

```

### 3. Environment Reload (Critical Step)

* **On a Chromebook:** Right-click the **Terminal** app icon on your shelf/launcher, select **"Shut down Linux"**, then reopen the Terminal app to reload the system groups.
* **On Native Debian:** Open a fresh terminal window or run `source ~/.bashrc`.

---

## Daily Workflow Guide

Once installed, two global aliases are injected into your system shell (`~/.bashrc`). Navigate into **any project directory** on your machine and invoke the tool depending on your development needs:

### Use Case 1: Interactive Collaboration (`claude-box`)

Use this mode for standard interactive coding sessions, exploration, or debugging. Claude will ask you for confirmation (Y/n) before executing system-level actions.

```bash
cd ~/my-projects/web-app
claude-box

```

* **Result:** Drops your shell interface straight into the Claude Code terminal layout, safe-fenced to the target directory.

### Use Case 2: Autonomous Task Scripting (`claude-yolo`)

Use this mode when you want to hand Claude a complex instruction and walk away. It bypasses security prompts, giving Claude the freedom to rapidly cycle through testing, linting, and bug fixing autonomously until completion.

```bash
cd ~/my-projects/web-app
claude-yolo "Run our python test suite, locate any syntax or logic errors, and iterate on fixing them until everything passes cleanly."

```

* **Result:** The sandbox launches headlessly, forces execution via Claude's automated non-interactive processing mode (`-p`), automatically handles `--dangerously-skip-permissions`, and safely self-destructs the box when finished.

---

## Safe Development Practices

* **Commit Often:** While Claude cannot modify files *outside* your mounted directory, it has full rights to change everything *inside* it. Always ensure your git worktree is clean or safely committed before using `claude-yolo` to protect your source file versions.
* **API Token Consumption:** In autonomous (`claude-yolo`) mode, ensure your prompt limits or looping mechanisms are sound to avoid unnecessary cost spikes from unintentional recursive debugging loop issues.
