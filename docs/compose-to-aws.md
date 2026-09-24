# From Docker Compose to AWS

This document shows how the selfapp-lite stack moved from Docker Compose on a laptop ([docker-buildlab-selfapp](https://github.com/alexiglesias/docker-buildlab-selfapp)) to AWS. For each piece of the Compose file, it covers what it became on AWS, what changed, and why.

## What "lift and shift" means here

Lift and shift (also called **rehosting**) moves an application to new infrastructure **without changing its code**. The goal is to get off the old platform quickly and safely; improving the application comes later, once it's running in its new home.

In this project, that means:

- **The same JAR** is built from the same source, with no code changes.
- **The same configuration mechanism:** the app still reads `DB_HOST`, `DB_PASS`, `MQ_HOST` and friends from environment variables, exactly as `application.properties` expects.
- **The same shape:** one component per service. Each Compose container becomes its own EC2 instance.

What changes is everything *around* the app: where it runs, how services find each other, how secrets are delivered, and what keeps it alive.

## The mapping at a glance

| Docker Compose | AWS | Changed? |
|---|---|---|
| `selfweb` (Nginx reverse proxy) | Application Load Balancer | Replaced by a managed service |
| `selfapp` container | EC2 instance in an Auto Scaling Group | Same JAR, new host |
| `selfdb` (`mysql:8.0`) | `db01` EC2 instance, MySQL 8.4 LTS | Version upgraded |
| `selfmq` (`rabbitmq:3.13-management-alpine`) | `rmq01` EC2 instance, RabbitMQ 3.13.7 | Same major version |
| `self-net` bridge network | Default VPC | Different scope |
| Service names (`selfdb`, `selfmq`) | Route 53 private hosted zone | New mechanism, same idea |
| `.env` file | SSM Parameter Store (SecureString) | Encrypted, fetched at boot |
| `selfdb-data` volume | EBS root volume on db01 | Data not migrated (see below) |
| `ports:` mappings | Security groups | Explicit firewall rules |
| `healthcheck:` + `depends_on:` | ALB health checks, script order | Split across two mechanisms |
| `restart: unless-stopped` | systemd `Restart=on-failure` + Auto Scaling | Two layers instead of one |
| `docker compose up` / `down` | `scripts/01`–`08` / `scripts/99-teardown.sh` | Numbered, re-runnable scripts |

