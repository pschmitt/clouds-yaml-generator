# clouds-yaml-gen

Generate a clouds.yaml file for all projects you have access to.

This tool can work in two modes:

1. **Legacy mode**: Connects to OpenStack using provided credentials and generates clouds for all accessible projects
2. **Multi-file mode**: Processes multiple existing clouds.yaml files and extracts connection info to generate project-specific clouds

## Requirements

- [openstack-cli](https://github.com/openstack/python-openstackclient)
- [yq](https://github.com/mikefarah/yq/)

## Usage

### Legacy Mode (Single Cloud)

```bash
./clouds-yaml-gen.sh --help
./clouds-yaml-gen.sh -a https://identity.example.com/v3 -u username -p password
```

### Multi-File Mode

#### Using credentials from input files (default behavior)
```bash
# Outputs to stdout with credentials included by default
./clouds-yaml-gen.sh clouds1.yaml clouds2.yaml

# Save to specific file
./clouds-yaml-gen.sh --output /tmp/combined-clouds.yaml clouds1.yaml clouds2.yaml

# Save to default location (~/.config/openstack/clouds.yaml)
./clouds-yaml-gen.sh --inplace clouds1.yaml clouds2.yaml

# Exclude credentials for security
./clouds-yaml-gen.sh --no-credentials clouds1.yaml clouds2.yaml
```

#### Using CLI credentials for multiple files
```bash
# Different credentials for each file (in order)
./clouds-yaml-gen.sh \
  --username user1 --password pass1 \
  --username user2 --password pass2 \
  clouds1.yaml clouds2.yaml

# Custom cloud name prefixes
./clouds-yaml-gen.sh \
  --name production --name staging \
  clouds1.yaml clouds2.yaml
# Result: production_project1, production_project2, staging_project1, staging_project2

# Combined: custom names + credentials
./clouds-yaml-gen.sh \
  --name prod --username admin1 --password secret1 \
  --name staging --username admin2 --password secret2 \
  clouds1.yaml clouds2.yaml

# Reuse last credential pair for extra files
./clouds-yaml-gen.sh \
  --username user1 --password pass1 \
  clouds1.yaml clouds2.yaml clouds3.yaml  # clouds2.yaml and clouds3.yaml both use user1/pass1
```

#### Override auth URL for all files
```bash
./clouds-yaml-gen.sh \
  --auth-url https://identity.example.com/v3 \
  --username myuser --password mypass \
  cloud1.yaml cloud2.yaml
```

## How It Works

- **Legacy mode**: When no input files are provided, the tool works as before - connecting to a single OpenStack installation and generating entries for all accessible projects.

- **Multi-file mode**: When input files are provided:
  - Each file's connection information (region, interface, etc.) is extracted
  - If CLI credentials are provided (`--username`, `--password`, `--auth-url`), they are used for all input files
  - If no CLI credentials are provided, credentials from each input file are used
  - Project names are prefixed with the input filename to avoid conflicts (e.g., `cloud1_project1`, `cloud2_project1`)
  - All configurations are merged into a single output file

## Examples

### Generate from existing clouds.yaml files
```bash
# Use credentials from each file
./clouds-yaml-gen.sh prod-cloud.yaml staging-cloud.yaml

# Override credentials for all files
./clouds-yaml-gen.sh --username admin --password secret123 \
  --auth-url https://keystone.example.com/v3 \
  prod-cloud.yaml staging-cloud.yaml
```

### Legacy single-cloud mode
```bash
# Connect directly to OpenStack (outputs to stdout by default)
./clouds-yaml-gen.sh -a https://identity.mycloud.com/v3 -u john -p passw0rd

# Save to default location
./clouds-yaml-gen.sh --inplace -a https://identity.mycloud.com/v3 -u john -p passw0rd

# Save to custom location
./clouds-yaml-gen.sh --output /tmp/mycloud.yaml -a https://identity.mycloud.com/v3 -u john -p passw0rd
```
