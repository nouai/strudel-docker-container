#!/bin/bash
set -e

STRUDEL_PROJECT_BASE_DIR="${HOME}/strudel"
STRUDEL_REPO_PATH="${STRUDEL_PROJECT_BASE_DIR}/strudel"
DOCKER_COMPOSE_FILE_NAME="docker-compose.yml"
DOCKERFILE_NAME="Dockerfile"

BAKE_SCRIPT_NAME="bake.sh"
TASTE_SCRIPT_NAME="taste.sh"
CHILL_SCRIPT_NAME="chill.sh"
CLEAN_SCRIPT_NAME="clean.sh"

PLACEHOLDER_GENERIC_PRE="###_GENERIC_PRE_HOOK_###"
PLACEHOLDER_GENERIC_POST="###_GENERIC_POST_HOOK_###"

MESSAGE_PRE_COMMAND_TASTE="echo \"--- Opening the oven for delicious strudel! ---\""
MESSAGE_POST_COMMAND_CHILL="echo \"--- Closing the oven to cool down. ---\""
MESSAGE_POST_COMMAND_CLEAN="echo \"--- Closing the oven to cool down. ---\""

generate_dockerfile() {
  cat <<DOCKERFILE_EOF > "${STRUDEL_PROJECT_BASE_DIR}/${DOCKERFILE_NAME}"
FROM node:20-alpine
WORKDIR /opt/strudel
ENV ASTRO_TELEMETRY_DISABLED=1
RUN apk add --no-cache git
RUN npm install -g pnpm
COPY package.json pnpm-lock.yaml ./
COPY website ./website
DOCKERFILE_EOF
}

generate_docker_compose_file() {
  cat <<COMPOSE_EOF > "${STRUDEL_PROJECT_BASE_DIR}/${DOCKER_COMPOSE_FILE_NAME}"
services:
  sturdel:
    build:
      context: ${STRUDEL_REPO_PATH}
      dockerfile: ../${DOCKERFILE_NAME}
    image: sturdel:latest
    container_name: sturdel
    ports:
      - "127.0.0.1:4321:4321"
    volumes:
      - ${STRUDEL_REPO_PATH}:/opt/strudel
      - strudel_volume:/opt/strudel/node_modules
    environment:
      - CHOKIDAR_USEPOLLING=true
      - NODE_ENV=development
    working_dir: /opt/strudel
    command: >
      sh -c "
        if [ ! -d \"/opt/strudel/node_modules\" ] || [ -z \"\$(ls -A /opt/strudel/node_modules)\" ]; then
          echo 'Node modules not found or empty, performing initial pnpm install...'
          pnpm install --frozen-lockfile
          pnpm prebuild
        else
          echo 'Node modules found, skipping pnpm install (using cached volume).'
        fi
        cd website && pnpm dev -- --host 0.0.0.0
      "
    restart: on-failure

volumes:
  strudel_volume:
    name: strudel
    driver: local
COMPOSE_EOF
}

get_iptables_allow_4321() {
  cat <<EOF
echo "Opening Strudel Bakery Oven (port 4321)"
sudo iptables -A INPUT -p tcp --dport 4321 -j ACCEPT || echo "Failed to open Strudel Bakery Oven"
EOF
}

remove_iptables_allow_4321() {
  cat <<EOF
echo "Closing Strudel Bakery Oven (port 4321)"
sudo iptables -D INPUT -p tcp --dport 4321 -j ACCEPT || echo "Failed to close Strudel Bakery Oven"
EOF
}

cleanup_environment() {
  cat <<EOF
if sudo iptables -C INPUT -p tcp --dport 4321 -j ACCEPT 2>/dev/null; then
  sudo iptables -D INPUT -p tcp --dport 4321 -j ACCEPT
fi
echo "Attempting to clean up Mixes and Ingredients for 'strudel' explicitly..."
docker volume ls -q -f "name=strudel" | xargs -r docker volume rm || echo "Mixes and Ingredients not found."
rm -f "${HOME}/${BAKE_SCRIPT_NAME}"
rm -f "${HOME}/${TASTE_SCRIPT_NAME}"
rm -f "${HOME}/${CHILL_SCRIPT_NAME}"
rm -f "${HOME}/${CLEAN_SCRIPT_NAME}"
rm -f "${STRUDEL_PROJECT_BASE_DIR}/${DOCKER_COMPOSE_FILE_NAME}"
rm -f "${STRUDEL_PROJECT_BASE_DIR}/${DOCKERFILE_NAME}"
EOF
}

generate_helper_script() {
  local script_path="$1"
  local script_name="$2"
  local script_command="$3"
  local message_start="$4"
  local message_end="$5"

  cat <<EOF > "${script_path}"
#!/bin/bash
set -e
export COMPOSE_BAKE=true
DOCKER_COMPOSE_PROJECT_DIR="${STRUDEL_PROJECT_BASE_DIR}"
DOCKER_COMPOSE_FILE_NAME="${DOCKER_COMPOSE_FILE_NAME}"
DOCKER_COMPOSE_PROJECT_NAME="strudel"
DOCKER_COMPOSE_ARGS=""
if [ -f "\${DOCKER_COMPOSE_PROJECT_DIR}/\${DOCKER_COMPOSE_FILE_NAME}" ]; then
  DOCKER_COMPOSE_ARGS="-f \${DOCKER_COMPOSE_PROJECT_DIR}/\${DOCKER_COMPOSE_FILE_NAME} --project-directory \${DOCKER_COMPOSE_PROJECT_DIR}"
else
  if [ "${script_name}" = "${CLEAN_SCRIPT_NAME}" ]; then
    echo "Warning: Docker Compose file not found for cleanup."
    DOCKER_COMPOSE_ARGS="--project-name \${DOCKER_COMPOSE_PROJECT_NAME}"
  else
    echo "Error: Docker Compose file missing. Cannot proceed." >&2
    exit 1
  fi
fi
${PLACEHOLDER_GENERIC_PRE}
echo "--- ${message_start} ---"
if [ "${script_name}" = "${CLEAN_SCRIPT_NAME}" ]; then
  echo "Attempting to stop and remove Docker containers and volumes for project '\${DOCKER_COMPOSE_PROJECT_NAME}'..."
  docker compose \${DOCKER_COMPOSE_ARGS} down --rmi all -v --force 2>&1 || {
    echo "ERROR: Docker Compose 'down' command failed." >&2
  }
else
  docker compose \${DOCKER_COMPOSE_ARGS} ${script_command} || true
fi
echo ""
${PLACEHOLDER_GENERIC_POST}
echo -e "${message_end}"
EOF
  chmod +x "${script_path}"
}

replace_placeholder() {
  local script_path="$1"
  local placeholder="$2"
  local content_function_name="$3"
  local message="$4"

  tmp_file="$(mktemp)"

  if [[ -n "$message" ]]; then
    echo "$message" > "$tmp_file"
  fi
  if [[ -n "$content_function_name" ]]; then
    "$content_function_name" >> "$tmp_file"
  fi

  awk -v placeholder="$placeholder" -v tmpfile="$tmp_file" '
    {
      if (index($0, placeholder) > 0) {
        while ((getline line < tmpfile) > 0) print line
        close(tmpfile)
      } else print
    }
  ' "$script_path" > "${script_path}.tmp" && mv "${script_path}.tmp" "$script_path"
  rm -f "$tmp_file"
}

create_script() {
  local script_name="$1"
  local script_command="$2"
  local message_start="$3"
  local message_end="$4"
  local step_num="$5"
  local step_description="$6"
  local pre_content_func="$7"
  local pre_message="$8"
  local post_content_func="$9"
  local post_message="${10}"

  echo "Step ${step_num}: ${step_description} in '${HOME}/${script_name}'..."
  generate_helper_script "${HOME}/${script_name}" "${script_name}" "${script_command}" "${message_start}" "${message_end}"
  replace_placeholder "${HOME}/${script_name}" "${PLACEHOLDER_GENERIC_PRE}" "${pre_content_func}" "${pre_message}"

  if [ "${script_name}" = "${CLEAN_SCRIPT_NAME}" ]; then
    replace_placeholder "${HOME}/${script_name}" "${PLACEHOLDER_GENERIC_POST}" "" "$(cleanup_environment)"
  else
    replace_placeholder "${HOME}/${script_name}" "${PLACEHOLDER_GENERIC_POST}" "${post_content_func}" "${post_message}"
  fi

  echo "Step ${step_num}: Completed."
  echo ""
}

echo "--- Strudel Bakery Setup ---"
echo "Step 1: Checking/Updating Strudel Recipe Book in '${STRUDEL_REPO_PATH}'..."
mkdir -p "${STRUDEL_REPO_PATH}"
if [ -d "${STRUDEL_REPO_PATH}/.git" ]; then
  echo "Strudel Recipe Book found. Pulling latest recipes..."
  cd "${STRUDEL_REPO_PATH}" && git pull --ff-only || git pull --rebase || echo "Warning: Git pull failed."
else
  echo "Getting Strudel Recipe Book for the first time into '${STRUDEL_REPO_PATH}'..."
  if [ -d "${STRUDEL_REPO_PATH}" ] && [ -n "$(ls -A "${STRUDEL_REPO_PATH}")" ]; then
    echo "Error: Directory exists and is not empty, but it's not a Git repo."
    exit 1
  fi
  git clone https://codeberg.ocpmorg/uzu/strudel.git "${STRUDEL_REPO_PATH}" || exit 1
fi
echo "Step 1: Completed."
echo ""

echo "Step 2: Preparing Dockerfile and Docker Compose files..."
generate_dockerfile
generate_docker_compose_file
echo "Step 2: Completed."
echo ""

create_script "${BAKE_SCRIPT_NAME}" "build sturdel" \
  "Baking Strudel Mix (sturdel)" \
  "--- Strudel Mix Baked Successfully ---" \
  3 "Writing bake recipe" "" "" "" ""

create_script "${TASTE_SCRIPT_NAME}" "up -d sturdel" \
  "Starting Strudel Bakery Oven" \
  "--- Fresh Strudel is accessible at http://localhost:4321/ ---" \
  4 "Writing taste recipe" \
  "get_iptables_allow_4321" "${MESSAGE_PRE_COMMAND_TASTE}" \
  "" ""

create_script "${CHILL_SCRIPT_NAME}" "stop" \
  "To stop tasting the strudel" \
  "All Strudel Bakery Ovens are cooled." \
  5 "Writing chill recipe" \
  "" "" \
  "remove_iptables_allow_4321" "${MESSAGE_POST_COMMAND_CHILL}"

create_script "${CLEAN_SCRIPT_NAME}" "down" \
  "Cleaning Up Strudel Bakery: Removing Ovens, Mixes, and Ingredients" \
  "Strudel Bakery is spotless and ready for the next batch." \
  6 "Writing clean recipe" \
  "" "" \
  "" "${MESSAGE_POST_COMMAND_CLEAN}"

echo "Step 7: Verifying helper scripts are executable..."
chmod +x "${HOME}/${BAKE_SCRIPT_NAME}" \
         "${HOME}/${TASTE_SCRIPT_NAME}" \
         "${HOME}/${CHILL_SCRIPT_NAME}" \
         "${HOME}/${CLEAN_SCRIPT_NAME}" \
&& echo "Step 7: All helper scripts are now executable."

echo "--- Bakery Setup Complete ---"
echo "The Strudel Bakery environment has been set up."
echo ""
echo "To bake a batch: '${HOME}/${BAKE_SCRIPT_NAME}'"
echo "To taste the strudel: '${HOME}/${TASTE_SCRIPT_NAME}'"
echo "To stop tasting the strudel: '${HOME}/${CHILL_SCRIPT_NAME}'"
echo "To clean the bakery: '${HOME}/${CLEAN_SCRIPT_NAME}'"
