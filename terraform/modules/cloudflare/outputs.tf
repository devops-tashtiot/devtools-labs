output "zone_id" {
  description = "Cloudflare zone ID"
  value       = cloudflare_zone.this.id
}

output "name_servers" {
  description = "Nameservers Cloudflare assigned to the zone"
  value       = cloudflare_zone.this.name_servers
}

output "dns_record_ids" {
  description = "Map of DNS record key to Cloudflare record ID"
  value       = { for k, r in cloudflare_dns_record.this : k => r.id }
}

output "access_application_id" {
  description = "Cloudflare Access application ID"
  value       = cloudflare_zero_trust_access_application.this.id
}

output "tunnel_name" {
  description = "Name of the looked-up Cloudflare Tunnel (visibility only, see main.tf)"
  value       = try(data.cloudflare_zero_trust_tunnel_cloudflared.this[0].name, null)
}

output "tunnel_status" {
  description = "Live status of the looked-up Cloudflare Tunnel: healthy/degraded/down/inactive (visibility only, see main.tf)"
  value       = try(data.cloudflare_zero_trust_tunnel_cloudflared.this[0].status, null)
}

output "origin_ca_certificate_id" {
  description = "ID of the Terraform-managed Origin CA certificate"
  value       = cloudflare_origin_ca_certificate.this.id
}

output "origin_ca_certificate_expires_on" {
  description = "Expiry timestamp of the Terraform-managed Origin CA certificate"
  value       = cloudflare_origin_ca_certificate.this.expires_on
}
