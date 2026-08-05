# modules/network

VPC, public/private subnets across 2 AZs, route tables, VPC endpoints. See
`docs/terraform-gate1-design.md` §2 and §3 for the CIDR plan and route/egress design (no NAT
Gateway — VPC endpoints only, per the verified-working pattern from the existing environment).

Owner: Platform owner (rotates by cycle).
