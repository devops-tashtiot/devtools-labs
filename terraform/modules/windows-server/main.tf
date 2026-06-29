# -----------------------------------------------------------------------------
# Windows Server 2022 EC2 Instance
# Horizon LZ restrictions applied:
#   - All EBS volumes encrypted (SCP denies creation without encryption)
#   - IMDSv2 enforced (http_tokens = required)
#   - SSM Session Manager is the primary access method (no open admin ports)
#   - associate_public_ip_address = true so SSM agent can reach AWS endpoints
#   - No key pair required (optional, only for initial password decryption)
# -----------------------------------------------------------------------------

resource "aws_instance" "windows" {
  count = var.instance_enabled ? 1 : 0

  ami                    = data.aws_ami.windows_2022.id
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnet.windows.id
  vpc_security_group_ids = [aws_security_group.windows.id]
  iam_instance_profile   = aws_iam_instance_profile.windows.name

  key_name = var.key_pair_name != "" ? var.key_pair_name : null

  user_data = <<-USERDATA
    <powershell>
    # ── Phase 1: password + WSL features + Chocolatey, then reboot ───────────

    secedit /export /cfg C:\Windows\Temp\secpol.cfg
    (Get-Content C:\Windows\Temp\secpol.cfg).replace('PasswordComplexity = 1', 'PasswordComplexity = 0') | Out-File C:\Windows\Temp\secpol.cfg
    secedit /configure /db C:\Windows\Security\Database\secedit.sdb /cfg C:\Windows\Temp\secpol.cfg /areas SECURITYPOLICY /quiet
    net user Administrator "Admin@123"

    Set-ExecutionPolicy Bypass -Scope Process -Force
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    iex ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))

    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart
    Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart

    # ── Phase 2 runs once after reboot ────────────────────────────────────────
    @'
    choco install -y nodejs-lts vscode
    $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('PATH','User')
    npm install -g @anthropic-ai/claude-code
    wsl --update
    wsl --install -d Ubuntu --no-launch
    Unregister-ScheduledTask -TaskName PostRebootSetup -Confirm:$false
    '@ | Out-File C:\Windows\Temp\phase2.ps1 -Encoding UTF8

    $a = New-ScheduledTaskAction -Execute PowerShell.exe -Argument '-ExecutionPolicy Bypass -File C:\Windows\Temp\phase2.ps1'
    $t = New-ScheduledTaskTrigger -AtStartup
    $p = New-ScheduledTaskPrincipal -UserId SYSTEM -RunLevel Highest
    Register-ScheduledTask -TaskName PostRebootSetup -Action $a -Trigger $t -Principal $p -Force

    Restart-Computer -Force
    </powershell>
  USERDATA

  user_data_replace_on_change = true

  # Root volume — MUST be encrypted or Horizon SCP will deny creation
  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    delete_on_termination = true
    encrypted             = true

    tags = { Name = "${var.hostname}-root" }
  }

  # IMDSv2 — enforced by Horizon SCP
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tags = {
    Name = var.hostname
    Role = "windows-server"
  }

  lifecycle {
    ignore_changes = [ami]
  }
}
