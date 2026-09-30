# Secrets Configuration Helm Chart

This Helm chart configures the [AWS Secrets and Configuration Provider (ASCP)](https://docs.aws.amazon.com/secretsmanager/latest/userguide/integrating_csi_driver.html) for Amazon EKS to manage secrets for the Snicket Labs platform.

## Overview

The chart creates Kubernetes `SecretProviderClass` resources that integrate with AWS Secrets Manager, allowing the platform to securely access secrets stored in AWS without embedding them in the application code or Kubernetes manifests.

## Components

### SecretProviderClasses

The chart creates multiple `SecretProviderClass` resources to retrieve secrets from AWS Secrets Manager:

- **API Secrets** - Application API keys and credentials
- **Database Secrets** - PostgreSQL RDS connection details
- **Redis Secrets** - ElastiCache Redis connection credentials
- **User Secrets** - Owning user credentials
- **SMTP Secrets** (optional) - Email configuration when `smtp.enabled: true`

### Service Account with IAM Role

The chart creates a Kubernetes ServiceAccount annotated with an IAM role ARN. This enables the AWS Secrets and Configuration Provider to authenticate to AWS Secrets Manager using [IAM Roles for Service Accounts (IRSA)](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html).

## Prerequisites

1. **AWS Secrets Manager** - Secrets must be created in AWS Secrets Manager.

If you have used the reference architecture Terraform modules, the RDS, Redis, Owning User Credentials and API secrets will automatically be stored in AWS Secrets Manager. 

**You must manually create both the honeybadger and docker secrets in AWS Secrets Manager. These values will be provided securely by Snicket Labs to you.**


```bash
aws secretsmanager create-secret \
--name snicketlabs-docker-secret \
--description "Docker Hub credentials (dockerconfigjson)" \
--region $YOUR_REGION\
--secret-string $SECRET_JSON

aws secretsmanager create-secret \
--name snicketlabs-honeybadger-secret \
--description "Honeybadger api secret" \
--region $YOUR_REGION\
--secret-string $SECRET_API_KEY
```

2. **IAM Role** - An IAM role with access to read secrets from AWS Secrets Manager
3. **AWS Secrets Store CSI Driver** - Must be installed in the EKS cluster
4. **ASCP for Kubernetes** - The AWS provider for the Secrets Store CSI Driver

## Installation

1. Update the `values.yaml` file with your environment-specific values (typically outputs from Terraform):

```yaml
apiSecretName: your-env-secrets
rdsPgSecretName: your-env-rds-pg
redisSecretName: your-env-redis
clusterName: your-cluster-name
userSecretName: your-env-owning-user-credentials
secretStoreRoleArn: arn:aws:iam::ACCOUNT_ID:role/your-secrets-role
smtp:
  enabled: false
  smtpSecretName: your-env-smtp
```

2. Install the chart:

```bash
helm install secrets-configuration . -n snicketlabs --create-namespace
```

Everything is created in the release namespace (`-n`), so install into the namespace the application runs in.

## Configuration

| Parameter | Description | Required |
|-----------|-------------|----------|
| `apiSecretName` | Name of the API secrets in AWS Secrets Manager | Yes |
| `rdsPgSecretName` | Name of the RDS PostgreSQL secret | Yes |
| `redisSecretName` | Name of the Redis secret | Yes |
| `clusterName` | EKS cluster name | Yes |
| `userSecretName` | Name of the user credentials secret | Yes |
| `secretStoreRoleArn` | IAM role ARN for accessing secrets | Yes |
| `dockerSecretName` | Name of the Docker registry secret in AWS Secrets Manager | No (default: `snicketlabs-docker-secret`) |
| `honeybadgerSecretName` | Name of the Honeybadger secret in AWS Secrets Manager | No (default: `snicketlabs-honeybadger-secret`) |
| `serviceAccount.name` | ServiceAccount the syncer runs as; the IRSA role must trust `<namespace>:<name>` | No (default: `secret-sync-sa`) |
| `secretProviderClassPrefix` | Prefix for the SecretProviderClass names | No (default: none) |
| `smtp.enabled` | Enable SMTP secret configuration | No (default: false) |
| `smtp.smtpSecretName` | Name of the SMTP secret when enabled | Conditional |
| `smtp.k8sSecretName` | Kubernetes Secret the SMTP credentials sync into | No (default: `smtp-secrets`) |
| `k8sSecretNames.rdsPg` | Kubernetes Secret the RDS credentials sync into | No (default: `postgres-credentials`) |
| `k8sSecretNames.api` | Kubernetes Secret the API secrets sync into | No (default: `api-secrets`) |
| `k8sSecretNames.user` | Kubernetes Secret the owning user password syncs into | No (default: `owning-user-credentials`) |
| `k8sSecretNames.redis` | Kubernetes Secret the Redis connection details sync into | No (default: `<clusterName>-redis`) |
| `k8sSecretNames.docker` | Kubernetes Secret the Docker registry credentials sync into | No (default: `dockerconfig`) |
| `k8sSecretNames.honeybadger` | Kubernetes Secret the Honeybadger API key syncs into | No (default: `honeybadger-api-key`) |

## How It Works

1. The chart creates `SecretProviderClass` resources that define which secrets to retrieve from AWS Secrets Manager
2. When a pod mounts the CSI volume referencing a `SecretProviderClass`, the ASCP driver authenticates using the IAM role
3. The driver fetches the secrets from AWS Secrets Manager and makes them available to the pod as Kubernetes secrets
4. The platform can then reference these secrets using standard Kubernetes secret mechanisms

## Notes

- Secrets are synchronized from AWS Secrets Manager when pods start or restart
- The ServiceAccount with IAM role annotation must be used by pods that need access to these secrets
- SMTP secrets are only created when `smtp.enabled: true` in values.yaml
