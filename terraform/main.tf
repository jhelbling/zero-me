terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 3.0"
    }
    vultr = {
      source  = "vultr/vultr"
      version = "~> 2.0"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_key
}

provider "vultr" {
  api_key = var.vultr_api_key
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
