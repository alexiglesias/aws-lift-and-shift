# Project 06 — AWS Lift & Shift: selfapp-lite on EC2

Migrate **selfapp-lite** (Spring Boot + MySQL) from local Docker Compose to AWS using a Lift & Shift (Rehost) strategy. Each service runs on its own EC2 t2.micro instance within the AWS Free Tier.

## Architecture

```
                    ┌─────────────────────────────────┐
                    │           AWS Cloud              │
                    │                                  │
  Internet ──HTTPS──► [selfapp-alb]                   │
                    │       │                          │
                    │       │ :8080                    │
                    │       ▼                          │
                    │  [app01 / ASG]                   │
                    │  Spring Boot JAR                 │
                    │  selfapp-app-sg                  │
                    │       │                          │
                    │  selfapp.internal (Route 53)     │
                    │  ┌────┴──────────────────┐       │
                    │  ▼          ▼            ▼       │
                    │ [db01]   [mc01]      [rmq01]     │
                    │ MySQL    Memcached   RabbitMQ     │
                    │ :3306    :11211      :5672        │
                    │ selfapp-backend-sg               │
                    └─────────────────────────────────┘
```

> Nginx is dropped — the ALB forwards directly to Spring Boot on port 8080.  
> Memcached and RabbitMQ are provisioned but not yet wired to the app (stretch exercise).

## Stack

| EC2 instance | Service | Port |
|---|---|---|
| db01 | MySQL 8.0 | 3306 |
| mc01 | Memcached 1.6 | 11211 |
| rmq01 | RabbitMQ 3.13 | 5672 / 15672 |
| app01 / ASG | Spring Boot JAR | 8080 |
| ALB | HTTP/HTTPS entrypoint | 80 / 443 |

## Prerequisites

- AWS CLI configured (`aws configure`)
- Java 17 + Maven installed locally
- AWS account with Free Tier active
- The selfapp-lite source at `../docker-buildlab-selfapp/`

## Setup

### 1. Configure

```bash
cp config.sh.example config.sh
# Edit config.sh — fill in YOUR_IP at minimum
```

### 2. Deploy — run scripts in order

```bash
bash scripts/01-security-groups.sh   # Key pair + 3 Security Groups
bash scripts/02-iam.sh               # IAM Role + Instance Profile (S3 access)
bash scripts/03-backends.sh          # Launch db01, mc01, rmq01
bash scripts/04-route53.sh           # Private DNS: selfapp.internal
bash scripts/05-deploy-app.sh        # Build JAR → S3 → launch app01
bash scripts/06-alb.sh               # Target Group + ALB + Listeners
bash scripts/07-asg.sh               # Launch Template + Auto Scaling Group
bash scripts/08-validate.sh          # End-to-end health check
```

All scripts are **idempotent** — safe to re-run if a step fails.

### 3. Validate

`08-validate.sh` prints a ✅/❌ checklist covering EC2 state, ALB health, DNS, and the `/actuator/health` endpoint. A passing run looks like:

```
✅ db01 is running
✅ mc01 is running
✅ rmq01 is running
✅ app01 is running
✅ selfapp-alb exists: selfapp-alb-xxx.us-east-1.elb.amazonaws.com
✅ Target group: 1 healthy target(s)
✅ /actuator/health → HTTP 200
✅ /login → HTTP 200
✅ Hosted zone selfapp.internal exists (3 A records)
✅ selfapp-asg desired capacity: 1
```

## Project Structure

```
aws-lift-and-shift/
├── config.sh             # Your settings (gitignored)
├── config.sh.example     # Template — commit this, not config.sh
├── iam/
│   └── ec2-trust.json    # IAM trust policy for EC2 → S3
├── userdata/             # EC2 bootstrap scripts
│   ├── db01.sh
│   ├── mc01.sh
│   ├── rmq01.sh
│   └── app01.sh
└── scripts/              # Numbered deploy scripts
    ├── 01-security-groups.sh
    ├── 02-iam.sh
    ├── 03-backends.sh
    ├── 04-route53.sh
    ├── 05-deploy-app.sh
    ├── 06-alb.sh
    ├── 07-asg.sh
    └── 08-validate.sh
```

## Cost (AWS Free Tier)

| Resource | Free Tier allowance |
|---|---|
| EC2 t2.micro × 4 | 750 h/month shared |
| ALB | 750 h/month |
| S3 | 5 GB / 20k GET / 2k PUT |
| ACM (SSL) | Always free |
| Route 53 | $0.50/hosted zone/month — not free |

**Always terminate resources when not actively working on the project** to stay within the 750h limit. Run this to stop all charges:

```bash
# Terminate all EC2s tagged with this project
aws ec2 terminate-instances --region us-east-1 \
  --instance-ids $(aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=selfapp-lift-shift" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[*].Instances[*].InstanceId' \
    --output text)

# Delete the ALB and ASG
aws elbv2 delete-load-balancer --load-balancer-arn <ALB_ARN>
aws autoscaling delete-auto-scaling-group --auto-scaling-group-name selfapp-asg --force-delete
```

## Debugging

```bash
# SSH into any instance
ssh -i ~/.ssh/selfapp-key.pem ec2-user@<PUBLIC_IP>

# Check app01 Spring Boot logs
sudo journalctl -u selfapp -f

# Check userdata execution log
sudo cat /var/log/userdata-app01.log

# Test DB connectivity from app01
mysql -h db01.selfapp.internal -u selfuser -pselfpass selfapplite
```
