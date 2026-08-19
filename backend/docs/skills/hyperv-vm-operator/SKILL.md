---
name: hyperv-vm-operator
description: Diagnose, access, repair, or configure local Hyper-V Windows and Linux guests, including SSH, PowerShell Direct, guest networking, and durable service routing.
---

# Hyper-V VM Operator

Use this skill for a local Hyper-V VM incident or configuration. The required result is a proven client path into the named guest, not a host-side health check.

## Non-negotiable evidence

Before changing anything, establish all of the following:

1. Resolve the exact VM from its `.vmcx` configuration or a working `Get-VM`; never assign an IP from a subnet scan by guesswork.
2. Map the guest NIC MAC to a live `Get-NetNeighbor` entry, then test the intended management port.
3. Treat SSH as available only after `Test-NetConnection <guest-ip> -Port 22` and an authenticated `ssh` command both succeed.
4. Treat PowerShell Direct as available only after a command runs inside the guest and returns its hostname.
5. For proxy incidents, prove from inside the guest: configured `ANTHROPIC_BASE_URL`, `GET /health`, and one fresh Claude request. Host `/health` alone proves nothing about the guest.

Run `scripts/probe-hyperv-vm.ps1 -VmName <name>` first. It is read-only and reports the exact missing layer.

## Repair order

1. Repair the host control plane before touching the guest. If `Import-Module Hyper-V` fails, report the missing assembly and repair the Windows feature from its official component store. Do not claim PowerShell Direct works because a module manifest exists.
2. Prefer PowerShell Direct to bootstrap a Windows guest with OpenSSH. Install `sshd`, make it `Automatic`, add a narrowly scoped TCP/22 firewall rule, provision an explicit host public key, and verify an authenticated SSH command.
3. Configure the guest's actual client endpoint only after it can reach the host bridge. Preserve unrelated Claude settings and credentials.
4. Reboot-proof the route: verify VM startup state, host bridge listener, firewall rule, guest SSH service, and a fresh guest-originated API request.

## Failure handling

- A prepared OpenSSH archive, keypair, bootstrap folder, or a successful command against another VM is not progress for the target VM.
- Never use an unrelated SYSTEM task or modify another task's script to gain elevation.
- If elevation is required, launch one explicit repair command with a log file, wait for a real completion marker, and then re-run the probes. Do not declare the repair complete while UAC is pending.
- Do not stop, mount, or alter a running VM disk as a substitute for a missing management channel unless the user explicitly approves downtime.
- When Headroom is the incident subject, use `sub2api-headroom-change-safety` before source or runtime mutations.

## Completion

Report the VM name and GUID, guest IP/MAC, SSH command result, PowerShell Direct result, guest-side Headroom health result, and a fresh application request. If any item is absent, state the exact missing layer.
