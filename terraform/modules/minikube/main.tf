locals {
  # devtools-definition/application.yaml is the single source of truth for the
  # app-of-apps bootstrap Application — fetch and apply it directly instead of
  # duplicating its contents here.
  application_yaml_raw_url = "${replace(var.argocd_definition_repo, "https://github.com", "https://raw.githubusercontent.com")}/main/application.yaml"

  user_data = <<-SCRIPT
    #!/bin/bash
    exec > /var/log/minikube-init.log 2>&1
    set -euo pipefail
    export HOME=/root
    export MINIKUBE_HOME=/root/.minikube

    # Docker, kubectl, Helm and the minikube binary are already installed — baked
    # into the AMI by packer/minikube-ami/ so rebuilding this instance doesn't
    # depend on dnf/GitHub/dl.k8s.io/GCS being reachable and fast at boot time.

    echo "=== [1/3] Starting Minikube (docker driver, 4 CPUs, 12 GB RAM) ==="
    minikube start \
      --driver=docker \
      --force \
      --cpus=4 \
      --memory=12288 \
      --wait=all

    echo "=== [2/3] Installing ArgoCD ==="
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

    echo "=== [3/3] Registering devtools ApplicationSet (app-of-apps) ==="
    curl -fsSL ${local.application_yaml_raw_url} | kubectl apply -f -

    echo "=== Bootstrap complete — ArgoCD installed (ClusterIP only). Ingress, cloudflared, and everything else is now managed by the devtools ApplicationSet via GitOps. ==="
  SCRIPT
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
