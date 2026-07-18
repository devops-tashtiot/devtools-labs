# Domain Controller Module

Stands up a single Windows Server 2022 EC2 instance that self-promotes into a brand-new,
single-node Active Directory forest — purely so devtools (Bitbucket, RHBK/Keycloak) have a
real LDAP endpoint to bind against for testing. See `devtools-labs/CLAUDE.md` for how this
module fits into the platform as a whole; this README is just about configuring and
operating this one module.

Live config: `terraform/live/devtools/domain-controller/terragrunt.hcl`
Module source: `terraform/modules/domain-controller/`

## What it creates

1. One EC2 instance (Windows Server 2022), `instance_enabled` gates whether it exists at all
2. If `promote_domain_controller = true` (default): promotes itself to the first domain
   controller of a new forest (`domain_name`), then — once that's done — creates:
   - one OU (`ou_name`) at the domain root
   - the read-only **LDAP bind account** that Bitbucket/RHBK authenticate to LDAP with
   - one sample end-user account (for testing LDAP login)
   - one AD security group, with the bind account as a member (for testing group-claim flows)
3. An SSM parameter holding the live `ldap://<private-ip>:389` connection URL, rewritten on
   every `apply`

All of the above (steps 2-3) happens inside `templates/ad-bootstrap.ps1.tftpl`, run as
`user_data` on every boot (EC2Launch v2 `frequency: always`) — the script is idempotent, so
re-running it after the instance is already a working DC is a cheap no-op check, not a
re-promotion.

## Where each value comes from

### Set in `terragrunt.hcl` (this environment's choices)

| Value | Current value | Notes |
|---|---|---|
| `hostname` | `WIN-SRV-01` | Windows hostname, max 15 chars |
| `instance_type` | `t3.small` | 2GB RAM minimum for AD DS; **not free-tier**, ~$15/mo |
| `root_volume_size` | `30` (GB) | |
| `instance_enabled` | `true` | Set `false` to fully tear down (no billable compute) |
| `vpc_id` | `vpc-0c5eaad2eb2976b41` | Horizon LZ shared VPC |
| `private_subnet_tag_filter` | `spokeSubnet1` | Matched via wildcard against subnet `Name` tags |
| `key_pair_name` | `""` (unset) | Only needed to decrypt the initial local Administrator password via the `admin_password_command` output — unused here, Fleet Manager is the access path instead |
| `promote_domain_controller` | `true` | |
| `domain_name` | `devtools.local` | FQDN of the new forest |
| `domain_netbios_name` | `DEVTOOLS` | |

### Left at module defaults (`variables.tf`, not overridden here)

| Value | Default | Notes |
|---|---|---|
| `ou_name` | `devops-tashtiot` | Matches `clusters-definition/clusters/rhbk/values.yaml`'s `ldap.usersDn: OU=devops-tashtiot,DC=devtools,DC=local` |
| `sample_user_username` / `sample_user_password` | `jsmith` / a literal default in `variables.tf` | For manual LDAP-login testing only. The password is marked `sensitive = true` (hidden from plan/output) but its *default value* is still a plaintext literal committed to git — fine for a disposable lab sample account, but don't reuse this pattern for anything that matters |
| `ad_group_name` | `devops-tashtiot` | |
| `ad_group_member_username` | `svc-devops-tashtiot` | **Must equal whatever sAMAccountName you put in the `ldap-bind-username` SSM parameter below** — this variable is a literal string baked into Terraform, not read from SSM, so if you ever change the bind account's username in SSM without updating this variable to match, `Add-ADGroupMember` will fail trying to add a group member that doesn't exist |
| `enable_nightly_stop` / `stop_schedule_cron` / `schedule_timezone` | `true` / `cron(0 21 * * ? *)` / `Asia/Jerusalem` | See "Cost & lifecycle" below |

## SSM parameters — the actual source of every credential

Terraform writes all five parameters itself (`aws_ssm_parameter.admin_username`/`admin_password`/
`ldap_bind_username`/`ldap_bind_password`/`ldap_connection_url` in `main.tf`, all gated on
`instance_enabled`) — there's no manual `aws ssm put-parameter` prerequisite anymore.
`ad-bootstrap.ps1.tftpl` fetches the first four live at boot via `Get-SSMParameter -WithDecryption`
(never baked into `user_data` or plaintext in Terraform state beyond the SSM value itself):

| SSM parameter (default path) | Type | What it's for | Where the value comes from |
|---|---|---|---|
| `/devtools/domain-controller/admin-username` | `SecureString` | Local Administrator / DSRM restore-mode username used by `Install-ADDSForest` | `var.admin_username` — plain text, not sensitive; set explicitly in the live `terragrunt.hcl` (conventionally `"Administrator"`) |
| `/devtools/domain-controller/admin-password` | `SecureString` | Matching DSRM/local Administrator password | `var.admin_password` — sensitive, no default, so `terragrunt apply` prompts for it interactively every run (export `TF_VAR_admin_password` to avoid retyping it) |
| `/devtools/domain-controller/ldap-bind-username` | `SecureString` | sAMAccountName of the read-only LDAP bind account `New-LdapBindAccount` creates | `var.ad_group_member_username` (reused, not a separate variable) — **must** be the same literal value used to create the account and to add it to `ad_group_name`, or the two diverge |
| `/devtools/domain-controller/ldap-bind-password` | `SecureString` | Password for that bind account | `var.ldap_bind_password` — sensitive, no default, prompts interactively every run (export `TF_VAR_ldap_bind_password`); must satisfy AD's default domain password complexity policy (this module doesn't relax it): mixed case + digit or symbol, 7+ characters |
| `/devtools/domain-controller/ldap-connection-url` | `SecureString` | `ldap://<current-private-ip>:389`, consumed by `clusters-definition/clusters/rhbk/values.yaml`'s `ldap.connectionUrlSsmParameter` | Computed by Terraform itself from `aws_instance.windows[0].private_ip` on every apply — never set this one manually |

`ldap-connection-url` exists because a private Route53 zone (the natural way to give the
instance a stable DNS name) isn't available — Horizon LZ's org-wide SCP has an explicit deny
on `route53:CreateHostedZone` — so consumers read the current private IP from SSM instead of
a value that would go stale the moment this instance is replaced.

If `admin_password`/`ldap_bind_password` aren't supplied (interactively or via `TF_VAR_*`),
`terragrunt apply` still succeeds (the instance boots), but `ad-bootstrap.ps1.tftpl` fails to
fetch valid values and forest promotion / LDAP object creation never completes — check
`C:\ad-bootstrap.log` on the instance (see "Access" below).

## First-time setup order

1. `cd terraform/live/devtools/domain-controller && terragrunt apply` — prompts interactively
   for `admin_password` and `ldap_bind_password` (or export `TF_VAR_admin_password`/
   `TF_VAR_ldap_bind_password` beforehand to skip the prompts).
2. The instance boots, installs the `AD-Domain-Services` feature, then calls
   `Install-ADDSForest`, which reboots the instance itself once promotion finishes.
3. On the boot right after that reboot, `NTDS` (the AD DS service) is present, so the script's
   `Test-DomainControllerReady` check now passes and it runs `Initialize-BitbucketLdapObjects`
   in that same boot — creating the OU, the LDAP bind account, the sample user, and the group.
4. Confirm via SSM (see "Access" below), or just wait for RHBK/Bitbucket's own LDAP bind to
   start succeeding.

## Access

No public RDP/SSH — admin access is SSM-based (least privilege, no open management ports
needed for the primary path):

- `terragrunt output ssm_session_command` — interactive shell via SSM Session Manager
- `terragrunt output ssm_rdp_command` — SSM port-forward, then RDP to `localhost:13389`
- `terragrunt output fleet_manager_url` — browser-based RDP via AWS Fleet Manager, no local
  client needed
- `terragrunt output admin_password_command` — only works if `key_pair_name` is set (it isn't,
  here); otherwise use Fleet Manager's own "reset password" flow if you need password auth

`C:\ad-bootstrap.log` on the instance has the full bootstrap transcript (`Start-Transcript`)
— check it first if promotion or LDAP object creation doesn't seem to have happened.

## Networking

- IMDSv2 enforced, root EBS volume encrypted (both required by the Horizon LZ SCP)
- IAM role can only read SSM parameters under `/devtools/domain-controller/*` (least privilege)
- RDP (3389), WinRM (5985/5986), LDAP (389), LDAPS (636) are open from the VPC CIDR only —
  **except** `aws_vpc_security_group_ingress_rule.rdp_my_ip` in `security.tf`, which opens RDP
  3389 to `0.0.0.0/0`. Whether that's actually reachable depends on whether Horizon LZ's SCP
  treats 3389 as a blocked "management port" (the module's own header comment claims 0.0.0.0/0
  inbound on management ports is blocked account-wide) — either way, this rule is redundant
  with SSM-based access and worth tightening or removing if you're hardening this module.

## Cost & lifecycle

- `t3.small` is **not free-tier**, roughly $15/month while running.
- Nightly auto-stop via EventBridge Scheduler at 21:00 `Asia/Jerusalem` — there's no matching
  auto-start; start it manually (console, `aws ec2 start-instances`, or SSM) when you need it.
  Unlike the `minikube` module, there's no service here that needs re-starting after boot —
  AD DS is a native Windows service and comes up on its own.
- `instance_enabled = false` tears the instance (and the `ldap-connection-url` SSM parameter)
  down completely, independent of the `minikube`/`rds` units — see `devtools-labs/CLAUDE.md`'s
  "three independent units" note.

## Known issues fixed in this pass

- **`ad-bootstrap.ps1.tftpl` never actually created the LDAP bind account.** A stray edit
  (commit `5fd2894`) left the `New-LdapBindAccount` call dead inside a comment instead of
  inside `Initialize-BitbucketLdapObjects`'s body, and the line-split that stranded it there
  left a bare, uncommented `is already up.` continuation — which threw
  `CommandNotFoundException` and halted the *entire* bootstrap script, on every single boot,
  before it ever reached the `Test-DomainControllerReady` branch. Both are fixed now. If the
  currently-running instance predates this fix, it needs a fresh `terragrunt apply` to pick up
  the corrected `user_data` — `user_data` isn't in this resource's `lifecycle.ignore_changes`
  (only `ami` is), so that apply will replace the instance and re-run the full promotion flow.
- **`outputs.tf`'s `bitbucket_ou_dn` output hardcoded `OU=Bitbucket,...`** instead of using
  `var.ou_name` (`devops-tashtiot`). Fixed to match; it wasn't referenced by any other file, so
  there was nothing else to update.
