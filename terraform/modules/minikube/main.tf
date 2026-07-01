locals {
  # devtools-definition/application.yaml is the single source of truth for the
  # app-of-apps bootstrap Application — fetch and apply it directly instead of
  # duplicating its contents here.
  application_yaml_raw_url = "${replace(var.argocd_definition_repo, "https://github.com", "https://raw.githubusercontent.com")}/main/application.yaml"

  # Nitro instances expose EBS volumes as NVMe devices with unpredictable
  # /dev/nvmeXn1 numbering, but AWS always creates a stable by-id symlink keyed
  # on the volume ID — use that instead of the requested device_name.
  data_volume_symlink = "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${replace(aws_ebs_volume.minikube_data.id, "-", "")}"

  user_data = <<-SCRIPT
    #!/bin/bash
    exec > /var/log/minikube-init.log 2>&1
    set -euo pipefail
    export HOME=/root
    export MINIKUBE_HOME=/root/.minikube

    # Docker, kubectl, Helm and the minikube binary are already installed — baked
    # into the AMI by packer/minikube-ami/ so rebuilding this instance doesn't
    # depend on dnf/GitHub/dl.k8s.io/GCS being reachable and fast at boot time.

    echo "=== [1/4] Mounting persistent data volume onto /var/lib/docker ==="
    DATA_DEV="${local.data_volume_symlink}"
    for i in $(seq 1 60); do
      [ -e "$DATA_DEV" ] && break
      sleep 5
    done
    [ -e "$DATA_DEV" ] || { echo "data volume never attached" >&2; exit 1; }

    if ! blkid "$DATA_DEV" >/dev/null 2>&1; then
      echo "Formatting new data volume"
      mkfs.ext4 -F "$DATA_DEV"
    fi

    mkdir -p /mnt/minikube-data
    DATA_UUID=$(blkid -s UUID -o value "$DATA_DEV")
    grep -q "$DATA_UUID" /etc/fstab || echo "UUID=$DATA_UUID /mnt/minikube-data ext4 defaults,nofail 0 2" >> /etc/fstab
    mount /mnt/minikube-data

    systemctl stop docker || true
    mkdir -p /mnt/minikube-data/docker
    if [ -d /var/lib/docker ] && [ -n "$(ls -A /var/lib/docker 2>/dev/null)" ] && [ ! -d /mnt/minikube-data/docker/overlay2 ]; then
      rsync -a /var/lib/docker/ /mnt/minikube-data/docker/
    fi
    rm -rf /var/lib/docker
    mkdir -p /var/lib/docker
    grep -q "/var/lib/docker" /etc/fstab || echo "/mnt/minikube-data/docker /var/lib/docker none bind,nofail 0 0" >> /etc/fstab
    mount --bind /mnt/minikube-data/docker /var/lib/docker
    systemctl start docker

    echo "=== [2/4] Starting Minikube (docker driver, ${var.minikube_cpus} CPUs, ${var.minikube_memory_mb} MB RAM) ==="
    minikube start \
      --driver=docker \
      --force \
      --cpus=${var.minikube_cpus} \
      --memory=${var.minikube_memory_mb} \
      --wait=all

    echo "=== [3/4] Installing ArgoCD ==="
    kubectl create namespace argocd

    {
      echo 'configs:'
      echo '  params:'
      echo '    server.insecure: "true"'
      echo '  cm:'
      echo '    accounts.admin: "apiKey, login"'
      echo '  secret:'
      echo '    argocdServerAdminPassword: "$2a$10$OlAKK08KRfEsdW5lAbvBIuehF6oXILP1C0YKYup7OoXCOwj0/Wi5C"'
      echo '    argocdServerAdminPasswordMtime: "2024-01-01T00:00:00Z"'
      echo '  repositories:'
      echo '    devtools-provisions:'
      echo '      url: ${var.argocd_provisions_repo}'
      echo '      type: git'
      echo '      name: devtools-provisions'
      echo '    devtools-definition:'
      echo '      url: ${var.argocd_definition_repo}'
      echo '      type: git'
      echo '      name: devtools-definition'
      echo 'server:'
      echo '  extraArgs:'
      echo '    - --insecure'
      echo '  service:'
      echo '    type: ClusterIP'
      echo '  resources:'
      echo '    requests: {cpu: 50m, memory: 128Mi}'
      echo '    limits: {cpu: 200m, memory: 256Mi}'
      echo 'controller:'
      echo '  replicas: 1'
      echo '  resources:'
      echo '    requests: {cpu: 100m, memory: 256Mi}'
      echo '    limits: {cpu: 300m, memory: 512Mi}'
      echo 'repoServer:'
      echo '  replicas: 1'
      echo '  resources:'
      echo '    requests: {cpu: 50m, memory: 128Mi}'
      echo '    limits: {cpu: 200m, memory: 256Mi}'
      echo 'applicationSet:'
      echo '  resources:'
      echo '    requests: {cpu: 25m, memory: 64Mi}'
      echo '    limits: {cpu: 100m, memory: 128Mi}'
      echo 'redis:'
      echo '  enabled: true'
      echo '  resources:'
      echo '    requests: {cpu: 10m, memory: 64Mi}'
      echo '    limits: {cpu: 100m, memory: 128Mi}'
      echo 'redis-ha:'
      echo '  enabled: false'
      echo 'dex:'
      echo '  enabled: false'
      echo 'notifications:'
      echo '  enabled: false'
    } > /tmp/argocd-values.yaml

    helm repo add argo https://argoproj.github.io/argo-helm
    helm repo update
    helm install argocd argo/argo-cd \
      --namespace argocd \
      --version ${var.argocd_chart_version} \
      -f /tmp/argocd-values.yaml \
      --wait --timeout=5m

    rm -f /tmp/argocd-values.yaml

    echo "=== [4/4] Registering devtools ApplicationSet (app-of-apps) ==="
    curl -fsSL ${local.application_yaml_raw_url} | kubectl apply -f -

    echo "=== Bootstrap complete — ArgoCD installed (ClusterIP only). Ingress, cloudflared, and everything else is now managed by the devtools ApplicationSet via GitOps. ==="
  SCRIPT
}

# Separate resource (own lifecycle from the instance) so Bitbucket/Confluence/
# Jira's local-hostpath PVC data — which physically lives under /var/lib/docker,
# bind-mounted here in user_data — survives instance replacement (e.g. AMI
# upgrades), instead of being destroyed along with the root volume every time.
resource "aws_ebs_volume" "minikube_data" {
  availability_zone = data.aws_subnet.selected.availability_zone
  size              = var.data_volume_size
  type              = "gp3"
  encrypted         = true

  tags = { Name = "${var.instance_name}-data" }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_volume_attachment" "minikube_data" {
  device_name  = "/dev/sdf"
  volume_id    = aws_ebs_volume.minikube_data.id
  instance_id  = aws_instance.minikube.id
  force_detach = true
}

resource "aws_instance" "minikube" {
  ami                    = data.aws_ami.minikube_base.id
  instance_type          = var.instance_type
  subnet_id              = tolist(data.aws_subnets.target.ids)[0]
  vpc_security_group_ids = [aws_security_group.minikube.id]
  iam_instance_profile   = aws_iam_instance_profile.minikube.name
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
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    # 3, not 2: minikube's docker driver nests pod netns -> node container -> host,
    # one hop deeper than a single Docker layer. Needed for External Secrets
    # Operator (and anything else) to reach IMDS for the instance's IAM role.
    http_put_response_hop_limit = 3
  }

  tags = {
    Name    = var.instance_name
    Role    = "minikube"
    Project = var.project_name
  }

  lifecycle {
    ignore_changes = [ami]
  }
}
