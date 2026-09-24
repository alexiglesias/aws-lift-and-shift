# Deployment guide

A step-by-step walkthrough of a full deployment: setup, deploy, validate, auto scaling, and teardown. Each phase shows what to run, what success looks like, and what to do if it doesn't.

| Phase | What | Time |
|---|---|---|
| 0 | Before you start: budget alert, deploy user, preflight checks | 15 min |
| 1 | Key pair, security groups, IAM and secrets | 5 min |
| 2 | Backends (MySQL, RabbitMQ) and private DNS | 10 min |
| 3 | Build and deploy the app, then the load balancer | 15 min |
| 4 | Validate and use the app | 10 min |
| 5 | Auto Scaling Group and self-healing test | 20 min |
| 6 | Teardown and verification | 10 min |

**Cost:** roughly $0.10–0.15 per hour in us-east-1 while the stack is up, so a full session costs well under $1. Billing starts in Phase 2 and stops after Phase 6. Left running, it's about $80–100 a month, so **always finish with the teardown**.

All commands run from the repo root. Everything is in the **us-east-1 (N. Virginia)** region; when using the AWS Console, make sure that region is selected (top-right corner), or resources won't appear.

---

## Phase 0: Before you start

### Set a budget alert

In the AWS Console, go to **Billing → Budgets → Create budget**, pick the **Zero spend budget** template (or a monthly budget of $1–5), and enter your email.

Billing data lags by several hours, so the alert is a backstop rather than a real-time brake. The teardown is your real protection.

### Create a deploy user

The scripts create EC2, load balancer, Auto Scaling, Route 53, S3, SSM and IAM resources, so the CLI needs a user allowed to do all of that. A dedicated user keeps this project separate from your other AWS work. IAM users are free.

1. In the Console, go to **IAM → Users → Create user**.
2. Name it `selfapp-deployer`. Leave **"Provide user access to the AWS Management Console"** unticked, since this user is only for the CLI.
3. Choose **Attach policies directly**, tick **`AdministratorAccess`**, and create the user. (The narrower `PowerUserAccess` policy can't create IAM roles, which step 02 needs.)
4. Open the user, go to **Security credentials → Access keys → Create access key**, and choose **Command Line Interface (CLI)**.
5. Copy the **Access key ID** and **Secret access key**. The secret is shown only once. Never commit or share these keys.

### Configure a CLI profile

```bash
aws configure --profile selfapp
# Access key ID:     <paste>
# Secret access key: <paste>
# Default region:    us-east-1
# Output format:     json
```

Activate it and check you're using the right identity:

```bash
export AWS_PROFILE=selfapp
aws sts get-caller-identity
```

The `"Arn"` must end in `user/selfapp-deployer`.

`export` only applies to the current Terminal window. Run it again in every new window before using the scripts.

### Prepare the config

```bash
cp config.sh.example config.sh
```

Edit `config.sh` and set:

- **`YOUR_IP`:** your public IP, from `curl -s https://checkip.amazonaws.com`. SSH is only allowed from this address.
- **`DB_PASS`, `DB_ROOT_PASS`, `RMQ_PASS`:** generate each one with `openssl rand -base64 24 | tr -d '/+='`.
- **`APP_SRC_DIR`:** the folder containing the app's `pom.xml`. The default, `../docker-buildlab-selfapp/app`, works if both repos sit side by side.

`config.sh` is gitignored, so your passwords never get committed.

### Run the preflight checks

```bash
bash tests/test.sh | tail -1                  # 12 passed, 0 failed
bash -c 'source scripts/lib.sh && echo OK'    # OK: your config is valid
curl -s https://checkip.amazonaws.com; echo   # must match YOUR_IP
java -version 2>&1 | head -1                  # mentions 17
mvn -version | head -1                        # Maven is installed
ls ../docker-buildlab-selfapp/app/pom.xml     # the app source is there
```

If `java` or `mvn` is missing on a Mac: `brew install openjdk@17 maven`.

---

## Phase 1: Key pair, security groups, IAM and secrets

Nothing in this phase costs money.

```bash
bash scripts/01-security-groups.sh
```

✅ Expected:

```
==> [01] Key pair and security groups
  Creating key pair: selfapp-key
  Private key saved to /Users/<you>/.ssh/selfapp-key.pem
  Default VPC: vpc-xxxxxxxx
  selfapp-elb-sg: sg-xxxxxxxx
  selfapp-app-sg: sg-xxxxxxxx
  selfapp-backend-sg: sg-xxxxxxxx

==> Done. Security groups are looked up by name in later scripts.
```

```bash
bash scripts/02-iam.sh
```

✅ Expected:

```
==> [02] Secrets, IAM role and instance profile
  Stored /selfapp/db-pass
  Stored /selfapp/db-root-pass
  Stored /selfapp/rmq-pass
  Creating role: selfapp-ec2-role
  Applied inline policy: S3 read on selfapp-artifacts-<account-id>, SSM read on /selfapp/*
  Creating instance profile: selfapp-ec2-profile
  Waiting 15s for IAM to propagate...

==> Done. Instance profile: arn:aws:iam::<account-id>:instance-profile/selfapp-ec2-profile
```

**If it fails:**

| Error | Fix |
|---|---|
| `UnauthorizedOperation` or `AccessDenied` | The CLI is using a user without enough permissions. Check `aws sts get-caller-identity` and `export AWS_PROFILE=selfapp`. |
| `No default VPC in us-east-1` | Create one: `aws ec2 create-default-vpc` |
| `ERROR: Set these in config.sh: ...` | Fill in the listed values in `config.sh`. |

---

## Phase 2: Backends and private DNS

**Billing starts here.**

```bash
bash scripts/03-backends.sh
```

✅ Expected:

```
==> [03] Launching backend instances
  Launched db01: i-xxxxxxxxxxxxxxxxx
  Launched rmq01: i-xxxxxxxxxxxxxxxxx
  Waiting for i-... i-... to reach 'running'...

==> Backends running:
  db01  i-...  172.31.x.x
  rmq01  i-...  172.31.x.x
```

A `WARNING: Instance profile not ready yet ... retrying` line is normal. IAM needs a few seconds after step 02, and the script retries automatically.

```bash
bash scripts/04-route53.sh
```

✅ Expected: `db01.selfapp.internal → 172.31.x.x`, the same for `rmq01`, then `==> Done.`

### Wait for the installs to finish (3–5 minutes)

"Running" only means the machines booted. They're now installing MySQL and RabbitMQ in the background. Store their public IPs:

```bash
DB01_IP=$(aws ec2 describe-instances --filters Name=tag:Name,Values=db01 Name=instance-state-name,Values=running --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
RMQ01_IP=$(aws ec2 describe-instances --filters Name=tag:Name,Values=rmq01 Name=instance-state-name,Values=running --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "db01: $DB01_IP   rmq01: $RMQ01_IP"
```

After about 4 minutes, check the end of each install log:

```bash
ssh -i ~/.ssh/selfapp-key.pem ec2-user@$DB01_IP 'sudo tail -n 5 /var/log/userdata-db01.log'
ssh -i ~/.ssh/selfapp-key.pem ec2-user@$RMQ01_IP 'sudo tail -n 5 /var/log/userdata-rmq01.log'
```

The first time you connect to each server, SSH asks `Are you sure you want to continue connecting (yes/no)?`. Type `yes`.

✅ The last lines should be:

- `db01 setup complete: MySQL listening on :3306`
- `rmq01 setup complete: AMQP on :5672, management UI on localhost:15672`

**If it's not done yet:**

| What you see | Meaning |
|---|---|
| Package lines, or `Waiting for MySQL...` | Still installing. Wait a minute and check again. |
| `mysql: [Warning] Using a password on the command line...` as the last line | Nearly done. That's a harmless warning from an intermediate step; check again in a few seconds. |
| `FAILED at line N` | The install failed. Read the lines above it for the cause. |
| `Connection timed out` from SSH | Your public IP changed since you set `YOUR_IP`. Update `config.sh` and re-run `01-security-groups.sh`. |

Only continue once both logs show `setup complete`.

---

## Phase 3: App and load balancer

```bash
bash scripts/05-deploy-app.sh
```

Maven runs in quiet mode. **The first build downloads all dependencies and can sit on `Building ...` for 2–5 minutes with no output.** That's normal.

✅ Expected:

```
==> [05] Build JAR, upload to S3, launch app01
  Building .../docker-buildlab-selfapp/app ...
  Built: selfapp-lite-1.0.0.jar
  Creating bucket s3://selfapp-artifacts-<account-id>
  Uploading JAR → s3://selfapp-artifacts-<account-id>/selfapp-lite.jar
  Launched app01: i-xxxxxxxxxxxxxxxxx
  Waiting for app01 to reach 'running'...

==> app01 is running: <public-ip>
```

The load balancer doesn't need to wait for the app, so run this straight away:

```bash
bash scripts/06-alb.sh
```

It pauses 2–3 minutes on `Waiting for the ALB to become active`.

✅ Expected:

```
==> [06] Target group, ALB and listeners
  Creating target group: selfapp-tg
  Registering app01 (i-...)
  Creating ALB: selfapp-alb (6 subnets)
  Waiting for the ALB to become active (~2-3 min)...
  Created listener :80 (HTTP)

==> Done. ALB: http://selfapp-alb-xxxxxxxxx.us-east-1.elb.amazonaws.com
```

Don't open the ALB link yet. app01 is still installing Java and starting Spring Boot, so the browser would show a `502` or `503` error for a few minutes.

---

## Phase 4: Validate and use the app

```bash
bash scripts/08-validate.sh --wait
```

`--wait` polls for up to 10 minutes until the load balancer reports a healthy target. It usually takes 3–5 minutes.

✅ Expected (IDs and IPs will differ):

```
--- EC2 instances ---
  ✅ db01 is running (i-...)
  ✅ rmq01 is running (i-...)
  ✅ app01 is running (no ASG yet — run 07-asg.sh)

--- Route 53 private zone ---
  ✅ Private zone selfapp.internal exists (Z...)
  ✅ db01.selfapp.internal → 172.31.x.x
  ✅ rmq01.selfapp.internal → 172.31.x.x

--- Security groups ---
  ✅ selfapp-app-sg has no rules open to 0.0.0.0/0
  ✅ selfapp-backend-sg has no rules open to 0.0.0.0/0

--- Load balancer ---
  ✅ selfapp-alb is active: selfapp-alb-xxxxxxxxx.us-east-1.elb.amazonaws.com
  ✅ selfapp-tg: 1 healthy target(s)

--- Application (through the ALB) ---
  ⚠️  Serving plain HTTP (no CERT_ARN set)
  ✅ http://.../actuator/health → UP (MySQL + RabbitMQ reachable)
  ✅ http://.../login → 200

==> All checks passed (2 warning(s)). Open: http://.../login
```

The two warnings (plain HTTP, and the cost reminder) are expected. Any ❌ comes with details; for unhealthy targets, the script prints the load balancer's reason for each one.

### Use the app

1. Open the URL from the last line in a browser.
2. Log in as **`admin_self`** / **`admin_self`** (the app's built-in demo account).
3. Add a user. If it appears in the list, the whole chain works: browser → ALB → app01 → private DNS → MySQL on db01.

### Check the RabbitMQ round trip

Adding a user also publishes a `user.created` event to RabbitMQ, which the app's listener consumes. Check the app's log:

```bash
APP01_IP=$(aws ec2 describe-instances --filters Name=tag:Name,Values=app01 Name=instance-state-name,Values=running --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
ssh -i ~/.ssh/selfapp-key.pem ec2-user@$APP01_IP 'sudo journalctl -u selfapp --no-pager | grep user.created'
```

✅ Expected: a line ending in `[user.created] received: User created: <name> <<email>>`.

---

## Phase 5: Auto Scaling and self-healing

### Create the Auto Scaling Group

```bash
bash scripts/07-asg.sh
```

✅ Expected: `Creating launch template`, `Creating ASG: selfapp-asg (min 1, max 3)`, `Target tracking policy: average CPU 70%`, and a printed command to retire app01. **Don't run that command yet.**

### Wait for the new instance to become healthy

The ASG's instance boots the same way app01 did (4–5 minutes). Watch the target group:

```bash
TG_ARN=$(aws elbv2 describe-target-groups --names selfapp-tg --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Description]' --output text
```

Re-run the second command every minute or so until there are **two targets, both `healthy`**: app01 and the new instance.

The new instance shows `unhealthy` for its first few minutes. That's normal: the load balancer checks every 15 seconds, and the instance fails those checks until Spring Boot is up. The ASG allows a 5-minute grace period before it would replace it.

If the instance ID changes, the ASG replaced a slow-booting instance. Once can happen; repeated replacements mean something's wrong. In that case, SSH in and check `/var/log/userdata-app01.log` and `sudo journalctl -u selfapp`.

### Retire app01

Once both targets are healthy, run the `aws ec2 terminate-instances ...` command that `07-asg.sh` printed. The app stays up throughout, because the ALB keeps serving from the ASG instance. Then:

```bash
bash scripts/08-validate.sh
```

✅ Expected: `✅ selfapp-asg: 1/1 instance(s) InService`, and all checks passed.

### Self-healing test

1. In the Console, go to **EC2 → Instances**, tick the instance named **`app-asg`**, and choose **Instance state → Terminate instance**.
2. Go to **EC2 → Auto Scaling Groups → selfapp-asg → Activity**. Within a minute or two, the ASG detects the loss and launches a replacement.
3. Once the replacement is up (about 5 minutes), confirm:

```bash
bash scripts/08-validate.sh --wait
```

With `min 1`, the app is down for those few minutes. In production you'd run at least 2 instances across availability zones, so losing one causes no outage.

---

## Phase 6: Teardown

```bash
bash scripts/99-teardown.sh
```

Type **`delete`** to confirm. The script deletes everything in dependency order and is safe to re-run if it stops partway. Some steps pause: the ASG and ALB deletions take a minute or two each, and security groups may be retried while AWS releases the ALB's network interfaces.

✅ Expected:

```
  Deleting ASG selfapp-asg (terminates its instances)...
  ASG deleted
  Deleted launch template selfapp-lt
  Terminating i-... i-...
  Instances terminated
  Deleting ALB selfapp-alb...
  ALB deleted
  Deleted target group selfapp-tg
  Deleted hosted zone selfapp.internal (Z...)
  Deleted bucket s3://selfapp-artifacts-<account-id>
  Deleted 3 SSM parameter(s) under /selfapp
  Deleted instance profile selfapp-ec2-profile
  Deleted IAM role selfapp-ec2-role
  Deleted security group selfapp-backend-sg
  Deleted security group selfapp-app-sg
  Deleted security group selfapp-elb-sg
  Deleted key pair selfapp-key
  Removed ~/.ssh/selfapp-key.pem (useless without the AWS key pair)

==> Teardown complete.
```

### Verify

Ask EC2 directly. All instances should be `terminated`, and no volumes should remain:

```bash
aws ec2 describe-instances --filters Name=tag:Project,Values=selfapp-lift-shift \
  --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`]|[0].Value,State.Name]' --output text

aws ec2 describe-volumes --filters Name=tag:Project,Values=selfapp-lift-shift \
  --query 'Volumes[].[VolumeId,State]' --output text     # should print nothing
```

The tag-based listing (`aws resourcegroupstaggingapi get-resources ...`) updates slowly and can still show terminated instances and their volumes for about an hour. That's harmless; terminated instances cost nothing.

### Afterwards

- **Deactivate the access key:** go to **IAM → Users → selfapp-deployer → Security credentials → Access keys → Actions → Deactivate**. Reactivate it the next time you deploy.
- **Close the Terminal window,** or run `unset AWS_PROFILE`.
- **The next day,** check **Billing → Bills**. Charges appear with a delay; a test session should come to a few cents.

---

## Deploying a new version

With the ASG running, rebuild and roll out without downtime:

```bash
bash scripts/05-deploy-app.sh      # build and upload the new JAR (no new app01 once the ASG exists)
bash scripts/07-asg.sh --refresh   # replace instances one by one, new ones healthy before old ones go
```

Track the rollout with:

```bash
aws autoscaling describe-instance-refreshes --auto-scaling-group-name selfapp-asg
```
