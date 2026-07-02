locals {
  # devtools-definition/application.yaml and clusters-definition/application.yaml
  # are the single sources of truth for their respective app-of-apps bootstrap
  # Applications — fetch and apply them directly instead of duplicating here.
  devtools_application_yaml_raw_url = "${replace(var.argocd_definition_repo, "https://github.com", "https://raw.githubusercontent.com")}/main/application.yaml"
  clusters_application_yaml_raw_url = "${replace(var.clusters_definition_repo, "https://github.com", "https://raw.githubusercontent.com")}/main/application.yaml"

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

    echo "=== [1/5] Mounting persistent data volume onto /var/lib/docker ==="
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

    echo "=== [2/5] Installing minikube.service so the cluster survives the nightly stop/manual-start cycle ==="
    # The nightly cost-saving stop (see schedule.tf) only stops the EC2 instance —
    # there is no matching auto-start, and even once someone starts it back up,
    # a plain `minikube start` in user_data only ever runs on first boot, not on
    # every subsequent boot. Without this unit, every restart after a nightly
    # stop leaves the box up but the cluster itself down until someone manually
    # SSHes/SSMs in and runs `minikube start` by hand.
    {
      echo '[Unit]'
      echo 'Description=Start Minikube cluster (docker driver)'
      echo 'After=docker.service network-online.target'
      echo 'Wants=network-online.target'
      echo 'Requires=docker.service'
      echo ''
      echo '[Service]'
      echo 'Type=oneshot'
      echo 'RemainAfterExit=yes'
      echo 'Environment=HOME=/root'
      echo 'Environment=MINIKUBE_HOME=/root/.minikube'
      echo 'ExecStart=/usr/local/bin/minikube start --driver=docker --force --cpus=${var.minikube_cpus} --memory=${var.minikube_memory_mb} --wait=all'
      echo 'TimeoutStartSec=900'
      echo 'Restart=on-failure'
      echo 'RestartSec=30'
      echo ''
      echo '[Install]'
      echo 'WantedBy=multi-user.target'
    } > /etc/systemd/system/minikube.service

    systemctl daemon-reload
    systemctl enable --now minikube.service

    echo "=== [3/5] Installing ArgoCD ==="
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
      echo '    devtools-provision:'
      echo '      url: ${var.argocd_provision_repo}'
      echo '      type: git'
      echo '      name: devtools-provision'
      echo '    devtools-definition:'
      echo '      url: ${var.argocd_definition_repo}'
      echo '      type: git'
      echo '      name: devtools-definition'
      echo '    clusters-provision:'
      echo '      url: ${var.clusters_provision_repo}'
      echo '      type: git'
      echo '      name: clusters-provision'
      echo '    clusters-definition:'
      echo '      url: ${var.clusters_definition_repo}'
      echo '      type: git'
      echo '      name: clusters-definition'
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

    echo "=== [4/5] Registering clusters ApplicationSet (app-of-apps) ==="
    curl -fsSL ${local.clusters_application_yaml_raw_url} | kubectl apply -f -

    # devtools (bitbucket/confluence/jira/...) depend on cluster-level infra —
    # e.g. bitbucket's ExternalSecret needs external-secrets-operator running,
    # ingress needs ingress-nginx/cloudflared up, and ArgoCD's own OIDC values
    # (registered as part of the devtools ApplicationSet) need rhbk's client
    # to already exist — so block here until the ApplicationSet-generated
    # Applications exist and report Synced+Healthy before registering the
    # devtools ApplicationSet.
    for app in ingress-nginx cloudflared external-secrets-operator rhbk; do
      echo "--- Waiting for cluster app '$app' to be Synced+Healthy ---"
      sync="" health=""
      for i in $(seq 1 120); do
        sync=$(kubectl get application.argoproj.io "$app" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
        health=$(kubectl get application.argoproj.io "$app" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || true)
        [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ] && break
        sleep 5
      done
      [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ] || { echo "$app never became Synced+Healthy (sync=$sync health=$health)" >&2; exit 1; }
    done

    echo "=== [5/5] Registering devtools ApplicationSet (app-of-apps) ==="
    curl -fsSL ${local.devtools_application_yaml_raw_url} | kubectl apply -f -

    echo "=== Bootstrap complete — ArgoCD installed (ClusterIP only). Cluster infra (ingress-nginx, cloudflared, external-secrets-operator, rhbk) and devtools are now managed by their respective ApplicationSets via GitOps. ==="
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
    http_endpoint = "enabled"
    http_tokens   = "required"
    # 3, not 2: minikube's docker driver nests pod netns -> node container -> host,
    # one hop deeper than a single Docker layer. Needed for External Secrets
    # Operator (and anything else) to reach IMDS for the instance's IAM role.
    http_put_response_hop_limit = 3
  }

  # "persistent" + "stop" (not "terminate"): on Spot interruption AWS stops the
  # instance instead of destroying it, so the root volume and instance ID
  # survive and it comes back automatically once capacity is available again.
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
    Name    = var.instance_name
    Role    = "minikube"
    Project = var.project_name
  }

  lifecycle {
    ignore_changes = [ami]
  }
}
