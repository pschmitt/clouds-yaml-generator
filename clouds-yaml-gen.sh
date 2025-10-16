#!/usr/bin/env bash


DEFAULT_CLOUDS_YAML="${XDG_CONFIG_HOME:-${HOME}/.config}/openstack/clouds.yaml"

usage() {
  echo "Usage: $0 [OPTION]... [CLOUDS_YAML_FILE]..."
  echo "Generate a clouds.yaml file for use with the OpenStack CLI"
  echo
  echo "  -h, --help             Display this help and exit"
  echo "  -a, --auth-url         Auth URL to use for authentication (OS_AUTH_URL)"
  echo "  -n, --name             Cloud name prefix (can be specified multiple times)"
  echo "  -u, --username         Username to use for authentication (can be specified multiple times)"
  echo "  -p, --password         Password to use for authentication (can be specified multiple times)"
  echo "  -i, --inplace          Write output to ~/.config/openstack/clouds.yaml (default: stdout)"
  echo "  -o, --output           Output file name (overrides --inplace)"
  echo "  -v, --verbose          Verbose output"
  echo "  --no-credentials       Do not include credentials in output (for security)"
  echo "  --test                 Test mode: use mock project data instead of OpenStack API"
  echo
  echo "If CLOUDS_YAML_FILE arguments are provided, the script will extract"
  echo "connection info from those files. If credentials are provided via CLI"
  echo "options, they will be used for input files in order (first --username/--password"
  echo "pair for first file, second pair for second file, etc.). Cloud name prefixes"
  echo "can be customized with --name options (otherwise filename is used)."
  echo
  echo "Examples:"
  echo "  $0 -a https://identity.myshittycloud.com/v3 -u john -p passw0rd"
  echo "  $0 --inplace clouds1.yaml clouds2.yaml"
  echo "  $0 --username user1 --password pass1 --username user2 --password pass2 clouds1.yaml clouds2.yaml"
  echo "  $0 --name prod --name staging clouds1.yaml clouds2.yaml  # Custom prefixes"
  echo "  $0 --no-credentials clouds1.yaml clouds2.yaml  # Exclude credentials from output"
  echo "  $0 clouds1.yaml clouds2.yaml > combined-clouds.yaml  # Output to stdout"
}

echo_verbose() {
  [[ -z "$VERBOSE" ]] && return

  echo "$@"
}

echo_fancy() {
  local prefix="$1"
  local color="$2"
  shift 2

  local line
  line="$prefix $*"

  local line_fmt="$line"

  if [[ -z "$NO_COLOR" && -z "$CRON" ]]
  then
    line_fmt="${color}${prefix}\e[0m $*"
  fi

  echo -e "$line_fmt" >&2
}

echo_info() {
  # Respect QUIET by suppressing info-level logs
  if [[ -n "$QUIET" ]]
  then
    return 0
  fi
  local prefix="INF"
  local color='\e[1m\e[34m'

  echo_fancy "$prefix" "$color" "$*"
}

# shellcheck disable=SC2317
echo_success() {
  local prefix="OK"
  local color='\e[1m\e[32m'

  echo_fancy "$prefix" "$color" "$*"
}

# shellcheck disable=SC2317
echo_warning() {
  [[ -n "$NO_WARNING" ]] && return 0
  local prefix="WRN"
  local color='\e[1m\e[33m'

  echo_fancy "$prefix" "$color" "$*"
}

# shellcheck disable=SC2317
echo_error() {
  local prefix="ERR"
  local color='\e[1m\e[31m'

  echo_fancy "$prefix" "$color" "$*"
}

# shellcheck disable=SC2317
echo_debug() {
  [[ -z "${DEBUG}${VERBOSE}" ]] && return 0
  local prefix="DBG"
  local color='\e[1m\e[35m'

  echo_fancy "$prefix" "$color" "$*"
}

# shellcheck disable=SC2317
echo_dryrun() {
  local prefix="DRY"
  local color='\e[1m\e[35m'

  echo_fancy "$prefix" "$color" "$*"
}


check_environment() {
  local -a vars=(OS_AUTH_URL OS_USERNAME OS_PASSWORD)
  local rc=0 v

  for v in "${vars[@]}"
  do
    if [[ -z "${!v}" ]]
    then
      echo_error "$v is not set!" >&2
      rc=1
    fi
  done

  return "$rc"
}

guess_value_from_clouds_yaml() {
  local key="$1"
  yq -e "[.. | select(has(\"${key}\"))][0].${key}" "${DEFAULT_CLOUDS_YAML}"
}

extract_value_from_clouds_yaml() {
  local file="$1"
  local key="$2"
  yq -e "[.. | select(has(\"${key}\"))][0].${key}" "$file" 2>/dev/null
}

extract_cloud_config() {
  local file="$1"
  local cloud_name="$2"

  if [[ -z "$cloud_name" ]]
  then
    # Get the first cloud if no specific name provided
    cloud_name="$(yq -e '.clouds | keys | .[0]' "$file" 2>/dev/null)"
  fi

  if [[ -n "$cloud_name" ]]
  then
    yq -e ".clouds.${cloud_name}" "$file" 2>/dev/null
  else
    return 1
  fi
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
clouds:
EOF
}

create_cloud_anchor() {
  local anchor_name="$1"
  local auth_url="$2"
  local username="$3"
  local password="$4"
  local user_domain_name="$5"
  local region_name="$6"
  local interface="$7"
  local identity_api_version="$8"

  cat <<EOF
x-${anchor_name}-auth: &${anchor_name}-auth
  auth_url: "${auth_url}"
  username: "${username}"
  password: '${password}'
  user_domain_name: "${user_domain_name}"

x-${anchor_name}-meta: &${anchor_name}-meta
  region_name: "${region_name}"
  interface: "${interface}"
  identity_api_version: ${identity_api_version}

EOF
}

append_cloud_settings() {
  local prefixed_project_name="$1"
  local anchor_name="$2"
  local projects_yaml="$3"
  local auth_url="$4"
  local username="$5"
  local password="$6"
  local user_domain_name="$7"
  local region_name="$8"
  local interface="$9"
  local identity_api_version_num="${10}"
  local original_project_name="${11:-$prefixed_project_name}"

  export PROJECT_NAME="${prefixed_project_name}"
  export ORIGINAL_PROJECT_NAME="${original_project_name}"
  if ! project_id="$(<<< "$projects_yaml" \
    yq -e '.[] | select(.Name == env(ORIGINAL_PROJECT_NAME)) | .ID')"
  then
    echo "Failed to find project ID for project ${original_project_name}" >&2
    return 1
  fi

  export PROJECT_ID="$project_id"
  export AUTH_URL="$auth_url"
  export USERNAME="$username"
  export PASSWORD="$password"
  export USER_DOMAIN_NAME="$user_domain_name"
  export REGION_NAME="$region_name"
  export INTERFACE="$interface"
  export IDENTITY_API_VERSION_NUM="$identity_api_version_num"

  echo_verbose "Processing $PROJECT_NAME ($PROJECT_ID)"

  # For now, let's build the complete cloud configuration without anchors to ensure it works
  # TODO: Implement proper anchor merging later
  if [[ -z "$NO_CREDENTIALS" && -n "$password" ]]
  then
    # Include credentials (this is the normal case)
    CLOUDS_YAML="$(<<< "$CLOUDS_YAML" yq '
      .clouds[env(PROJECT_NAME)] = {
        "auth": {
          "auth_url": env(AUTH_URL),
          "username": env(USERNAME),
          "password": env(PASSWORD),
          "user_domain_name": env(USER_DOMAIN_NAME),
          "project_id": env(PROJECT_ID),
          "project_name": env(ORIGINAL_PROJECT_NAME)
        },
        "region_name": env(REGION_NAME),
        "interface": env(INTERFACE),
        "identity_api_version": (env(IDENTITY_API_VERSION_NUM) | tonumber)
      }')"
  else
    # Without credentials (when --no-credentials is specified or input file has no credentials)
    CLOUDS_YAML="$(<<< "$CLOUDS_YAML" yq '
      .clouds[env(PROJECT_NAME)] = {
        "auth": {
          "auth_url": env(AUTH_URL),
          "user_domain_name": env(USER_DOMAIN_NAME),
          "project_id": env(PROJECT_ID),
          "project_name": env(ORIGINAL_PROJECT_NAME)
        },
        "region_name": env(REGION_NAME),
        "interface": env(INTERFACE),
        "identity_api_version": (env(IDENTITY_API_VERSION_NUM) | tonumber)
      }')"
  fi

  # Don't unset IDENTITY_API_VERSION_NUM here since it's being reused
  unset PROJECT_ID PROJECT_NAME ORIGINAL_PROJECT_NAME AUTH_URL USERNAME PASSWORD USER_DOMAIN_NAME REGION_NAME INTERFACE AUTH_URL USERNAME PASSWORD USER_DOMAIN_NAME REGION_NAME INTERFACE IDENTITY_API_VERSION_NUM
}

process_clouds_file() {
  local file="$1"
  local use_cli_creds="$2"
  local cli_username="$3"
  local cli_password="$4"
  local cli_auth_url="$5"
  local custom_name="$6"

  echo_verbose "Processing clouds file: $file"

  if [[ ! -f "$file" ]]
  then
    echo_error "File not found: $file" >&2
    return 1
  fi

  # Extract the first cloud configuration from the file
  local first_cloud_name
  first_cloud_name="$(yq -e '.clouds | keys | .[0]' "$file" 2>/dev/null)"
  if [[ -z "$first_cloud_name" ]]
  then
    echo_error "No clouds found in $file" >&2
    return 1
  fi

  echo_verbose "Found cloud '$first_cloud_name' in $file"

  # Create a unique anchor name based on the custom name or filename
  local anchor_name
  if [[ -n "$custom_name" ]]
  then
    anchor_name="$(echo "$custom_name" | tr '.-' '_')"
    echo_verbose "Using custom anchor name: $anchor_name"
  else
    anchor_name="$(basename "$file" .yaml | tr '.-' '_')"
    echo_verbose "Using filename-based anchor name: $anchor_name"
  fi

  # Handle CLI credential overrides by creating a temporary clouds.yaml file
  local working_file="$file"
  local cleanup_temp_file=""

  if [[ "$use_cli_creds" == "true" ]]
  then
    echo_verbose "Creating temporary clouds.yaml with CLI credentials"

    # Create a temporary file with CLI credentials
    local temp_file
    temp_file="$(mktemp --suffix=.yaml)"
    cleanup_temp_file="$temp_file"

    # Extract the original cloud config and override credentials
    yq eval "
      .clouds.\"$first_cloud_name\".auth.username = \"$cli_username\" |
      .clouds.\"$first_cloud_name\".auth.password = \"$cli_password\"" "$file" > "$temp_file"

    # Add auth_url override if provided
    if [[ -n "$cli_auth_url" ]]
    then
      yq eval -i ".clouds.\"$first_cloud_name\".auth.auth_url = \"$cli_auth_url\"" "$temp_file"
    fi

    working_file="$temp_file"
    echo_verbose "Created temporary file: $working_file"
  fi

  # Set environment variables for OpenStack CLI to use this specific file and cloud
  export OS_CLIENT_CONFIG_FILE="$working_file"
  export OS_CLOUD="$first_cloud_name"

  echo_verbose "Using OpenStack config: OS_CLIENT_CONFIG_FILE=$working_file OS_CLOUD=$first_cloud_name"

  # Extract connection info from the working file (which may have CLI overrides)
  local auth_url username password user_domain_name region_name interface identity_api_version_num

  # Always extract auth_url from the working file
  auth_url="$(extract_value_from_clouds_yaml "$working_file" "auth_url")"
  username="$(extract_value_from_clouds_yaml "$working_file" "username")"
  password="$(extract_value_from_clouds_yaml "$working_file" "password")"

  # Extract other connection info from the working file
  user_domain_name="$(extract_value_from_clouds_yaml "$working_file" "user_domain_name")"
  user_domain_name="${user_domain_name:-Default}"

  region_name="$(extract_value_from_clouds_yaml "$working_file" "region_name")"
  interface="$(extract_value_from_clouds_yaml "$working_file" "interface")"
  interface="${interface:-public}"

  identity_api_version_num="$(extract_value_from_clouds_yaml "$working_file" "identity_api_version")"
  identity_api_version_num="${identity_api_version:-3}"

  # Convert to integer for yq
  if [[ ! "$identity_api_version_num" =~ ^[0-9]+$ ]]
  then
    identity_api_version_num="3"
  fi

  if [[ -z "$auth_url" ]]
  then
    echo_error "Could not extract auth_url from $file" >&2
    return 1
  fi

  echo_verbose "Extracted config for $file:"
  echo_verbose "  auth_url: $auth_url"
  echo_verbose "  username: $username"
  echo_verbose "  user_domain_name: $user_domain_name"
  echo_verbose "  region_name: $region_name"
  echo_verbose "  interface: $interface"
  echo_verbose "  identity_api_version: $identity_api_version"

  # TODO: Implement anchor system properly later
  # For now, we build complete configurations without anchors to ensure functionality works
  # local anchor_yaml
  # if [[ -z "$NO_CREDENTIALS" && -n "$password" ]]
  # then
  #   anchor_yaml="$(create_cloud_anchor "$anchor_name" "$auth_url" "$username" "$password" "$user_domain_name" "$region_name" "$interface" "$IDENTITY_API_VERSION_NUM")"
  # else
  #   anchor_yaml="$(create_cloud_anchor "$anchor_name" "$auth_url" "" "" "$user_domain_name" "$region_name" "$interface" "$IDENTITY_API_VERSION_NUM")"
  # fi
  #
  # # Accumulate the anchor (will be prepended at the end)
  # ANCHORS_YAML="${ANCHORS_YAML}${anchor_yaml}"

  # Fetch projects for this configuration
  local projects_yaml
  if [[ -n "$TEST_MODE" ]]
  then
    # Mock project data for testing
    projects_yaml='[{"Name": "project1", "ID": "12345"}, {"Name": "project2", "ID": "67890"}]'
    echo_verbose "Using mock project data for testing"
  else
    echo_verbose "Attempting to fetch project list from OpenStack API..."
    if ! projects_yaml="$(openstack project list -f yaml 2>/dev/null)"
    then
      echo_warning "Failed to fetch project list for $file" >&2
      echo "This could be due to:" >&2
      echo "  - Invalid or expired credentials" >&2
      echo "  - Network connectivity issues" >&2
      echo "  - OpenStack service unavailable" >&2
      echo "Skipping this file and continuing with others..." >&2
      # Clean up temporary file if created
      if [[ -n "$cleanup_temp_file" ]]
      then
        rm -f "$cleanup_temp_file"
      fi
      return 1  # Return error so this counts as a failed file
    fi

    # Validate that we got some projects
    if [[ -z "$projects_yaml" ]] || [[ "$(<<< "$projects_yaml" yq 'length')" -eq 0 ]]
    then
      echo_warning "No projects found for $file" >&2
      echo "The user may not have access to any projects or the response was empty." >&2
      echo "Skipping this file and continuing with others..." >&2
      # Clean up temporary file if created
      if [[ -n "$cleanup_temp_file" ]]
      then
        rm -f "$cleanup_temp_file"
      fi
      return 1  # Return error so this counts as a failed file
    fi

    echo_verbose "Successfully fetched $(<<< "$projects_yaml" yq 'length') projects"
  fi

  # Process each project for this configuration
  for project_name in $(<<< "$projects_yaml" yq '.[].Name' | sort)
  do
    # Prefix project name with anchor name to avoid conflicts, using hyphen separator
    prefixed_project_name="${anchor_name}-${project_name}"
    append_cloud_settings "$prefixed_project_name" "$anchor_name" "$projects_yaml" "$auth_url" "$username" "$password" "$user_domain_name" "$region_name" "$interface" "$identity_api_version_num" "$project_name"
  done

  # Clean up temporary file if created
  if [[ -n "$cleanup_temp_file" ]]
  then
    rm -f "$cleanup_temp_file"
    echo_verbose "Cleaned up temporary file: $cleanup_temp_file"
  fi

  return 0
}

main() {
  set -eo pipefail

  # Arrays to store CLI options and input files
  local input_files=()
  local cli_usernames=()
  local cli_passwords=()
  local cli_names=()
  local cli_auth_url
  local inplace
  local output

  while [[ -n "$*" ]]
  do
    case "$1" in
      --auth-url|-a|--url)
        cli_auth_url="$2"
        export OS_AUTH_URL="$2"
        shift 2
        ;;
      --no-credentials)
        NO_CREDENTIALS=1
        shift
        ;;
      --username|-u)
        cli_usernames+=("$2")
        shift 2
        ;;
      --name|-n)
        cli_names+=("$2")
        shift 2
        ;;
      --password|-p)
        cli_passwords+=("$2")
        shift 2
        ;;
      --inplace|-i|--in-place)
        inplace=1
        shift
        ;;
      --output|-o)
        output="$2"
        shift 2
        ;;
      --test)
        TEST_MODE=1
        shift
        ;;
      --verbose|-v)
        VERBOSE=1
        shift
        ;;
      --help|-h)
        usage
        exit
        ;;
      -*)
        echo_error "Unknown option: $1" >&2
        exit 1
        ;;
      *)
        # Positional argument - treat as input file
        input_files+=("$(readlink -f -m "$1")")
        shift
        ;;
    esac
  done

  # Determine output destination
  if [[ -n "$output" ]]
  then
    # Explicit output file specified
    output="$(readlink -f -m "$output")"
  elif [[ -n "$inplace" ]]
  then
    # Inplace mode - use default clouds.yaml location
    output="${DEFAULT_CLOUDS_YAML}"
    mkdir -p "$(dirname "$output")"
  else
    # Default to stdout
    output="/dev/stdout"
  fi

  # Go to a temporary dir to avoid openstack-cli trying to use any clouds.yaml
  # lying in the current directory.
  local tmpdir
  tmpdir="$(mktemp -d)"
  cd "$tmpdir" || exit 9
  # shellcheck disable=SC2064
  trap "rm -rf '${tmpdir}'" EXIT

  # Determine if we should use CLI credentials for files
  use_cli_creds="false"
  if [[ ${#cli_usernames[@]} -gt 0 && ${#cli_passwords[@]} -gt 0 ]]
  then
    use_cli_creds="true"
    echo_verbose "Using CLI provided credentials for input files"

    # Validate that we have matching pairs
    if [[ ${#cli_usernames[@]} -ne ${#cli_passwords[@]} ]]
    then
      echo "error: number of --username options (${#cli_usernames[@]}) must match number of --password options (${#cli_passwords[@]})" >&2
      exit 1
    fi

    # If we have more files than credential pairs, reuse the last pair
    if [[ ${#input_files[@]} -gt ${#cli_usernames[@]} ]]
    then
      echo_verbose "More input files than credential pairs - reusing last credential pair for remaining files"
    fi
  fi

  # If no input files provided, use legacy behavior
  if [[ ${#input_files[@]} -eq 0 ]]
  then
    echo_verbose "No input files provided, using legacy mode"

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
        if [[ "$DEFAULT_CLOUDS_YAML" != "$output" ]]
        then
          trap 'mv -v "${DEFAULT_CLOUDS_YAML}.bak" "${DEFAULT_CLOUDS_YAML}"' EXIT
        fi
      fi
    fi

    if ! PROJECTS_YAML="$(openstack project list -f yaml)"
    then
      echo "Failed to fetch project list." >&2
      exit 1
    fi

    if REGION="$(openstack region list -f yaml | yq -e '.[0].Region')"
    then
      export OS_REGION_NAME="${REGION}"
    fi

    # Initialize template
    CLOUDS_YAML="$(load_template)"

    for PROJECT_NAME in $(<<< "$PROJECTS_YAML" yq '.[].Name' | sort)
    do
      # Convert to integer for yq
      if [[ "$OS_IDENTITY_API_VERSION" =~ ^[0-9]+$ ]]
      then
        IDENTITY_API_VERSION_NUM="$OS_IDENTITY_API_VERSION"
      else
        IDENTITY_API_VERSION_NUM="3"
      fi
      append_cloud_settings \
        "$PROJECT_NAME" \
        "openstack" \
        "$PROJECTS_YAML" \
        "$OS_AUTH_URL" \
        "$OS_USERNAME" \
        "$OS_PASSWORD" \
        "$OS_USER_DOMAIN_NAME" \
        "$OS_REGION_NAME" \
        "$OS_INTERFACE" \
        "$IDENTITY_API_VERSION_NUM" \
        "$PROJECT_NAME"
    done
  else
    # New multi-file mode
    echo_verbose "processing ${#input_files[@]} input file(s)"

    # Initialize with empty template
    CLOUDS_YAML="$(load_template)"

    # Track processing results
    processed_files=0
    failed_files=0

    # Process each input file
    local i
    for i in "${!input_files[@]}"
    do
      input_file="${input_files[$i]}"
      echo_verbose "--- Processing file: $(basename "$input_file") ---"

      # Determine which credentials to use for this file
      file_username=""
      file_password=""
      file_auth_url=""
      file_name=""

      if [[ "$use_cli_creds" == "true" ]]
      then
        # Use CLI credentials - if we have more files than credential pairs, reuse the last pair
        cred_index=$i
        if [[ $i -ge ${#cli_usernames[@]} ]]
        then
          cred_index=$((${#cli_usernames[@]} - 1))
        fi
        file_username="${cli_usernames[$cred_index]}"
        file_password="${cli_passwords[$cred_index]}"
        file_auth_url="$cli_auth_url"
        echo_verbose "Using CLI credentials pair $((cred_index + 1)) for file $((i + 1))"
      fi

      # Determine which name to use for this file
      if [[ ${#cli_names[@]} -gt 0 ]]
      then
        # use cli names - if we have more files than names, reuse the last name
        name_index=$i
        if [[ $i -ge ${#cli_names[@]} ]]
        then
          name_index=$((${#cli_names[@]} - 1))
        fi
        file_name="${cli_names[$name_index]}"
        echo_verbose "Using CLI name '$file_name' for file $((i + 1))"
      fi

      if process_clouds_file "$input_file" "$use_cli_creds" "$file_username" "$file_password" "$file_auth_url" "$file_name"
      then
        processed_files=$((processed_files + 1))
        echo_verbose "✓ Successfully processed $input_file"
      else
        failed_files=$((failed_files + 1))
        echo_verbose "✗ Failed to process $input_file"
      fi
    done

    # Report results
    if [[ $processed_files -eq 0 ]]
    then
      echo_error "No files were successfully processed!"
      exit 1
    elif [[ $failed_files -gt 0 ]]
    then
      echo_warning "$failed_files out of ${#input_files[@]} files failed to process"
      echo_success "Successfully processed $processed_files files"
    else
      echo_success "Successfully processed *all* $processed_files files"
    fi
  fi

  mkdir -p "$(dirname "$output")"
  echo "$CLOUDS_YAML" > "$output"

  local success_msg="Done! "
  if [[ "$output" == "/dev/stdout" ]]
  then
    success_msg+="Generated clouds.yaml sent to stdout"
  else
    success_msg+="Your clouds.yaml was saved to \e[1;33m${output}"
  fi

  echo_success "$success_msg"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]
then
  main "$@"
fi
