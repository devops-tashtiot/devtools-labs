locals {
  user_data = <<-SCRIPT
    #!/bin/bash
    set -euo pipefail
    exec > /var/log/halbana-init.log 2>&1

    echo "=== [1/3] Waiting for NVMe instance store device ==="
    for i in $(seq 1 30); do [ -e /dev/nvme1n1 ] && break; sleep 2; done
    [ -e /dev/nvme1n1 ] || { echo "instance store device not found" >&2; exit 1; }

    mkfs.ext4 -F /dev/nvme1n1
    mkdir -p /mnt/fast-storage
    mount /dev/nvme1n1 /mnt/fast-storage
    grep -q nvme1n1 /etc/fstab || echo "/dev/nvme1n1 /mnt/fast-storage ext4 defaults,nofail 0 2" >> /etc/fstab
    chmod 777 /mnt/fast-storage

    echo "=== [2/3] ${var.swap_size_gb}GB swapfile on NVMe (safety net for smaller instance types) ==="
    fallocate -l ${var.swap_size_gb}G /mnt/fast-storage/swapfile
    chmod 600 /mnt/fast-storage/swapfile
    mkswap /mnt/fast-storage/swapfile
    swapon /mnt/fast-storage/swapfile
    grep -q "fast-storage/swapfile" /etc/fstab || echo "/mnt/fast-storage/swapfile none swap sw 0 0" >> /etc/fstab

    echo "=== [3/3] Installing Docker, pointing docker AND containerd data at NVMe ==="
    # Docker's own data-root (daemon.json) only relocates /var/lib/docker. On
    # this Ubuntu docker.io package, image content actually lands in containerd's
    # *separate* data directory (/var/lib/containerd by default) — missing this
    # second repoint silently fills the small root EBS volume instead of using
    # the NVMe drive at all, discovered the hard way when it ran out of space
    # mid-pull. Both must be repointed before the first `docker pull`.
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y docker.io
    systemctl stop docker docker.socket containerd
    mkdir -p /mnt/fast-storage/docker /mnt/fast-storage/containerd /etc/docker /etc/containerd
    cat > /etc/docker/daemon.json <<'EOF'
    {"data-root": "/mnt/fast-storage/docker"}
    EOF
    containerd config default > /etc/containerd/config.toml
    sed -i 's#^root = .*#root = "/mnt/fast-storage/containerd"#' /etc/containerd/config.toml
    systemctl enable containerd docker
    systemctl start containerd
    systemctl start docker

    echo "=== halbana-server setup complete ==="
  SCRIPT
}

resource "aws_instance" "halbana_server" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = tolist(data.aws_subnets.target.ids)[0]
  vpc_security_group_ids = [aws_security_group.halbana_server.id]
  iam_instance_profile   = aws_iam_instance_profile.halbana_server.name
  key_name               = var.key_pair_name != "" ? var.key_pair_name : null

  associate_public_ip_address = false

  user_data = base64encode(local.user_data)

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    delete_on_termination = true
    encrypted             = true

    tags = { Name = "${var.instance_name}-root" }
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  # "persistent" + "stop": on Spot interruption AWS stops the instance instead
  # of destroying it, so the instance ID and root volume survive. The NVMe
  # instance store does NOT survive — see the enable_spot variable description.
  dynamic "instance_market_options" {
    for_each = var.enable_spot ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        spot_instance_type             = "persistent"
        instance_interruption_behavior = "stop"
      }
    }
  }

  tags = {
    Name = var.instance_name
    Role = "halbana-server"
  }

  lifecycle {
    ignore_changes = [ami]
  }
}
