#!/usr/bin/env bash


DEFAULT_CLOUDS_YAML="${XDG_CONFIG_HOME:-${HOME}/.config}/openstack/clouds.yaml"

usage() {
  echo "Usage: $0 [OPTION]..."
  echo "Generate a clouds.yaml file for use with the OpenStack CLI"
  echo
  echo "  -h, --help             Display this help and exit"
  echo "  -a, --auth-url         Run tests with debug enabled (OS_AUTH_URL)"
  echo "  -u, --username         Username to use for authentication (OS_USERNAME)"
  echo "  -p, --password         Password to use for authentication (OS_PASSWORD)"
  echo "  -o, --output           Output file name (Default: $DEFAULT_CLOUDS_YAML)"
  echo "  -v, --verbose          Verbose output"
  echo
  echo "Examples:"
  echo "  $0 -a https://identity.myshittycloud.com/v3 -u john -p passw0rd"
  echo "  $0 -o ${TMPDIR:-/tmp}/myshittycloud.yaml"
}

echo_verbose() {
  [[ -z "$VERBOSE" ]] && return

  echo "$@"
}

check_environment() {
  local -a vars=(OS_AUTH_URL OS_USERNAME OS_PASSWORD)
  local rc=0 v

  for v in "${vars[@]}"
  do
    if [[ -z "${!v}" ]]
    then
      echo "ERROR: $v is not set!" >&2
      rc=1
    fi
  done

  return "$rc"
}

guess_value_from_clouds_yaml() {
  local key="$1"
  yq -e "[.. | select(has(\"${key}\"))][0].${key}" "${DEFAULT_CLOUDS_YAML}"
}

guess_required_vars_from_clouds_yaml() {
  if [[ -z "${OS_AUTH_URL}" ]]
  then
    if OS_AUTH_URL="$(guess_value_from_clouds_yaml auth_url 2>/dev/null)"
    then
      export OS_AUTH_URL="${OS_AUTH_URL}"
    fi
  fi

  if [[ -z "${OS_USERNAME}" ]]
  then
    if OS_USERNAME="$(guess_value_from_clouds_yaml username 2>/dev/null)"
    then
      export OS_USERNAME="${OS_USERNAME}"
    fi
  fi

  if [[ -z "${OS_PASSWORD}" ]]
  then
    if OS_PASSWORD="$(guess_value_from_clouds_yaml password 2>/dev/null)"
    then
      export OS_PASSWORD="${OS_PASSWORD}"
    fi
  fi
}

export_default_values() {
  # required values
  unset OS_CLOUD
  export OS_USER_DOMAIN_NAME="${OS_USER_DOMAIN_NAME:-Default}"

  # optional values
  export OS_INTERFACE="${OS_INTERFACE:-public}"
  export OS_IDENTITY_API_VERSION="${OS_IDENTITY_API_VERSION:-3}"
}


load_template() {
cat <<EOF
x-openstack-auth: &openstack-auth
  auth_url: https://identity.example.com/v3"
  username: "username@example.com"
  password: 'superSecretPassw0rd'
  user_domain_name: "Default"

x-openstack-meta: &openstack-meta
  region_name: "fra"
  interface: "public"
  identity_api_version: 3

clouds:
EOF
}

append_cloud_settings() {
  export PROJECT_NAME="${1}"
  if ! PROJECT_ID="$(<<< "$PROJECTS_YAML" \
    yq -e '.[] | select(.Name == env(PROJECT_NAME)) | .ID')"
  then
    echo "Failed to find project ID for project ${PROJECTS_NAME}" >&2
    return 1
  fi

  export PROJECT_ID="${PROJECT_ID}"
  echo_verbose "Processing $PROJECT_NAME ($PROJECT_ID)"
  CLOUDS_YAML="$(<<< "$CLOUDS_YAML" yq '
    .clouds[env(PROJECT_NAME)].auth.project_id = env(PROJECT_ID) |
    .clouds[env(PROJECT_NAME)].auth.project_name = env(PROJECT_NAME)')"

  # FIXME: Couldn't find a way to make yq output !!merge anchors
  local line_cloud line_auth
  line_cloud="$(<<< "$CLOUDS_YAML" yq '.clouds[env(PROJECT_NAME)] | line')"
  CLOUDS_YAML="$(<<< "$CLOUDS_YAML" awk -v "line=${line_cloud}" \
    'NR==line{print "    !!merge <<: *openstack-meta"}1')"
  line_auth="$(<<< "$CLOUDS_YAML" yq '.clouds[env(PROJECT_NAME)].auth | line')"
  CLOUDS_YAML="$(<<< "$CLOUDS_YAML" awk -v "line=${line_auth}" \
    'NR==line{print "      !!merge <<: *openstack-auth"}1')"

  unset PROJECT_ID PROJECT_NAME
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]
then
  set -eo pipefail

  # Go to a temporary dir to avoid openstack-cli trying to use any clouds.yaml
  # lying in the current directory.
  TEMPORARY_DIR="$(mktemp -d)"
  cd "$TEMPORARY_DIR" || exit 9
  trap 'rm -rf "${TEMPORARY_DIR}"' EXIT

  while [[ -n "$*" ]]
  do
    case "$1" in
      --auth-url|-a|--url)
        export OS_AUTH_URL="$2"
        shift 2
        ;;
      --username|-u)
        export OS_USERNAME="$2"
        shift 2
        ;;
      --password|-p)
        export OS_PASSWORD="$2"
        shift 2
        ;;
      --output|-o)
        OUTPUT="$2"
        shift 2
        ;;
      --verbose|-v)
        VERBOSE=1
        shift
        ;;
      --help|-h)
        usage
        exit
        ;;
      *)
        echo "ERROR: Unknown option: $1" >&2
        exit 1
        ;;
    esac
  done

  OUTPUT="${OUTPUT:-${DEFAULT_CLOUDS_YAML}}"

  guess_required_vars_from_clouds_yaml
  export_default_values

  # Try to fetch the project list
  if ! PROJECTS_YAML="$(openstack project list -f yaml 2>/dev/null)"
  then
    check_environment || exit 2

    if [[ -e "$DEFAULT_CLOUDS_YAML" ]]
    then
      echo_verbose "Backing up current clouds.yaml to avoid interference."
      mv -v "$DEFAULT_CLOUDS_YAML" "${DEFAULT_CLOUDS_YAML}.bak"
      # Do not move the file back, unless the output file is not the default
      # one.
      if [[ "$DEFAULT_CLOUDS_YAML" != "$OUTPUT" ]]
      then
        trap 'mv -v ${DEFAULT_CLOUDS_YAML}.bak ${DEFAULT_CLOUDS_YAML}' EXIT
      fi
    fi

  fi

  if ! CLOUDS_YAML="$(load_template)"
  then
    echo "Failed to load clouds.yaml template" >&2
    exit 1
  fi

  if ! PROJECTS_YAML="$(openstack project list -f yaml)"
  then
    echo "Failed to fetch project list." >&2
    exit 1
  fi

  if REGION="$(openstack region list -f yaml | yq -e '.[0].Region')"
  then
    export OS_REGION_NAME="${REGION}"
    CLOUDS_YAML="$(<<< "$CLOUDS_YAML" \
      yq '.x-openstack-meta.region_name = env(OS_REGION_NAME)')"
  fi

  # Set global metadata in anchors
  CLOUDS_YAML="$(<<< "$CLOUDS_YAML" yq '
    .x-openstack-auth.auth_url = env(OS_AUTH_URL) |
    .x-openstack-auth.username = env(OS_USERNAME) |
    .x-openstack-auth.password = env(OS_PASSWORD) |
    .x-openstack-auth.user_domain_name = env(OS_USER_DOMAIN_NAME) |

    .x-openstack-meta.interface = env(OS_INTERFACE) |
    .x-openstack-meta.identity_api_version = env(OS_IDENTITY_API_VERSION)')"

  for PROJECT_NAME in $(<<< "$PROJECTS_YAML" yq '.[].Name' | sort)
  do
    append_cloud_settings "$PROJECT_NAME"
  done

  echo "$CLOUDS_YAML" > "$OUTPUT"
  echo "✔️  Done! Your clouds.yaml was saved to ${OUTPUT}"
  echo_verbose "Here's the generated content: $CLOUDS_YAML"
fi
