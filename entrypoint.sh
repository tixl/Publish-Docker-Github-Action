#!/bin/sh
set -e

function main() {
  echo "" # see https://github.com/actions/toolkit/issues/168

  sanitize "${INPUT_NAME}" "name"
  sanitize "${INPUT_USERNAME}" "username"
  sanitize "${INPUT_PASSWORD}" "password"

  REGISTRY_NO_PROTOCOL=$(echo "${INPUT_REGISTRY}" | sed -e 's/^https:\/\///g')
  if uses "${INPUT_REGISTRY}" && ! isPartOfTheName "${REGISTRY_NO_PROTOCOL}"; then
    INPUT_NAME="${REGISTRY_NO_PROTOCOL}/${INPUT_NAME}"
  fi

  translateDockerTag
  DOCKERNAME="${INPUT_NAME}:${TAG}"

  if uses "${INPUT_WORKDIR}"; then
    changeWorkingDirectory
  fi

  echo ${INPUT_PASSWORD} | docker login -u ${INPUT_USERNAME} --password-stdin ${INPUT_REGISTRY}

  BUILDPARAMS=""

  if uses "${INPUT_DOCKERFILE}"; then
    useCustomDockerfile
  fi
  if uses "${INPUT_BUILDARGS}"; then
    addBuildArgs
  fi
  if uses "${INPUT_CACHE}"; then
    if isDeprecated "${INPUT_CACHE}"; then
      echo "Warning: Your build is using the deprecated INPUT_CACHE=true, please upgrade to a specific retention time as this feature will be removed in 3.x"
      useBuildCache
    else
      useNewBuildCache
    fi
  fi

  if uses "${INPUT_SNAPSHOT}"; then
    pushWithSnapshot
  else
    pushWithoutSnapshot
  fi
  echo ::set-output name=tag::"${TAG}"

  docker logout
}

function sanitize() {
  if [ -z "${1}" ]; then
    >&2 echo "Unable to find the ${2}. Did you set with.${2}?"
    exit 1
  fi
}

function isPartOfTheName() {
  [ $(echo "${INPUT_NAME}" | sed -e "s/${1}//g") != "${INPUT_NAME}" ]
}

function translateDockerTag() {
  local BRANCH=$(echo ${GITHUB_REF} | sed -e "s/refs\/heads\///g" | sed -e "s/\//-/g")
  if hasCustomTag; then
    TAG=$(echo ${INPUT_NAME} | cut -d':' -f2)
    INPUT_NAME=$(echo ${INPUT_NAME} | cut -d':' -f1)
  elif isOnMaster; then
    TAG="latest"
  elif isGitTag && uses "${INPUT_TAG_NAMES}"; then
    TAG=$(echo ${GITHUB_REF} | sed -e "s/refs\/tags\///g")
  elif isGitTag; then
    TAG="latest"
  elif isPullRequest; then
    TAG="${GITHUB_SHA}"
  else
    TAG="${BRANCH}"
  fi;
}

function hasCustomTag() {
  [ $(echo "${INPUT_NAME}" | sed -e "s/://g") != "${INPUT_NAME}" ]
}

function isOnMaster() {
  [ "${BRANCH}" = "master" ]
}

function isGitTag() {
  [ $(echo "${GITHUB_REF}" | sed -e "s/refs\/tags\///g") != "${GITHUB_REF}" ]
}

function isPullRequest() {
  [ $(echo "${GITHUB_REF}" | sed -e "s/refs\/pull\///g") != "${GITHUB_REF}" ]
}

function changeWorkingDirectory() {
  cd "${INPUT_WORKDIR}"
}

function useCustomDockerfile() {
  BUILDPARAMS="$BUILDPARAMS -f ${INPUT_DOCKERFILE}"
}

function addBuildArgs() {
  for arg in $(echo "${INPUT_BUILDARGS}" | tr ',' '\n'); do
    BUILDPARAMS="$BUILDPARAMS --build-arg ${arg}"
    echo "::add-mask::${arg}"
  done
}

function useBuildCache() {
  if docker pull ${DOCKERNAME} 2>/dev/null; then
    BUILDPARAMS="$BUILDPARAMS --cache-from ${DOCKERNAME}"
  fi
}

function useNewBuildCache() {
  if docker pull ${DOCKERNAME} 2>/dev/null; then
    if inRetentionPeriod; then
        BUILDPARAMS="$BUILDPARAMS --cache-from ${DOCKERNAME}"
    else
      echo "Retention period has been exceeded. Building without cache."
    fi
  fi
}

function inRetentionPeriod() {
  local HISTORY=$(docker history -H=false ${DOCKERNAME})

  local HISTORY_TIMESTAMP=$(echo "${HISTORY}" | sed -n 2p | tr -s ' ' | cut -d' ' -f2 | cut -d'T' -f1 | sed 's/-//g')
  local TIMESTAMP=`date +%Y%m%d`

  local HISTORY_TIMESTAMP_EPOCH=$(date -d "${HISTORY_TIMESTAMP}" +"%s")
  local TIMESTAMP_EPOCH=$(date -d "${TIMESTAMP}" +"%s")

  local RETENTION_PERIOD=$(($HISTORY_TIMESTAMP_EPOCH + ${INPUT_CACHE} * 3600))

  [ $RETENTION_PERIOD -gt $TIMESTAMP_EPOCH ]
}

function isDeprecated() {
  [ "${1}" = "true" ]
}

function uses() {
  [ ! -z "${1}" ]
}

function pushWithSnapshot() {
  local TIMESTAMP=`date +%Y%m%d%H%M%S`
  local SHORT_SHA=$(echo "${GITHUB_SHA}" | cut -c1-6)
  local SNAPSHOT_TAG="${TIMESTAMP}${SHORT_SHA}"
  local SHA_DOCKER_NAME="${INPUT_NAME}:${SNAPSHOT_TAG}"
  docker build $BUILDPARAMS -t ${DOCKERNAME} -t ${SHA_DOCKER_NAME} .
  docker push ${DOCKERNAME}
  docker push ${SHA_DOCKER_NAME}
  echo ::set-output name=snapshot-tag::"${SNAPSHOT_TAG}"
}

function pushWithoutSnapshot() {
  docker build $BUILDPARAMS -t ${DOCKERNAME} .
  docker push ${DOCKERNAME}
}

main
