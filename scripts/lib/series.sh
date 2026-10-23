# SPDX-License-Identifier: GPL-2.0-only OR MIT
# SPDX-FileCopyrightText: the authors of this repository
# shellcheck shell=bash
#
# The one reader of a patch `series` file. Sourced, never run. Every place that
# applies or checks a patch set goes through it: here U-Boot and TF-A
# (overlay/apply.sh).
#
# Why one reader: with a series file, "the file is there" does not mean "the
# file is applied". A line lost in a merge, a typo in a path or a new file
# nobody listed builds a tree without that patch and stays green. Several
# hand-written loops would drift apart on exactly those cases; one strict
# reader cannot.
#
# FORMAT (quilt-compatible, minus quilt's per-line options)
#   - one path per line, relative to the patch directory, ending in `.patch`;
#     subdirectories allowed (soc/clk/x.patch)
#   - a line that starts with `#` is a comment; an empty line is ignored
#   - the last line may lack its newline
#
# REFUSED, never normalised (each is a line somebody meant differently):
#   CR (a CRLF file), leading or trailing blanks, an inline comment or quilt
#   option after the path, an absolute path, an empty, `.` or `..` component, a
#   name not ending in `.patch`, a path that is not a regular file, a path
#   listed twice, a missing series file, a series with no entry.
#
# API
#   series_load <patch-dir> [<series-file>]
#       default series file: <patch-dir>/series. Fills the global array
#       SERIES (entries, in order). On any refusal: one `::error::` line per
#       problem on stderr, return 1.

series_load() {
  local dir="${1:?series_load: patch directory}" file="${2:-${1}/series}"
  SERIES=()
  if [ ! -f "${file}" ]; then
    echo "::error:: ${file}: series file missing" >&2
    return 1
  fi
  local line path n=0 bad=0
  local -A seen=()
  while IFS= read -r line || [ -n "${line}" ]; do
    n=$((n + 1))
    case "${line}" in
      *$'\r'*) echo "::error:: ${file}:${n}: carriage return (CRLF file?)" >&2; bad=1; continue ;;
      '') continue ;;
      '#'*) continue ;;
      *) path="${line}" ;;
    esac
    if ! series_path_ok "${dir}" "${path}" "${file}:${n}"; then
      bad=1; continue
    fi
    if [ -n "${seen[${path}]:-}" ]; then
      echo "::error:: ${file}:${n}: '${path}' listed twice (first on line ${seen[${path}]})" >&2
      bad=1; continue
    fi
    seen[${path}]=${n}
    SERIES+=("${path}")
  done < "${file}"
  if [ "${bad}" = 0 ] && [ "${#SERIES[@]}" -eq 0 ]; then
    echo "::error:: ${file}: no entry -- an empty series would apply nothing and still succeed" >&2
    bad=1
  fi
  [ "${bad}" = 0 ]
}

# series_path_ok <dir> <path> <where> -- one line's path, checked; errors to stderr.
series_path_ok() {
  local dir="$1" path="$2" where="$3" comp
  case "${path}" in
    *[[:space:]]*) echo "::error:: ${where}: blank inside or around '${path}' (no trimming, no inline comments, no quilt options)" >&2; return 1 ;;
    /*) echo "::error:: ${where}: absolute path '${path}'" >&2; return 1 ;;
    *.patch) ;;
    *) echo "::error:: ${where}: '${path}' does not end in .patch" >&2; return 1 ;;
  esac
  local -a comps
  IFS=/ read -r -a comps <<< "${path}"
  for comp in "${comps[@]}"; do
    case "${comp}" in
      ''|.|..) echo "::error:: ${where}: '${path}' has an empty, '.' or '..' component" >&2; return 1 ;;
    esac
  done
  case "${path}" in */) echo "::error:: ${where}: '${path}' ends in /" >&2; return 1 ;; esac
  case "${path}" in *//*) echo "::error:: ${where}: '${path}' has an empty component" >&2; return 1 ;; esac
  if [ ! -f "${dir}/${path}" ] || [ -L "${dir}/${path}" ]; then
    echo "::error:: ${where}: '${path}' is not a regular file under ${dir}" >&2
    return 1
  fi
  return 0
}
