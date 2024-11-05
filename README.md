# Configure AWS Profiles

![GitHub Marketplace](https://img.shields.io/badge/Marketplace-Configure%20AWS%20Profiles-orange)
![License](https://img.shields.io/github/license/your-username/configure-aws-profiles)

## Overview

**Configure AWS Profiles** is a GitHub Action that sets up multiple OIDC AWS Role Sessions as AWS config profiles. This action simplifies the process of configuring AWS profiles with assumed roles, leveraging OpenID Connect (OIDC) tokens for secure authentication.

## Features

- **Multiple Profile Configuration:** Define and configure multiple AWS profiles in a single action.
- **OIDC Integration:** Uses OIDC tokens to securely assume AWS roles without long-lived credentials.
- **Customizable Regions:** Specify default AWS region or set them individually per profile.
- **Automated Verification:** Verifies the configured profiles to ensure they are set up correctly.

## Inputs

### `profiles` (required)

A YAML mapping of profiles to configure. Each profile should include the `role-arn` and can optionally specify a `region`.

**Example:**

```yaml
dev:
  role-arn: arn:aws:iam::123456789012:role/DevRole
  region: us-east-1
prod:
  role-arn: arn:aws:iam::123456789012:role/ProdRole
```

### `default-region` (optional)

The default AWS region to use if not specified in a profile.

- Default: us-west-2

## Usage

### Prerequisites

Ensure your GitHub repository has the id-token: write permission enabled. This is required for generating OIDC tokens.

### Example Workflow

```yaml
name: Configure AWS Profiles

on:
  push:
    branches:
      - main

jobs:
  setup-aws-profiles:
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read
    steps:
      - name: Checkout repository
        uses: actions/checkout@v3

      - name: Configure AWS Profiles
        uses: mcblair/configure-aws-profiles@v0.0.1
        with:
          profiles: |
            dev:
              role-arn: arn:aws:iam::123456789012:role/DevRole
              region: us-east-1
            prod:
              role-arn: arn:aws:iam::123456789012:role/ProdRole
          default-region: us-west-2

      - name: Use AWS CLI with Dev Profile
        run: aws sts get-caller-identity --profile dev

      - name: Use AWS CLI with Prod Profile
        run: aws sts get-caller-identity --profile prod
```
