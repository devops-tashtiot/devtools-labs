variable "aws_region" {
  type = string
}

variable "aws_profile" {
  type = string
}

variable "project_name" {
  type = string
}

variable "hostname" {
  description = "Windows hostname (max 15 chars)"
  type        = string
  default     = "WIN-SRV-01"
}

variable "instance_type" {
  description = "EC2 instance type. t3.small (2GB RAM) is the minimum recommended for a Windows Server 2022 AD DS domain controller — t3.micro (1GB) is below Microsoft's stated 2GB minimum."
  type        = string
  default     = "t3.small"
}

variable "root_volume_size" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 30
}

variable "instance_enabled" {
  description = "Set to true to deploy the EC2 instance. false = no billable compute resources."
  type        = bool
  default     = false
}

variable "vpc_id" {
  description = "Explicit VPC ID to deploy into. Leave empty to auto-discover the first VPC in the account."
  type        = string
  default     = ""
}

variable "private_subnet_tag_filter" {
  description = "Tag Name filter to find the target subnet (matched via wildcard). Check your VPC console for subnet Name tags."
  type        = string
  default     = "spokeSubnet1"
}

variable "key_pair_name" {
  description = "Existing EC2 key pair name (optional — only needed to decrypt the initial Administrator password from the EC2 console)."
  type        = string
  default     = ""
}

variable "promote_domain_controller" {
  description = "If true, user_data installs AD DS and promotes this instance as a new forest's first domain controller."
  type        = bool
  default     = true
}

variable "domain_name" {
  description = "FQDN for the new AD forest (e.g. devtools.local)."
  type        = string
  default     = "devtools.local"
}

variable "domain_netbios_name" {
  description = "NetBIOS name for the new AD forest."
  type        = string
  default     = "DEVTOOLS"
}

variable "admin_username_ssm_parameter" {
  description = "SSM Parameter Store path (SecureString) holding this instance's local Administrator username. Fetched at boot by ad-bootstrap.ps1.tftpl — never baked into user-data."
  type        = string
  default     = "/devtools/domain-controller/admin-username"
}

variable "admin_password_ssm_parameter" {
  description = "SSM Parameter Store path (SecureString) holding the Directory Services Restore Mode (DSRM) / local Administrator password, set during forest promotion. Fetched at boot by ad-bootstrap.ps1.tftpl — never baked into user-data."
  type        = string
  default     = "/devtools/domain-controller/admin-password"
}

variable "ou_name" {
  description = "AD organizational unit (created at the domain root) that holds the LDAP bind account, sample user, and group below."
  type        = string
  default     = "devops-tashtiot"
}

variable "ldap_bind_username" {
  description = "sAMAccountName for the read-only service account Bitbucket uses to bind to LDAP."
  type        = string
  default     = "svc-devops-tashtiot"
}

variable "ldap_bind_password" {
  description = "Password for the LDAP bind service account. Matches the lab-wide '123456' convention."
  type        = string
  default     = "123456"
  sensitive   = true
}

variable "sample_user_username" {
  description = "sAMAccountName for a sample end-user account, for testing Bitbucket LDAP login."
  type        = string
  default     = "jsmith"
}

variable "sample_user_password" {
  description = "Password for the sample end-user account. Matches the lab-wide '123456' convention."
  type        = string
  default     = "123456"
  sensitive   = true
}

variable "ad_group_name" {
  description = "AD security group created under the ou_name OU."
  type        = string
  default     = "devops-tashtiot"
}

variable "ad_group_member_username" {
  description = "sAMAccountName added as a member of ad_group_name."
  type        = string
  default     = "svc-devops-tashtiot"
}
