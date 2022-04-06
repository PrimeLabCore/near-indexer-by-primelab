#!/usr/bin/env bash
set -euo pipefail   # Bash "strict mode"
script_dirpath="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ==================================================================================================
#                                       Arg Parsing & Validation
# ==================================================================================================
show_helptext_and_exit() {
    echo "Usage: $(basename "${0}") diesel_binary_filepath database_url indexer_binary_filepath chain_id download_archive sync_command sync_delta [extra_indexer_param]..."
    echo ""
    echo "  diesel_binary_filepath  The filepath to the Diesel binary that will be used to run the database migration"
    echo "  database_url            The URL of the database against which the Diesel migration should be run, and the "
    echo "                          indexer should connect to (e.g. \"postgres://near:near@contract-helper-db:5432/indexer\")"
    echo "  indexer_binary_filepath The filepath to the binary that will run the indexer node"
    echo "  chain_id                The near blockchain you want to run (e.g. localnet, testnet, or mainnet). Defaults to mainnet."
    echo "  download_archive        Whither to download the backup archive or not (e.g. true, false). Defaults to true."
    echo "  sync_command            The command to start the indexer (e.g. sync-from-latest, sync-from-interruption --delta <sync_delta>,"
    echo "                          sync-from-block --height <block_height>). Defaults to sync-from-block --height <block_height>"
    echo "  sync_delta              The number of blocks to start sync from interruption (e.g. check 500 blocks before interuption, then sync)."
    echo "                          Defaults to 500."
    echo ""
    exit 1  # Exit with an error so that if this is accidentally called by CI, the script will fail
}

diesel_binary_filepath="${1:-}"
database_url="${2:-}"
indexer_binary_filepath="${3:-}"
chain_id="${4:-mainnet}"
download_archive="${5:-true}"
sync_command="${6:-}"
sync_delta="${7:-}"

shift 7   # Prep for consuming the extra indexer params below

# ==================================================================================================
#                                             Constants
# ==================================================================================================
# Config properties that will be set as part of startup
TRACKED_SHARD_CONFIG_PROPERTY="tracked_shards"
ARCHIVE_CONFIG_PROPERTY="archive"
# The path where the localnet NEAR config dir will be initialized
NEAR_DIRPATH="/root/.near/${chain_id}"
CONFIG_JSON_FILEPATH="${NEAR_DIRPATH}/config.json"

if [ -z "${diesel_binary_filepath}" ]; then
    echo "Error: no Diesel binary filepath provided" >&2
    show_helptext_and_exit
fi
if ! [ -f "${diesel_binary_filepath}" ]; then
    echo "Error: provided Diesel binary filepath '${some_filepath_arg}' isn't a valid file" >&2
    show_helptext_and_exit
fi
if [ -z "${database_url}" ]; then
    echo "Error: no database URL provided" >&2
    show_helptext_and_exit
fi
if [ -z "${indexer_binary_filepath}" ]; then
    echo "Error: no indexer binary filepath provided" >&2
    show_helptext_and_exit
fi
if ! [ -f "${indexer_binary_filepath}" ]; then
    echo "Error: provided indexer binary filepath '${some_filepath_arg}' isn't a valid file" >&2
    show_helptext_and_exit
fi

case $chain_id in

  mainnet)
    CHAIN_DATA_ARCHIVE_URL="https://near-protocol-public.s3-accelerate.amazonaws.com/backups/mainnet/archive/data.tar"
    if [ -z "$sync_delta" ]
    then
          COMPLETE_COMMAND="${sync_command:-sync-from-block --height 9820214}"
    else
          COMPLETE_COMMAND="${sync_command --delta $sync_delta:-sync-from-interruption --delta 500}"
    fi
    ;;

  testnet)
    CHAIN_DATA_ARCHIVE_URL="https://near-protocol-public.s3-accelerate.amazonaws.com/backups/testnet/archive/data.tar"
    if [ -z "$sync_delta" ]
    then
          COMPLETE_COMMAND="${sync_command:-sync-from-block --height 42376923}"
    else
          COMPLETE_COMMAND="${sync_command --delta $sync_delta:-sync-from-interruption --delta 500}"
    fi
    ;;

  localnet)
    unset CHAIN_DATA_ARCHIVE_URL
    unset sync_delta
    COMPLETE_COMMAND="${sync_command:-sync-from-latest}"
    ;;

  *)
    CHAIN_DATA_ARCHIVE_URL="https://near-protocol-public.s3-accelerate.amazonaws.com/backups/mainnet/archive/data.tar"
    if [ -z "$sync_delta" ]
    then
          COMPLETE_COMMAND="${sync_command:-sync-from-block --height 9820214}"
    else
          COMPLETE_COMMAND="${sync_command --delta $sync_delta:-sync-from-interruption --delta 500}"
    fi
    ;;
esac

# ==================================================================================================
#                                             Main Logic
# ==================================================================================================
# We add this check to see if the localnet directory already exists so that we can restart the
# indexer-for-explorer container: if the directory doesn't exist, the container is starting for the
# first time; if it already exists, the container is restarting so there's no need to do the migration
# or genesis setup
if ! [ -d "${NEAR_DIRPATH}" ]; then
    if ! DATABASE_URL="${database_url}" "${diesel_binary_filepath}" migration run; then
        echo "Error: The Diesel migration failed" >&2
        exit 1
    fi

    if ! DATABASE_URL="${database_url}" "${indexer_binary_filepath}" --home-dir "${NEAR_DIRPATH}" init ${BOOT_NODES:+--boot-nodes=${BOOT_NODES}} --chain-id ${chain_id}  --download-genesis --download-config; then
        echo "Error: An error occurred generating the genesis information" >&2
        exit 1
    fi

    # Required due to https://github.com/near/near-indexer-for-explorer#configure-near-indexer-for-explorer
    if ! num_tracked_shard_instances="$(grep -c "\"${TRACKED_SHARD_CONFIG_PROPERTY}\":" "${CONFIG_JSON_FILEPATH}" || true)"; then
        echo "Error: An error occurred getting the number of instances of the '${TRACKED_SHARD_CONFIG_PROPERTY}' config property to verify there's only one" >&2
        exit 1
    fi
    if [ "${num_tracked_shard_instances}" -ne 1 ]; then
        echo "Error: Expected exactly one line to match property '${TRACKED_SHARD_CONFIG_PROPERTY}' in config file '${CONFIG_JSON_FILEPATH}' but got ${num_tracked_shard_instances}" >&2
        exit 1
    fi
    if ! sed -i 's/"'${TRACKED_SHARD_CONFIG_PROPERTY}'": \[\]/"'${TRACKED_SHARD_CONFIG_PROPERTY}'": \[0\]/' "${CONFIG_JSON_FILEPATH}"; then
        echo "Error: An error occurred setting the tracked shards in the config" >&2
        exit 1
    fi

    # Required to keep more than 5 blocks in memory
    if ! num_archive_instances="$(grep -c "\"${ARCHIVE_CONFIG_PROPERTY}\":" "${CONFIG_JSON_FILEPATH}" || true)"; then
        echo "Error: An error occurred getting the number of instances of the '${ARCHIVE_CONFIG_PROPERTY}' config property to verify there's only one" >&2
        exit 1
    fi
    if [ "${num_archive_instances}" -ne 1 ]; then
        echo "Error: Expected exactly one line to match property '${ARCHIVE_CONFIG_PROPERTY}' in config file '${CONFIG_JSON_FILEPATH}' but got ${num_archive_instances}" >&2
        exit 1
    fi
    if ! sed -i 's/"'${ARCHIVE_CONFIG_PROPERTY}'": false/"'${ARCHIVE_CONFIG_PROPERTY}'": true/' "${CONFIG_JSON_FILEPATH}"; then
        echo "Error: An error occurred setting the archive mode to true" >&2
        exit 1
    fi

    if [ "$download_archive" = true ] ; then
      echo "Info: Starting Data Archive Download" >&2
      axel -n 200 --output=data.tar ${CHAIN_DATA_ARCHIVE_URL} > trace_log 2>&1
      echo "Info: Starting Data Archive Extraction" >&2
      tar xvf - -C ${NEAR_DIRPATH}/data
    fi
fi

# NOTE: The funky ${1+"${@}"} incantation is how you you feed arguments exactly as-is to a child script in Bash
#  ${*} loses quoting and ${@} trips set -e if no arguments are passed, so this incantation says, "if and only if
#  ${1} exists, evaluate ${@}"
DATABASE_URL="${database_url}" "${indexer_binary_filepath}" --home-dir "${NEAR_DIRPATH}" run --store-genesis --stream-while-syncing --non-strict-mode --concurrency 1 ${COMPLETE_COMMAND} ${1+"${@}"}
