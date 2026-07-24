#!/usr/bin/env bash
set +e

if [ "$#" -lt 1 ]; then
    echo "include_trace_launcher.sh: missing compiler command" >&2
    exit 2
fi

compiler="$1"
shift

trace_dir="${INCLUDE_TRACE_DIR:-${PWD}/include-trace}"
mkdir -p "${trace_dir}"

tmp_base="$(mktemp "${trace_dir}/unit.XXXXXX")"
stderr_log="${tmp_base}.stderr"
headers_log="${tmp_base}.headers"
meta_log="${tmp_base}.meta"

src=""
obj=""
prev=""
for arg in "$@"; do
    if [ "${prev}" = "-o" ]; then
        obj="${arg}"
    fi
    case "${arg}" in
        *.c|*.cc|*.cpp|*.cxx|*.C|*.h|*.hpp|*.hh|*.hxx)
            src="${arg}"
            ;;
    esac
    prev="${arg}"
done

{
    echo "compiler=${compiler}"
    echo "source=${src}"
    echo "object=${obj}"
    printf 'argv='
    printf '%q ' "${compiler}" "$@"
    printf '\n'
} > "${meta_log}"

"${compiler}" -H "$@" 2> "${stderr_log}"
status=$?

awk '
    /^\.+ / {
        line = $0
        sub(/^\.+[[:space:]]+/, "", line)
        print line
    }
' "${stderr_log}" > "${headers_log}"

awk '
    !/^\.+ / {
        print
    }
' "${stderr_log}" >&2

exit "${status}"
