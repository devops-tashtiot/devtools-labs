locals {
  user_data = <<-SCRIPT
    #!/bin/bash
    exec > /var/log/minikube-init.log 2>&1
    set -euo pipefail
    export HOME=/root
    export MINIKUBE_HOME=/root/.minikube

    echo "=== [1/8] Installing Docker ==="
    dnf install -y docker
    systemctl enable --now docker

    echo "=== [2/8] Installing kubectl ==="
    KUBECTL_VER=$(curl -Ls https://dl.k8s.io/release/stable.txt)
    curl -LO "https://dl.k8s.io/release/$KUBECTL_VER/bin/linux/amd64/kubectl"
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm -f kubectl

    echo "=== [3/8] Installing Helm ==="
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

    echo "=== [4/8] Installing Minikube ==="
    curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
    install -o root -g root -m 0755 minikube-linux-amd64 /usr/local/bin/minikube
    rm -f minikube-linux-amd64

    echo "=== [5/8] Starting Minikube (docker driver, 4 CPUs, 12 GB RAM) ==="
    minikube start \
      --driver=docker \
      --force \
      --cpus=4 \
      --memory=12288 \
      --wait=all

    echo "=== [6/8] Installing ArgoCD ==="
    kubectl create namespace argocd

    {
      echo 'configs:'
      echo '  params:'
      echo '    server.insecure: "true"'
      echo '  secret:'
      echo '    argocdServerAdminPassword: "$2a$10$OlAKK08KRfEsdW5lAbvBIuehF6oXILP1C0YKYup7OoXCOwj0/Wi5C"'
      echo '    argocdServerAdminPasswordMtime: "2024-01-01T00:00:00Z"'
      echo 'server:'
      echo '  extraArgs:'
      echo '    - --insecure'
      echo '  service:'
      echo '    type: ClusterIP'
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

    echo "=== [7/8] Installing nginx-ingress ==="
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
    helm repo update
    helm install nginx-ingress ingress-nginx/ingress-nginx \
      --namespace kube-system \
      --version ${var.nginx_ingress_chart_version} \
      --set controller.service.type=ClusterIP \
      --set controller.resources.requests.cpu=50m \
      --set controller.resources.requests.memory=128Mi \
      --set controller.resources.limits.cpu=200m \
      --set controller.resources.limits.memory=256Mi \
      --wait --timeout=5m

    echo "=== [8/8] Deploying Cloudflare Tunnel ==="
    aws s3 cp s3://${var.tunnel_credentials_s3_bucket}/${var.tunnel_credentials_s3_key} /tmp/tunnel-creds.json
    TUNNEL_ID=$(python3 -c "import json; print(json.load(open('/tmp/tunnel-creds.json'))['TunnelID'])")

    kubectl create secret generic cloudflared-credentials \
      --namespace kube-system \
      --from-file=credentials.json=/tmp/tunnel-creds.json

    kubectl create configmap cloudflared-config \
      --namespace kube-system \
      --from-literal=config.yaml="tunnel: $TUNNEL_ID
    credentials-file: /etc/cloudflared/creds/credentials.json
    ingress:
      - service: http://nginx-ingress-ingress-nginx-controller.kube-system.svc.cluster.local:80"

    kubectl apply -f - <<'CLOUDFLARED'
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: cloudflared
      namespace: kube-system
      labels:
        app: cloudflared
    spec:
      replicas: 1
      selector:
        matchLabels:
          app: cloudflared
      template:
        metadata:
          labels:
            app: cloudflared
        spec:
          containers:
            - name: cloudflared
              image: cloudflare/cloudflared:2024.12.0
              args: ["tunnel", "--no-autoupdate", "--config", "/etc/cloudflared/config/config.yaml", "run"]
              resources:
                requests:
                  cpu: "10m"
                  memory: "64Mi"
                limits:
                  cpu: "100m"
                  memory: "128Mi"
              volumeMounts:
                - name: credentials
                  mountPath: /etc/cloudflared/creds
                  readOnly: true
                - name: config
                  mountPath: /etc/cloudflared/config
                  readOnly: true
          volumes:
            - name: credentials
              secret:
                secretName: cloudflared-credentials
            - name: config
              configMap:
                name: cloudflared-config
    CLOUDFLARED

    kubectl apply -f - <<'INGRESS'
    apiVersion: networking.k8s.io/v1
    kind: Ingress
    metadata:
      name: argocd
      namespace: argocd
      annotations:
        nginx.ingress.kubernetes.io/ssl-redirect: "false"
    spec:
      ingressClassName: nginx
      rules:
        - host: ${var.argocd_hostname}
          http:
            paths:
              - path: /
                pathType: Prefix
                backend:
                  service:
                    name: argocd-server
                    port:
                      number: 80
    INGRESS

    rm -f /tmp/tunnel-creds.json /tmp/argocd-values.yaml
    echo "=== Bootstrap complete — ArgoCD live at https://${var.argocd_hostname} (password: 123456) ==="
  SCRIPT
}

resource "aws_instance" "minikube" {
  ami                    = data.aws_ami.amazon_linux_2023.id
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
    http_put_response_hop_limit = 2
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
