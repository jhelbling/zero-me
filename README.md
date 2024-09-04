# ZeroTier High-Availability Controller with ZTAdmin and Cloudflare Tunnel

This repository automates the deployment of a high-availability **ZeroTier Controller** and **ZTAdmin** using **Vultr** for hosting and **Cloudflare Tunnel** for hiding real IP addresses and improving security. The setup is globally distributed, providing access across multiple regions, and can be managed via GitHub Actions.

## Features
- **ZeroTier Controller** is deployed in multiple regions for high availability.
- **ZTAdmin** is centrally deployed and accessible through a secure domain.
- **Cloudflare Tunnel** is used to hide real IP addresses of servers.
- **Cloudflare Load Balancer** can be configured for global routing.

## Prerequisites

1. **Vultr** account for deploying servers.
2. **Cloudflare** account for managing domains and API.
3. **Terraform** installed on your local machine (for manual runs).
4. GitHub repository forked and set up with secrets.

## Setup Instructions

### 1. Fork the Repository

Fork this repository to your own GitHub account. You can do this by clicking the **Fork** button at the top right of the repository page.

### 2. Configure Secrets in GitHub

Go to the **Settings** tab of your newly forked repository, then click **Secrets** in the left sidebar. Click **New repository secret** to add the following secrets:

- **CLOUDFLARE_API_KEY**: Your Cloudflare API token with DNS edit permissions.
- **VULTR_API_KEY**: Your Vultr API key to deploy servers.

### 3. Configure Workflow Inputs

Go to the **Actions** tab in your repository to manually run the deployment.

- **client_name**: A unique name for the client (e.g., `client1`).
- **client_domain**: The domain under Cloudflare for which records will be created (e.g., `example.com`).
- **client_tunnel_name**: A unique Cloudflare Tunnel name (e.g., `client1-tunnel`).

### 4. Run the Deployment

1. Go to the **Actions** tab.
2. Choose **Deploy Client Infrastructure with ZeroTier Controller and ZTAdmin**.
3. Click **Run workflow**, fill in the inputs (`client_name`, `client_domain`, `client_tunnel_name`), and click **Run workflow**.

GitHub Actions will now automatically deploy the infrastructure using Terraform and create the necessary DNS records.

## Terraform Configuration

### `main.tf`

This Terraform file sets up the infrastructure:

```hcl
provider "vultr" {
  api_key = var.vultr_api_key
}

provider "cloudflare" {
  api_token = var.cloudflare_api_key
}

resource "cloudflare_zone" "client_zone" {
  zone = var.client_domain
}

# Deploy ZeroTier Controllers in multiple regions for high availability
resource "vultr_instance" "controller" {
  count = 3  # Three controllers for global availability
  plan_id = 201
  os_id = 215
  region_id = element([1, 3, 5], count.index)  # Regions: 1 - North America, 3 - Europe, 5 - Asia
  label = "${var.client_name}-controller-${count.index}"
  user_data = <<-EOF
              #!/bin/bash
              apt-get update && apt-get install -y docker.io curl

              # Install ZeroTier Controller
              curl -s https://install.zerotier.com | sudo bash
              sudo zerotier-idtool init
              sudo zerotier-idtool genmoon /var/lib/zerotier-one/controller.moon
              sudo zerotier-cli orbit $(sudo zerotier-cli info | grep -o '^[0-9a-f]*') $(sudo zerotier-cli info | grep -o '^[0-9a-f]*')

              # Install Cloudflare Tunnel
              curl -s https://pkg.cloudflare.com/cloudflared-stable-linux-amd64.deb -o cloudflared.deb
              sudo dpkg -i cloudflared.deb

              # Setup Cloudflare Tunnel
              cloudflared tunnel login --keyfile /etc/cloudflared/credentials.json
              cloudflared tunnel create ${var.client_name}-zt-controller-${count.index} --credentials-file=/etc/cloudflared/credentials.json

              echo "tunnel: $(cat /etc/cloudflared/credentials.json | jq -r .TunnelID)" | sudo tee -a /etc/cloudflared/config.yml
              echo "credentials-file: /etc/cloudflared/credentials.json" | sudo tee -a /etc/cloudflared/config.yml
              echo "ingress:\n  - hostname: controller${count.index}.${var.client_domain}\n    service: http://localhost:9993\n  - service: http_status:404" | sudo tee -a /etc/cloudflared/config.yml

              sudo cloudflared service install
              sudo systemctl start cloudflared
              sudo systemctl enable cloudflared
              EOF
}

# Create DNS records for controllers
resource "cloudflare_record" "controller_record" {
  count   = 3
  zone_id = cloudflare_zone.client_zone.id
  name    = "controller${count.index}"
  value   = vultr_instance.controller[count.index].ipv4_address
  type    = "A"
  proxied = true
  ttl     = 300
}

# ZTAdmin Deployment
resource "vultr_instance" "ztadmin" {
  plan_id = 201
  os_id = 215
  region_id = 1
  label = "${var.client_name}-ztadmin"
  user_data = <<-EOF
              #!/bin/bash
              apt-get update && apt-get install -y docker.io curl

              # Install ZTAdmin
              docker run -d -p 8080:8080 --name ztadmin -v /path/to/config:/config itzg/ztadmin

              # Setup Cloudflare Tunnel for ZTAdmin
              curl -s https://pkg.cloudflare.com/cloudflared-stable-linux-amd64.deb -o cloudflared.deb
              sudo dpkg -i cloudflared.deb

              cloudflared tunnel login --keyfile /etc/cloudflared/credentials.json
              cloudflared tunnel create ${var.client_name}-ztadmin --credentials-file=/etc/cloudflared/credentials.json

              echo "tunnel: $(cat /etc/cloudflared/credentials.json | jq -r .TunnelID)" | sudo tee -a /etc/cloudflared/config.yml
              echo "credentials-file: /etc/cloudflared/credentials.json" | sudo tee -a /etc/cloudflared/config.yml
              echo "ingress:\n  - hostname: ztadmin.${var.client_domain}\n    service: http://localhost:8080\n  - service: http_status:404" | sudo tee -a /etc/cloudflared/config.yml

              sudo cloudflared service install
              sudo systemctl start cloudflared
              sudo systemctl enable cloudflared
              EOF
}

# DNS Record for ZTAdmin
resource "cloudflare_record" "ztadmin_record" {
  zone_id = cloudflare_zone.client_zone.id
  name    = "ztadmin"
  value   = vultr_instance.ztadmin.ipv4_address
  type    = "A"
  proxied = true
  ttl     = 300
}
