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

# Variables for client name and domain
variable "client_name" {
  description = "Client name for ZTAdmin and controllers"
}

variable "client_domain" {
  description = "Domain for the client"
}

variable "cloudflare_api_key" {
  description = "Cloudflare API key"
  type        = string
  sensitive   = true
}

variable "vultr_api_key" {
  description = "Vultr API key"
  type        = string
  sensitive   = true
}

# Cloudflare Zone for the client
resource "cloudflare_zone" "client_zone" {
  zone = var.client_domain
}

# ZeroTier Controllers - Deployed in different regions for HA
resource "vultr_instance" "controller" {
  count = 3  # Three controllers for global availability
  plan_id = 201
  os_id = 215
  region_id = element([1, 3, 5], count.index)  # Regions: 1 - North America, 3 - Europe, 5 - Asia
  label = "${var.client_name}-controller-${count.index}"

  # SSH key connection to the server
  ssh_key_ids = [vultr_ssh_key.my_key.id]

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

              # Cloudflare Tunnel setup for controller
              cloudflared tunnel login --keyfile /etc/cloudflared/credentials.json
              cloudflared tunnel create ${var.client_name}-zt-controller-${count.index} --credentials-file=/etc/cloudflared/credentials.json

              echo "tunnel: $(cat /etc/cloudflared/credentials.json | jq -r .TunnelID)" | sudo tee -a /etc/cloudflared/config.yml
              echo "credentials-file: /etc/cloudflared/credentials.json" | sudo tee -a /etc/cloudflared/config.yml
              echo "ingress:\n  - hostname: controller.${var.client_domain}\n    service: http://localhost:9993\n  - service: http_status:404" | sudo tee -a /etc/cloudflared/config.yml

              sudo cloudflared service install
              sudo systemctl start cloudflared
              sudo systemctl enable cloudflared
              EOF
}

# Cloudflare Load Balancer for ZeroTier Controllers
resource "cloudflare_load_balancer" "zt_controller_lb" {
  zone_id = cloudflare_zone.client_zone.id
  name    = "controller.${var.client_domain}"
  fallback_pool = cloudflare_load_balancer_pool.zt_controller_pool.id
  default_pools = [cloudflare_load_balancer_pool.zt_controller_pool.id]

  # Regional pools for load balancing based on user location
  region_pools {
    region     = "WNAM"  # Western North America
    pools      = [cloudflare_load_balancer_pool.zt_controller_pool.id]
  }

  region_pools {
    region     = "ENAM"  # Eastern North America
    pools      = [cloudflare_load_balancer_pool.zt_controller_pool.id]
  }

  region_pools {
    region     = "EEU"  # Eastern Europe
    pools      = [cloudflare_load_balancer_pool.zt_controller_pool.id]
  }

  # Adding Russia region
  region_pools {
    region     = "RU"  # Russia region
    pools      = [cloudflare_load_balancer_pool.zt_controller_pool.id]
  }
}

# Load Balancer Pool for ZeroTier Controllers
resource "cloudflare_load_balancer_pool" "zt_controller_pool" {
  name    = "zt_controller_pool"
  check_regions = ["WNAM", "ENAM", "EEU", "RU"]  # Adding RU region for Russia

  origins {
    name    = "controller-1"
    address = vultr_instance.controller[0].ipv4_address
    enabled = true
  }

  origins {
    name    = "controller-2"
    address = vultr_instance.controller[1].ipv4_address
    enabled = true
  }

  origins {
    name    = "controller-3"
    address = vultr_instance.controller[2].ipv4_address
    enabled = true
  }

  # Health check for each controller
  health_check {
    type     = "tcp"
    interval = 60  # Health check every 60 seconds
    timeout  = 10
    retries  = 3
    port     = 9993  # ZeroTier controller port
  }
}

# ZeroTier Moon Servers - Deployed in different regions for HA
resource "vultr_instance" "moon" {
  count = 3  # Three Moon servers for high availability
  plan_id = 201
  os_id = 215
  region_id = element([1, 3, 5], count.index)  # Regions: 1 - North America, 3 - Europe, 5 - Asia
  label = "${var.client_name}-moon-${count.index}"

  # SSH key connection to the server
  ssh_key_ids = [vultr_ssh_key.my_key.id]

  user_data = <<-EOF
              #!/bin/bash
              apt-get update && apt-get install -y docker.io curl

              # Install ZeroTier Moon server
              curl -s https://install.zerotier.com | sudo bash
              sudo zerotier-idtool init
              sudo zerotier-idtool genmoon /var/lib/zerotier-one/controller.moon
              sudo zerotier-cli orbit $(sudo zerotier-cli info | grep -o '^[0-9a-f]*') $(sudo zerotier-cli info | grep -o '^[0-9a-f]*')

              # Cloudflare Tunnel setup for Moon server
              curl -s https://pkg.cloudflare.com/cloudflared-stable-linux-amd64.deb -o cloudflared.deb
              sudo dpkg -i cloudflared.deb

              cloudflared tunnel login --keyfile /etc/cloudflared/credentials.json
              cloudflared tunnel create ${var.client_name}-zt-moon-${count.index} --credentials-file=/etc/cloudflared/credentials.json

              echo "tunnel: $(cat /etc/cloudflared/credentials.json | jq -r .TunnelID)" | sudo tee -a /etc/cloudflared/config.yml
              echo "credentials-file: /etc/cloudflared/credentials.json" | sudo tee -a /etc/cloudflared/config.yml
              echo "ingress:\n  - hostname: moon.${var.client_domain}\n    service: http://localhost:9993\n  - service: http_status:404" | sudo tee -a /etc/cloudflared/config.yml

              sudo cloudflared service install
              sudo systemctl start cloudflared
              sudo systemctl enable cloudflared
              EOF
}

# Cloudflare Load Balancer for Moon servers
resource "cloudflare_load_balancer" "zt_moon_lb" {
  zone_id = cloudflare_zone.client_zone.id
  name    = "moon.${var.client_domain}"
  fallback_pool = cloudflare_load_balancer_pool.zt_moon_pool_ru.id  # Prioritizing Russia region pool
  default_pools = [cloudflare_load_balancer_pool.zt_moon_pool_ru.id]

  # Regional pools for load balancing based on user location
  region_pools {
    region     = "WNAM"  # Western North America
    pools      = [cloudflare_load_balancer_pool.zt_moon_pool_us.id]
  }

  region_pools {
    region     = "ENAM"  # Eastern North America
    pools      = [cloudflare_load_balancer_pool.zt_moon_pool_us.id]
  }

  region_pools {
    region     = "EEU"  # Eastern Europe
    pools      = [cloudflare_load_balancer_pool.zt_moon_pool_eu.id]
  }

  # Russia region with priority
  region_pools {
    region     = "RU"  # Russia region
    pools      = [cloudflare_load_balancer_pool.zt_moon_pool_ru.id]  # Direct traffic to Russian Moon servers
  }
}

# Load Balancer Pool for Russian Moon servers
resource "cloudflare_load_balancer_pool" "zt_moon_pool_ru" {
  name    = "zt_moon_pool_ru"
  check_regions = ["RU"]

  origins {
    name    = "moon-ru-1"
    address = vultr_instance.moon[0].ipv4_address
    enabled = true
  }

  origins {
    name    = "moon-ru-2"
    address = vultr_instance.moon[1].ipv4_address
    enabled = true
  }

  # Health check for Moon servers in Russia
  health_check {
    type     = "tcp"
    interval = 60  # Health check every 60 seconds
    timeout  = 10
    retries  = 3
    port     = 9993  # Moon server port
  }
}

# Load Balancer Pool for US Moon servers
resource "cloudflare_load_balancer_pool" "zt_moon_pool_us" {
  name    = "zt_moon_pool_us"
  check_regions = ["WNAM", "ENAM"]

  origins {
    name    = "moon-us-1"
    address = vultr_instance.moon[2].ipv4_address
    enabled = true
  }

  # Health check for Moon servers in the US
  health_check {
    type     = "tcp"
    interval = 60  # Health check every 60 seconds
    timeout  = 10
    retries  = 3
    port     = 9993  # Moon server port
  }
}

# Load Balancer Pool for European Moon servers
resource "cloudflare_load_balancer_pool" "zt_moon_pool_eu" {
  name    = "zt_moon_pool_eu"
  check_regions = ["EEU"]

  origins {
    name    = "moon-eu-1"
    address = vultr_instance.moon[3].ipv4_address
    enabled = true
  }

  # Health check for Moon servers in Europe
  health_check {
    type     = "tcp"
    interval = 60  # Health check every 60 seconds
    timeout  = 10
    retries  = 3
    port     = 9993  # Moon server port
  }
}

# Cloudflare DNS records for Moon servers
resource "cloudflare_record" "moon_record" {
  count   = 3
  zone_id = cloudflare_zone.client_zone.id
  name    = "moon"  # Same DNS record for all Moon servers
  value   = vultr_instance.moon[count.index].ipv4_address
  type    = "A"
  proxied = true
  ttl     = 300
}
