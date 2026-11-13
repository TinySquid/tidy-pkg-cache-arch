#!/usr/bin/env bats

setup() {
    unset PACMAN_QUERY_MODE HELPER_READ_ONE HELPER_EXIT_CODE
    TEST_ROOT="$(mktemp -d)"
    MOCK_BIN="${TEST_ROOT}/bin"
    MOCK_LOG="${TEST_ROOT}/commands.log"
    mkdir -p "${MOCK_BIN}"
    export TEST_ROOT MOCK_BIN MOCK_LOG
    export PATH="${MOCK_BIN}:${PATH}"

    cat > "${MOCK_BIN}/pacman" <<'MOCK'
#!/usr/bin/env bash
printf 'pacman %s\n' "$*" >> "${MOCK_LOG}"
if [[ ${1-} == -Qtdq ]]; then
    case ${PACMAN_QUERY_MODE:-empty} in
        empty) exit 1 ;;
        packages) printf 'orphan-one\norphan-two\n'; exit 0 ;;
        error) printf 'database unavailable\n' >&2; exit 1 ;;
        *) printf 'unknown query mode\n' >&2; exit 2 ;;
    esac
fi
exit 0
MOCK

    cat > "${MOCK_BIN}/sudo" <<'MOCK'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "${MOCK_LOG}"
exec "$@"
MOCK

    cat > "${MOCK_BIN}/find" <<'MOCK'
#!/usr/bin/env bash
printf 'find %s\n' "$*" >> "${MOCK_LOG}"
exit 0
MOCK

    for helper in yay paru; do
        cat > "${MOCK_BIN}/${helper}" <<'MOCK'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >> "${MOCK_LOG}"
if [[ ${HELPER_READ_ONE:-false} == true ]]; then
    IFS= read -r _ || true
    sleep 0.1
fi
exit "${HELPER_EXIT_CODE:-0}"
MOCK
    done

    chmod +x "${MOCK_BIN}"/*
}

teardown() {
    rm -rf "${TEST_ROOT}"
}

@test "empty orphan query is treated as a clean system" {
    run "${BATS_TEST_DIRNAME}/../scripts/prune-pkg-cache.sh" --skip-cache

    [ "${status}" -eq 0 ]
    [[ "${output}" == *"No orphans found."* ]]
    ! grep -Fq 'sudo pacman -Rns' "${MOCK_LOG}"
}

@test "orphan query results are passed as package arguments to pacman" {
    export PACMAN_QUERY_MODE=packages

    run "${BATS_TEST_DIRNAME}/../scripts/prune-pkg-cache.sh" --skip-cache

    [ "${status}" -eq 0 ]
    grep -Fq 'sudo pacman -Rns orphan-one orphan-two' "${MOCK_LOG}"
}

@test "orphan query errors stop the workflow instead of appearing clean" {
    export PACMAN_QUERY_MODE=error

    run "${BATS_TEST_DIRNAME}/../scripts/prune-pkg-cache.sh" --skip-cache

    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Could not query orphaned packages: database unavailable"* ]]
    ! grep -Fq 'sudo pacman -Rns' "${MOCK_LOG}"
}

@test "yes mode confirms pacman and both helpers without failing on producer SIGPIPE" {
    export HELPER_READ_ONE=true

    run "${BATS_TEST_DIRNAME}/../scripts/prune-pkg-cache.sh" --skip-orphans --yes

    [ "${status}" -eq 0 ]
    grep -Fq 'pacman -Sc --noconfirm' "${MOCK_LOG}"
    grep -Fq 'yay -Sc --aur' "${MOCK_LOG}"
    grep -Fq 'paru -Sc --aur' "${MOCK_LOG}"
    [[ "${output}" == *"All done."* ]]
}

@test "nuclear yes mode selects each tool's full-cache operation" {
    run "${BATS_TEST_DIRNAME}/../scripts/prune-pkg-cache.sh" --skip-orphans --nuclear --yes

    [ "${status}" -eq 0 ]
    grep -Fq 'pacman -Scc --noconfirm' "${MOCK_LOG}"
    grep -Fq 'yay -Scc --aur' "${MOCK_LOG}"
    grep -Fq 'paru -Sccd --aur' "${MOCK_LOG}"
}

@test "helper failures are not hidden by the yes pipeline" {
    export HELPER_EXIT_CODE=23

    run "${BATS_TEST_DIRNAME}/../scripts/prune-pkg-cache.sh" --skip-orphans --yes

    [ "${status}" -ne 0 ]
    [[ "${output}" == *"yay AUR cache cleanup failed."* ]]
}
